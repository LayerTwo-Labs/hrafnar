package munin

// Run reader and single-run iterator.

import "base:runtime"
import "core:os"
import "core:sync"

Run :: struct {
	f:             ^os.File, // nil until first use (run_ensure_open)
	opened:        bool,
	expected_size: u64, // manifest's size claim, verified at open; 0 = skip
	run_id:        u64,
	path:          string, // owned; needed for deferred deletion
	file_size:     u64,
	key_only:      bool,
	has_filter:    bool,
	entry_count:   u64,
	// Index and filter payloads load lazily on first access: a database
	// holds thousands of runs and most queries touch one bucket, so eager
	// loading at open turns into gigabytes of pointless reads.
	index_offset:  u64,
	index_length:  u64,
	filter_offset: u64,
	filter_length: u64,
	load_mu:       sync.Mutex,
	loaded:        bool,
	index_payload: []byte, // owned; held for the lifetime of the open run
	index:         Block,
	filter_payload: []byte, // owned; nil when absent
	filter:        Filter,
	cache:         ^Cache, // optional shared block cache; nil reads direct
	refs:          int, // iterator pin count, guarded by the owning Db
	allocator:     runtime.Allocator,
}

// run_ensure_open opens the file and verifies the footer on first use.
// Caller holds load_mu. Opening thousands of runs eagerly at db_open costs
// tens of seconds on slow disks; queries touch a handful.
@(private = "file")
run_ensure_open_locked :: proc(r: ^Run) -> (err: Error) {
	if r.opened {
		return nil
	}
	f, oerr := os.open(r.path, {.Read})
	if oerr != nil {
		return oerr
	}
	defer if err != nil {os.close(f)}

	size := os.file_size(f) or_return
	if r.expected_size > 0 && u64(size) != r.expected_size {
		return Corruption.Size_Mismatch
	}
	if size < RUN_FOOTER_SIZE {
		return Corruption.Truncated
	}
	footer: [RUN_FOOTER_SIZE]byte
	read_full_at(f, footer[:], size - RUN_FOOTER_SIZE) or_return
	if get_u64le(footer[0:]) != RUN_MAGIC {
		return Corruption.Bad_Magic
	}
	if crc32c(footer[:56]) != get_u32le(footer[56:]) {
		return Corruption.Bad_Checksum
	}
	if get_u32le(footer[8:]) > RUN_FORMAT_VERSION {
		return Corruption.Bad_Format_Version
	}
	flags := get_u32le(footer[12:])
	index_offset := get_u64le(footer[16:])
	index_length := get_u64le(footer[24:])
	filter_offset := get_u64le(footer[32:])
	filter_length := get_u64le(footer[40:])
	if index_offset + index_length + BLOCK_TRAILER_SIZE > u64(size) {
		return Corruption.Truncated
	}

	r.f = f
	r.file_size = u64(size)
	r.key_only = flags & RUN_FLAG_KEY_ONLY != 0
	r.has_filter = flags & RUN_FLAG_HAS_FILTER != 0
	r.entry_count = get_u64le(footer[48:])
	r.index_offset = index_offset
	r.index_length = index_length
	if r.has_filter {
		if filter_offset + filter_length + BLOCK_TRAILER_SIZE > u64(size) {
			return Corruption.Truncated
		}
		r.filter_offset = filter_offset
		r.filter_length = filter_length
	}
	r.opened = true
	return nil
}

// run_ensure_loaded opens the file (first use) and reads the index and
// filter blocks. Thread-safe: concurrent iterators over one run are
// common.
run_ensure_loaded :: proc(r: ^Run) -> (err: Error) {
	if sync.atomic_load(&r.loaded) {
		return nil
	}
	sync.mutex_lock(&r.load_mu)
	defer sync.mutex_unlock(&r.load_mu)
	if r.loaded {
		return nil
	}
	run_ensure_open_locked(r) or_return

	index_payload := read_block_direct(r.f, r.index_offset, r.index_length, r.allocator) or_return
	defer if err != nil {delete(index_payload, r.allocator)}
	idx: Block
	block_init(&idx, index_payload, false) or_return

	filter_payload: []byte
	flt: Filter
	if r.has_filter {
		filter_payload = read_block_direct(r.f, r.filter_offset, r.filter_length, r.allocator) or_return
		ferr := filter_init(&flt, filter_payload)
		if ferr != nil {
			delete(filter_payload, r.allocator)
			return ferr
		}
	}

	r.index_payload = index_payload
	r.index = idx
	r.filter_payload = filter_payload
	r.filter = flt
	sync.atomic_store(&r.loaded, true)
	return nil
}

// run_make_lazy creates a run handle with NO I/O: the file opens and the
// footer verifies on first access. This is what lets a database with
// thousands of runs open in milliseconds.
run_make_lazy :: proc(
	path: string,
	run_id: u64 = 0,
	expected_size: u64 = 0,
	cache: ^Cache = nil,
	allocator := context.allocator,
) -> (
	r: ^Run,
	err: Error,
) {
	r = new(Run, allocator)
	perr: runtime.Allocator_Error
	r.path, perr = clone_string(path, allocator)
	if perr != nil {
		free(r, allocator)
		return nil, os.Error(perr)
	}
	r.run_id = run_id
	r.expected_size = expected_size
	r.cache = cache
	r.allocator = allocator
	return r, nil
}

// run_open makes a handle and opens/verifies it immediately — for tests
// and single-run tooling. Databases use run_make_lazy.
run_open :: proc(
	path: string,
	run_id: u64 = 0,
	cache: ^Cache = nil,
	allocator := context.allocator,
) -> (
	r: ^Run,
	err: Error,
) {
	r = run_make_lazy(path, run_id, 0, cache, allocator) or_return
	sync.mutex_lock(&r.load_mu)
	oerr := run_ensure_open_locked(r)
	sync.mutex_unlock(&r.load_mu)
	if oerr != nil {
		run_close(r)
		return nil, oerr
	}
	return r, nil
}

run_close :: proc(r: ^Run) {
	if r == nil {return}
	if r.f != nil {
		os.close(r.f)
	}
	delete(r.index_payload, r.allocator)
	delete(r.filter_payload, r.allocator)
	delete(r.path, r.allocator)
	free(r, r.allocator)
}

// run_filter_check returns false only when the run provably contains no key
// with the lookup key's prefix.
run_filter_check :: proc(r: ^Run, key: []byte) -> bool {
	if !r.has_filter {return true}
	if run_ensure_loaded(r) != nil {
		return true // fail open; the subsequent seek reports the error
	}
	return filter_check(&r.filter, key)
}

// ---------------------------------------------------------------------------
// Block reads

// read_full_at reads exactly len(p) bytes at offset.
@(private)
read_full_at :: proc(f: ^os.File, p: []byte, offset: i64) -> (err: Error) {
	p := p
	offset := offset
	for len(p) > 0 {
		n, rerr := os.read_at(f, p, offset)
		if rerr != nil {
			return rerr
		}
		if n <= 0 {
			return Corruption.Truncated
		}
		p = p[n:]
		offset += i64(n)
	}
	return nil
}

// read_block_direct reads and verifies one block, returning the payload in
// a fresh allocation.
@(private)
read_block_direct :: proc(
	f: ^os.File,
	offset, length: u64,
	allocator: runtime.Allocator,
) -> (
	payload: []byte,
	err: Error,
) {
	buf := make([]byte, length + BLOCK_TRAILER_SIZE, allocator)
	defer if err != nil {delete(buf, allocator)}

	read_full_at(f, buf, i64(offset)) or_return
	verify_block_trailer(buf) or_return
	// Compression type 0 only for now; anything else is from a future
	// format we don't read.
	if buf[length] != 0 {
		return nil, Corruption.Bad_Format_Version
	}
	return buf[:length], nil
}

// verify_block_trailer checks the CRC over payload + type byte.
@(private)
verify_block_trailer :: proc(buf: []byte) -> Error {
	if len(buf) < BLOCK_TRAILER_SIZE {
		return Corruption.Truncated
	}
	length := len(buf) - BLOCK_TRAILER_SIZE
	want := get_u32le(buf[length + 1:])
	got := crc32c(buf[:length + 1])
	if got != want {
		return Corruption.Bad_Checksum
	}
	return nil
}

// run_block_payload fetches a data block, through the cache when present.
// The returned handle must be released; payload is valid until then.
run_block_payload :: proc(r: ^Run, offset, length: u64) -> (payload: []byte, handle: Cache_Handle, err: Error) {
	if r.cache != nil {
		return cache_get(r.cache, r, offset, length)
	}
	payload = read_block_direct(r.f, offset, length, r.allocator) or_return
	handle = Cache_Handle{payload = payload, allocator = r.allocator}
	return payload, handle, nil
}

// ---------------------------------------------------------------------------
// Single-run iterator

Run_Iter :: struct {
	run:        ^Run,
	index_it:   Block_Iter,
	data_blk:   Block,
	data_it:    Block_Iter,
	handle:     Cache_Handle,
	have_block: bool,
	valid:      bool,
	err:        Error,
}

run_iter_init :: proc(it: ^Run_Iter, r: ^Run, allocator := context.allocator) {
	it.run = r
	block_iter_init(&it.index_it, &r.index, allocator)
	block_iter_init(&it.data_it, &it.data_blk, allocator)
	it.have_block = false
	it.valid = false
	it.err = nil
}

run_iter_destroy :: proc(it: ^Run_Iter) {
	release_block(it)
	block_iter_destroy(&it.index_it)
	block_iter_destroy(&it.data_it)
}

@(private = "file")
release_block :: proc(it: ^Run_Iter) {
	if it.have_block {
		cache_handle_release(&it.handle)
		it.have_block = false
	}
}

@(private = "file")
load_block_from_index :: proc(it: ^Run_Iter) -> (ok: bool) {
	release_block(it)
	if !it.index_it.valid {
		it.valid = false
		if it.index_it.err != nil {it.err = it.index_it.err}
		return false
	}
	val := it.index_it.value
	offset, n0 := uvarint_get(val)
	if n0 == 0 {
		it.valid = false
		it.err = Corruption.Bad_Block
		return false
	}
	length, n1 := uvarint_get(val[n0:])
	if n1 == 0 {
		it.valid = false
		it.err = Corruption.Bad_Block
		return false
	}

	payload, handle, err := run_block_payload(it.run, offset, length)
	if err != nil {
		it.valid = false
		it.err = err
		return false
	}
	it.handle = handle
	it.have_block = true

	berr := block_init(&it.data_blk, payload, it.run.key_only)
	if berr != nil {
		it.valid = false
		it.err = berr
		return false
	}
	return true
}

run_iter_seek_first :: proc(it: ^Run_Iter) {
	it.err = nil
	if lerr := run_ensure_loaded(it.run); lerr != nil {
		it.valid = false
		it.err = lerr
		return
	}
	block_iter_seek_first(&it.index_it)
	if !load_block_from_index(it) {return}
	block_iter_seek_first(&it.data_it)
	it.valid = it.data_it.valid
	if it.data_it.err != nil {it.err = it.data_it.err; it.valid = false}
}

// run_iter_seek positions on the first key >= target.
run_iter_seek :: proc(it: ^Run_Iter, target: []byte) {
	it.err = nil
	if lerr := run_ensure_loaded(it.run); lerr != nil {
		it.valid = false
		it.err = lerr
		return
	}
	// Index keys are separators >= each block's last key, so the first
	// index entry >= target names the only block that can contain target.
	block_iter_seek(&it.index_it, target)
	if !load_block_from_index(it) {return}
	block_iter_seek(&it.data_it, target)
	if it.data_it.err != nil {
		it.valid = false
		it.err = it.data_it.err
		return
	}
	if !it.data_it.valid {
		// target fell between this block's last key and its separator;
		// the answer is the next block's first key.
		advance_block(it)
		return
	}
	it.valid = true
}

run_iter_next :: proc(it: ^Run_Iter) {
	if !it.valid {return}
	block_iter_next(&it.data_it)
	if it.data_it.err != nil {
		it.valid = false
		it.err = it.data_it.err
		return
	}
	if !it.data_it.valid {
		advance_block(it)
		return
	}
}

@(private = "file")
advance_block :: proc(it: ^Run_Iter) {
	block_iter_next(&it.index_it)
	if !load_block_from_index(it) {return}
	block_iter_seek_first(&it.data_it)
	it.valid = it.data_it.valid
	if it.data_it.err != nil {it.err = it.data_it.err; it.valid = false}
}

run_iter_valid :: proc(it: ^Run_Iter) -> bool {
	return it.valid
}

// Borrowed; invalid after the next seek/next/destroy.
run_iter_key :: proc(it: ^Run_Iter) -> []byte {
	return it.data_it.key[:]
}

run_iter_value :: proc(it: ^Run_Iter) -> []byte {
	return it.data_it.value
}
