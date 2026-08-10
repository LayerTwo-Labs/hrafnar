package munin

// Data block encode/decode with prefix compression.
//
// Entry:   shared_len uvarint | unshared_len uvarint | [value_len uvarint]
//          | key suffix | [value]
// Trailer: restart offsets u32le × R | restart_count u32le
//
// value_len and value are omitted entirely in key-only blocks. Restarts
// occur every restart_interval entries; a restart entry has shared_len == 0
// so its key is stored complete.

import "core:bytes"

// ---------------------------------------------------------------------------
// Writer

Block_Writer :: struct {
	buf:                 [dynamic]byte,
	restarts:            [dynamic]u32,
	last_key:            [dynamic]byte,
	restart_interval:    int,
	key_only:            bool,
	count_since_restart: int,
	entry_count:         int,
}

block_writer_init :: proc(
	w: ^Block_Writer,
	restart_interval: int,
	key_only: bool,
	allocator := context.allocator,
) {
	w.buf = make([dynamic]byte, allocator)
	w.restarts = make([dynamic]u32, allocator)
	w.last_key = make([dynamic]byte, allocator)
	w.restart_interval = restart_interval
	w.key_only = key_only
	w.count_since_restart = 0
	w.entry_count = 0
}

block_writer_destroy :: proc(w: ^Block_Writer) {
	delete(w.buf)
	delete(w.restarts)
	delete(w.last_key)
}

block_writer_reset :: proc(w: ^Block_Writer) {
	clear(&w.buf)
	clear(&w.restarts)
	clear(&w.last_key)
	w.count_since_restart = 0
	w.entry_count = 0
}

// block_writer_add appends an entry. Keys must arrive in strictly
// increasing order.
block_writer_add :: proc(w: ^Block_Writer, key, value: []byte) -> Error {
	if w.entry_count > 0 && bytes.compare(key, w.last_key[:]) <= 0 {
		return Usage_Error.Keys_Out_Of_Order
	}

	shared := 0
	if w.count_since_restart >= w.restart_interval || w.entry_count == 0 {
		append(&w.restarts, u32(len(w.buf)))
		w.count_since_restart = 0
	} else {
		limit := min(len(key), len(w.last_key))
		for shared < limit && key[shared] == w.last_key[shared] {
			shared += 1
		}
	}

	uvarint_append(&w.buf, u64(shared))
	uvarint_append(&w.buf, u64(len(key) - shared))
	if !w.key_only {
		uvarint_append(&w.buf, u64(len(value)))
	}
	append(&w.buf, ..key[shared:])
	if !w.key_only {
		append(&w.buf, ..value)
	}

	resize(&w.last_key, len(key))
	copy(w.last_key[:], key)
	w.count_since_restart += 1
	w.entry_count += 1
	return nil
}

// block_writer_size is the payload size if finished now.
block_writer_size :: proc(w: ^Block_Writer) -> int {
	return len(w.buf) + 4 * len(w.restarts) + 4
}

// block_writer_estimate is block_writer_size after adding an entry of the
// given key/value lengths (worst case: no prefix sharing, new restart).
block_writer_estimate :: proc(w: ^Block_Writer, key_len, value_len: int) -> int {
	entry := 2 * UVARINT_MAX_LEN + key_len
	if !w.key_only {
		entry += UVARINT_MAX_LEN + value_len
	}
	restart := 0
	if w.count_since_restart >= w.restart_interval || w.entry_count == 0 {
		restart = 4
	}
	return block_writer_size(w) + entry + restart
}

// block_writer_finish appends the restart trailer and returns the payload,
// borrowed from the writer until the next reset/destroy.
block_writer_finish :: proc(w: ^Block_Writer) -> []byte {
	for r in w.restarts {
		u32le_append(&w.buf, r)
	}
	u32le_append(&w.buf, u32(len(w.restarts)))
	return w.buf[:]
}

@(private)
u32le_append :: proc(buf: ^[dynamic]byte, x: u32) {
	append(buf, byte(x), byte(x >> 8), byte(x >> 16), byte(x >> 24))
}

// ---------------------------------------------------------------------------
// Reader

Block :: struct {
	payload:       []byte, // full payload including restart trailer
	entries_end:   int, // where the entry region ends / restart array begins
	restart_count: int,
	key_only:      bool,
}

block_init :: proc(b: ^Block, payload: []byte, key_only: bool) -> Error {
	if len(payload) < 4 {
		return Corruption.Bad_Block
	}
	rc := int(get_u32le(payload[len(payload) - 4:]))
	entries_end := len(payload) - 4 - 4 * rc
	if rc < 1 || entries_end < 0 {
		return Corruption.Bad_Block
	}
	b.payload = payload
	b.entries_end = entries_end
	b.restart_count = rc
	b.key_only = key_only
	return nil
}

block_restart_offset :: proc(b: ^Block, i: int) -> int {
	return int(get_u32le(b.payload[b.entries_end + 4 * i:]))
}

// Block_Iter walks entries in order, reconstructing keys into its own
// buffer. value slices are borrowed from the payload.
Block_Iter :: struct {
	blk:         ^Block,
	offset:      int, // offset of the entry after the current one
	key:         [dynamic]byte,
	value:       []byte,
	valid:       bool,
	err:         Error,
}

block_iter_init :: proc(it: ^Block_Iter, b: ^Block, allocator := context.allocator) {
	it.blk = b
	it.key = make([dynamic]byte, allocator)
	it.valid = false
	it.err = nil
}

block_iter_destroy :: proc(it: ^Block_Iter) {
	delete(it.key)
}

// block_iter_parse_next decodes the entry at it.offset and advances.
@(private = "file")
block_iter_parse_next :: proc(it: ^Block_Iter) {
	b := it.blk
	if it.offset >= b.entries_end {
		it.valid = false
		return
	}
	rest := b.payload[it.offset:b.entries_end]

	shared, n0 := uvarint_get(rest)
	if n0 == 0 {it.valid = false; it.err = Corruption.Bad_Block; return}
	rest = rest[n0:]
	unshared, n1 := uvarint_get(rest)
	if n1 == 0 {it.valid = false; it.err = Corruption.Bad_Block; return}
	rest = rest[n1:]
	vlen: u64
	n2: int
	if !b.key_only {
		vlen, n2 = uvarint_get(rest)
		if n2 == 0 {it.valid = false; it.err = Corruption.Bad_Block; return}
		rest = rest[n2:]
	}
	if int(shared) > len(it.key) || unshared > u64(len(rest)) || vlen > u64(len(rest)) - unshared {
		it.valid = false
		it.err = Corruption.Bad_Block
		return
	}

	resize(&it.key, int(shared) + int(unshared))
	copy(it.key[int(shared):], rest[:unshared])
	it.value = rest[unshared:unshared + vlen]
	it.offset += n0 + n1 + n2 + int(unshared) + int(vlen)
	it.valid = true
}

block_iter_seek_first :: proc(it: ^Block_Iter) {
	it.offset = 0
	clear(&it.key)
	block_iter_parse_next(it)
}

// block_iter_seek positions on the first entry with key >= target.
block_iter_seek :: proc(it: ^Block_Iter, target: []byte) {
	b := it.blk

	// Binary search restarts for the last restart whose key < target.
	// A restart entry has shared_len == 0, so its key is stored complete
	// and comparable without reconstruction.
	lo, hi := 0, b.restart_count - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		rkey, ok := block_restart_key(b, mid)
		if !ok {
			it.valid = false
			it.err = Corruption.Bad_Block
			return
		}
		if bytes.compare(rkey, target) < 0 {
			lo = mid
		} else {
			hi = mid - 1
		}
	}

	it.offset = block_restart_offset(b, lo)
	clear(&it.key)
	block_iter_parse_next(it)
	for it.valid && bytes.compare(it.key[:], target) < 0 {
		block_iter_parse_next(it)
	}
}

block_iter_next :: proc(it: ^Block_Iter) {
	if it.valid {
		block_iter_parse_next(it)
	}
}

// block_restart_key returns the complete key stored at restart i, borrowed
// from the payload.
@(private = "file")
block_restart_key :: proc(b: ^Block, i: int) -> (key: []byte, ok: bool) {
	off := block_restart_offset(b, i)
	if off >= b.entries_end {return nil, false}
	rest := b.payload[off:b.entries_end]

	shared, n0 := uvarint_get(rest)
	if n0 == 0 || shared != 0 {return nil, false}
	rest = rest[n0:]
	unshared, n1 := uvarint_get(rest)
	if n1 == 0 {return nil, false}
	rest = rest[n1:]
	if !b.key_only {
		_, n2 := uvarint_get(rest)
		if n2 == 0 {return nil, false}
		rest = rest[n2:]
	}
	if u64(len(rest)) < unshared {return nil, false}
	return rest[:unshared], true
}
