package munin

// Sorted run writer. Produces one immutable .run file:
//
//   data blocks | filter block (optional) | index block | footer (64 bytes)
//
// Every block carries a 5-byte trailer: compression type byte (0 = none)
// plus CRC32C over the payload and the type byte. Recorded offsets and
// lengths refer to the payload only.

import "base:runtime"
import "core:bytes"
import "core:os"

RUN_MAGIC :: u64(0x4D554E494E52554E) // "MUNINRUN" read big-endian
RUN_FORMAT_VERSION :: u32(1)
RUN_FOOTER_SIZE :: 64
BLOCK_TRAILER_SIZE :: 5

RUN_FLAG_KEY_ONLY :: u32(1 << 0)
RUN_FLAG_HAS_FILTER :: u32(1 << 1)

Run_Writer_Config :: struct {
	block_size:          int,
	restart_interval:    int,
	key_only:            bool,
	filter_prefix_len:   int, // 0 = no filter
	filter_bits_per_key: int,
}

Run_Writer :: struct {
	f:              ^os.File,
	path:           string, // owned
	cfg:            Run_Writer_Config,
	offset:         u64,
	bw:             Block_Writer, // current data block
	iw:             Block_Writer, // index block
	// Index entry for a data block is emitted only once the next block's
	// first key is known, so the separator can be computed.
	pending_last:   [dynamic]byte,
	pending_offset: u64,
	pending_length: u64,
	pending:        bool,
	sep_buf:        [dynamic]byte,
	filter:         Filter_Builder,
	entry_count:    u64,
	min_key:        [dynamic]byte,
	max_key:        [dynamic]byte,
	finished:       bool,
	allocator:      runtime.Allocator,
}

run_writer_begin :: proc(
	w: ^Run_Writer,
	path: string,
	cfg: Run_Writer_Config,
	allocator := context.allocator,
) -> (
	err: Error,
) {
	cfg := cfg
	if cfg.block_size <= 0 {cfg.block_size = 4096}
	if cfg.restart_interval <= 0 {cfg.restart_interval = 16}
	if cfg.filter_bits_per_key <= 0 {cfg.filter_bits_per_key = 10}

	f, oerr := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Read_All + {.Write_User})
	if oerr != nil {
		return oerr
	}
	w.f = f
	perr: runtime.Allocator_Error
	w.path, perr = clone_string(path, allocator)
	if perr != nil {
		os.close(f)
		return os.Error(perr)
	}
	w.cfg = cfg
	w.offset = 0
	block_writer_init(&w.bw, cfg.restart_interval, cfg.key_only, allocator)
	block_writer_init(&w.iw, cfg.restart_interval, false, allocator)
	w.pending_last = make([dynamic]byte, allocator)
	w.sep_buf = make([dynamic]byte, allocator)
	w.pending = false
	if cfg.filter_prefix_len > 0 {
		filter_builder_init(&w.filter, cfg.filter_prefix_len, cfg.filter_bits_per_key, allocator)
	}
	w.entry_count = 0
	w.min_key = make([dynamic]byte, allocator)
	w.max_key = make([dynamic]byte, allocator)
	w.finished = false
	w.allocator = allocator
	return nil
}

run_writer_destroy :: proc(w: ^Run_Writer) {
	block_writer_destroy(&w.bw)
	block_writer_destroy(&w.iw)
	delete(w.pending_last)
	delete(w.sep_buf)
	if w.cfg.filter_prefix_len > 0 {
		filter_builder_destroy(&w.filter)
	}
	delete(w.min_key)
	delete(w.max_key)
	delete(w.path, w.allocator)
}

// run_writer_abort closes and removes the partial file.
run_writer_abort :: proc(w: ^Run_Writer) {
	if w.f != nil {
		os.close(w.f)
		os.remove(w.path)
		w.f = nil
	}
	run_writer_destroy(w)
}

run_writer_add :: proc(w: ^Run_Writer, key, value: []byte) -> Error {
	if w.finished || w.f == nil {
		return Usage_Error.Ingest_Misuse
	}
	// Cross-block ordering: the block writer only checks within the current
	// block, so check against the run-wide max here.
	if w.entry_count > 0 && bytes.compare(key, w.max_key[:]) <= 0 {
		return Usage_Error.Keys_Out_Of_Order
	}

	if w.bw.entry_count > 0 &&
	   block_writer_estimate(&w.bw, len(key), len(value)) > w.cfg.block_size {
		flush_data_block(w) or_return
	}

	// The first key of a new block resolves the pending index entry for the
	// previous block.
	if w.bw.entry_count == 0 && w.pending {
		emit_pending_index(w, key) or_return
	}

	block_writer_add(&w.bw, key, value) or_return

	if w.cfg.filter_prefix_len > 0 {
		filter_builder_add(&w.filter, key)
	}
	if w.entry_count == 0 {
		resize(&w.min_key, len(key))
		copy(w.min_key[:], key)
	}
	resize(&w.max_key, len(key))
	copy(w.max_key[:], key)
	w.entry_count += 1
	return nil
}

Run_Writer_Result :: struct {
	entry_count: u64,
	file_size:   u64,
}

run_writer_finish :: proc(w: ^Run_Writer) -> (res: Run_Writer_Result, err: Error) {
	if w.finished || w.f == nil {
		return {}, Usage_Error.Ingest_Misuse
	}
	if w.entry_count == 0 {
		return {}, Usage_Error.Ingest_Misuse
	}
	defer if err != nil {
		os.close(w.f)
		os.remove(w.path)
		w.f = nil
	}

	if w.bw.entry_count > 0 {
		flush_data_block(w) or_return
	}
	// Final block has no successor; its index key is its own last key.
	if w.pending {
		iw_add_pending(w, w.pending_last[:]) or_return
	}

	flags: u32
	if w.cfg.key_only {flags |= RUN_FLAG_KEY_ONLY}

	filter_offset, filter_length: u64
	if w.cfg.filter_prefix_len > 0 {
		flags |= RUN_FLAG_HAS_FILTER
		fpayload := filter_builder_finish(&w.filter)
		filter_offset = w.offset
		filter_length = u64(len(fpayload))
		write_block(w, fpayload) or_return
	}

	index_payload := block_writer_finish(&w.iw)
	index_offset := w.offset
	index_length := u64(len(index_payload))
	write_block(w, index_payload) or_return

	footer: [RUN_FOOTER_SIZE]byte
	put_u64le(footer[0:], RUN_MAGIC)
	put_u32le(footer[8:], RUN_FORMAT_VERSION)
	put_u32le(footer[12:], flags)
	put_u64le(footer[16:], index_offset)
	put_u64le(footer[24:], index_length)
	put_u64le(footer[32:], filter_offset)
	put_u64le(footer[40:], filter_length)
	put_u64le(footer[48:], w.entry_count)
	put_u32le(footer[56:], crc32c(footer[:56]))
	// bytes 60..63 reserved, zero
	write_all(w.f, footer[:]) or_return
	w.offset += RUN_FOOTER_SIZE

	os.sync(w.f) or_return
	os.close(w.f) or_return
	w.f = nil
	w.finished = true
	return Run_Writer_Result{entry_count = w.entry_count, file_size = w.offset}, nil
}

// ---------------------------------------------------------------------------

@(private = "file")
flush_data_block :: proc(w: ^Run_Writer) -> (err: Error) {
	payload := block_writer_finish(&w.bw)
	off := w.offset
	write_block(w, payload) or_return

	resize(&w.pending_last, len(w.bw.last_key))
	copy(w.pending_last[:], w.bw.last_key[:])
	w.pending_offset = off
	w.pending_length = u64(len(payload))
	w.pending = true

	block_writer_reset(&w.bw)
	return nil
}

@(private = "file")
emit_pending_index :: proc(w: ^Run_Writer, next_first_key: []byte) -> (err: Error) {
	shortest_separator(&w.sep_buf, w.pending_last[:], next_first_key)
	return iw_add_pending(w, w.sep_buf[:])
}

@(private = "file")
iw_add_pending :: proc(w: ^Run_Writer, sep: []byte) -> (err: Error) {
	val: [2 * UVARINT_MAX_LEN]byte
	n := uvarint_put(val[:], w.pending_offset)
	n += uvarint_put(val[n:], w.pending_length)
	block_writer_add(&w.iw, sep, val[:n]) or_return
	w.pending = false
	return nil
}

// write_block writes payload plus its 5-byte trailer and advances the
// offset past both.
@(private = "file")
write_block :: proc(w: ^Run_Writer, payload: []byte) -> (err: Error) {
	trailer: [BLOCK_TRAILER_SIZE]byte
	trailer[0] = 0 // no compression
	crc := crc32c_update(crc32c(payload), trailer[:1])
	put_u32le(trailer[1:], crc)
	write_all(w.f, payload) or_return
	write_all(w.f, trailer[:]) or_return
	w.offset += u64(len(payload)) + BLOCK_TRAILER_SIZE
	return nil
}

@(private)
write_all :: proc(f: ^os.File, data: []byte) -> (err: Error) {
	data := data
	for len(data) > 0 {
		n, werr := os.write(f, data)
		if werr != nil {
			return werr
		}
		if n <= 0 {
			return os.Error(os.General_Error.Broken_Pipe)
		}
		data = data[n:]
	}
	return nil
}

// shortest_separator writes into buf the shortest byte string S with
// a <= S < b, given a < b. Falls back to a itself when no shorter
// separator exists.
@(private)
shortest_separator :: proc(buf: ^[dynamic]byte, a, b: []byte) {
	limit := min(len(a), len(b))
	i := 0
	for i < limit && a[i] == b[i] {
		i += 1
	}
	if i < limit && a[i] + 1 < b[i] {
		// a[:i] + (a[i]+1) is > a (larger byte at i) and < b (smaller
		// byte at i than b's).
		resize(buf, i + 1)
		copy(buf[:], a[:i])
		buf[i] = a[i] + 1
		return
	}
	// Either a is a prefix of b, or the bytes are adjacent: keep a.
	resize(buf, len(a))
	copy(buf[:], a)
}

@(private)
clone_string :: proc(s: string, allocator: runtime.Allocator) -> (out: string, err: runtime.Allocator_Error) {
	b := make([]byte, len(s), allocator) or_return
	copy(b, s)
	return string(b), nil
}
