package hugin

import "base:intrinsics"

// headers.dat: the selected main chain as a flat array of fixed 128-byte
// records indexed directly by height, plus the CHECKPOINT file. Both are
// written with the tmp -> fsync -> rename -> fsync-dir protocol.
//
// record:
//   hash 32 | raw header 80 | file_no u16 | offset u32 | length u32
//   | tx_count u32 | reserved u16

import "core:fmt"
import "core:os"

import munin "../munin"

HEADERS_NAME :: "headers.dat"
HEADERS_TMP_NAME :: "headers.dat.tmp"
HEADER_RECORD_SIZE :: 128
CHECKPOINT_NAME :: "CHECKPOINT"
CHECKPOINT_TMP_NAME :: "CHECKPOINT.tmp"
CHECKPOINT_SIZE :: 40

Stored_Header :: struct {
	hash:     [32]u8,
	raw:      [80]u8,
	file_no:  u32,
	offset:   u32,
	length:   u32,
	tx_count: u32,
}

// headers_store_write persists the whole chain. Heights are implicit:
// record i is height i.
headers_store_write :: proc(dir: string, chain: []Stored_Header) -> (err: Error) {
	tmp_path := fmt.tprintf("%s/%s", dir, HEADERS_TMP_NAME)
	final_path := fmt.tprintf("%s/%s", dir, HEADERS_NAME)

	f := os.open(tmp_path, {.Write, .Create, .Trunc}, os.Permissions_Read_All + {.Write_User}) or_return

	rec: [HEADER_RECORD_SIZE]byte
	ok := true
	oserr: os.Error
	for &h in chain {
		copy(rec[0:32], h.hash[:])
		copy(rec[32:112], h.raw[:])
		rec[112] = byte(h.file_no)
		rec[113] = byte(h.file_no >> 8)
		put_u32le(rec[114:], h.offset)
		put_u32le(rec[118:], h.length)
		put_u32le(rec[122:], h.tx_count)
		rec[126] = 0
		rec[127] = 0
		if werr := write_full(f, rec[:]); werr != nil {
			oserr = werr
			ok = false
			break
		}
	}
	if ok {
		if serr := os.sync(f); serr != nil {
			oserr = serr
			ok = false
		}
	}
	cerr := os.close(f)
	if !ok {
		return oserr
	}
	if cerr != nil {
		return cerr
	}

	os.rename(tmp_path, final_path) or_return
	dir_sync(dir) or_return
	return nil
}

// headers_store_read loads the whole chain into memory (~130 bytes per
// block; the full chain is ~120MB).
headers_store_read :: proc(
	dir: string,
	allocator := context.allocator,
) -> (
	chain: []Stored_Header,
	err: Error,
) {
	path := fmt.tprintf("%s/%s", dir, HEADERS_NAME)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return nil, rerr
	}
	if len(data) % HEADER_RECORD_SIZE != 0 {
		return nil, Corruption.Truncated
	}
	n := len(data) / HEADER_RECORD_SIZE
	chain = make([]Stored_Header, n, allocator)
	for i in 0 ..< n {
		rec := data[i * HEADER_RECORD_SIZE:]
		h := &chain[i]
		copy(h.hash[:], rec[0:32])
		copy(h.raw[:], rec[32:112])
		h.file_no = u32(rec[112]) | u32(rec[113]) << 8
		h.offset = get_u32le(rec[114:])
		h.length = get_u32le(rec[118:])
		h.tx_count = get_u32le(rec[122:])
	}
	return chain, nil
}

// ---------------------------------------------------------------------------
// Checkpoint: (height u32, block_hash [32]u8, crc32c u32)

checkpoint_write :: proc(dir: string, height: u32, hash: [32]u8) -> (err: Error) {
	hash := hash
	buf: [CHECKPOINT_SIZE]byte
	put_u32le(buf[0:], height)
	copy(buf[4:36], hash[:])
	put_u32le(buf[36:], munin.crc32c(buf[:36]))

	tmp_path := fmt.tprintf("%s/%s", dir, CHECKPOINT_TMP_NAME)
	final_path := fmt.tprintf("%s/%s", dir, CHECKPOINT_NAME)

	f := os.open(tmp_path, {.Write, .Create, .Trunc}, os.Permissions_Read_All + {.Write_User}) or_return
	werr := write_full(f, buf[:])
	if werr == nil {
		if serr := os.sync(f); serr != nil {
			werr = serr
		}
	}
	cerr := os.close(f)
	if werr != nil {
		return werr
	}
	if cerr != nil {
		return cerr
	}

	os.rename(tmp_path, final_path) or_return
	dir_sync(dir) or_return
	return nil
}

checkpoint_read :: proc(dir: string) -> (height: u32, hash: [32]u8, err: Error) {
	path := fmt.tprintf("%s/%s", dir, CHECKPOINT_NAME)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return 0, {}, rerr
	}
	if len(data) != CHECKPOINT_SIZE {
		return 0, {}, Corruption.Truncated
	}
	if munin.crc32c(data[:36]) != get_u32le(data[36:]) {
		return 0, {}, Corruption.Bad_Checksum
	}
	height = get_u32le(data[0:])
	copy(hash[:], data[4:36])
	return height, hash, nil
}

// ---------------------------------------------------------------------------
// Small shared file helpers (Hugin side).

@(private)
write_full :: proc(f: ^os.File, data: []byte) -> os.Error {
	data := data
	for len(data) > 0 {
		n, werr := os.write(f, data)
		if werr != nil {
			return werr
		}
		if n <= 0 {
			return os.General_Error.Broken_Pipe
		}
		data = data[n:]
	}
	return nil
}

// ensure_dir is make_directory_all treating an existing path as success
// (os.make_directory_all returns .Exist for one).
@(private)
ensure_dir :: proc(dir: string) -> Error {
	merr := os.make_directory_all(dir)
	if merr != nil {
		if ge, is_ge := merr.(os.General_Error); is_ge && ge == .Exist {
			return nil
		}
		return merr
	}
	return nil
}

@(private)
dir_sync :: proc(dir: string) -> (err: Error) {
	f := os.open(dir, {.Read}) or_return
	serr := os.sync(f)
	cerr := os.close(f)
	if serr != nil {
		return serr
	}
	if cerr != nil {
		return cerr
	}
	return nil
}

// Unaligned loads of Odin's endian types: one load (plus a swap on
// big-endian hosts) instead of a shift-and-or chain. These sit on the
// block-parsing path, so they run over every transaction.
@(private)
get_u32le :: proc "contextless" (buf: []byte) -> u32 {
	#no_bounds_check return u32(intrinsics.unaligned_load((^u32le)(&buf[0])))
}

@(private)
put_u32le :: proc "contextless" (buf: []byte, x: u32) {
	buf[0] = byte(x)
	buf[1] = byte(x >> 8)
	buf[2] = byte(x >> 16)
	buf[3] = byte(x >> 24)
}

@(private)
get_u64le :: proc "contextless" (buf: []byte) -> u64 {
	#no_bounds_check return u64(intrinsics.unaligned_load((^u64le)(&buf[0])))
}

@(private)
put_u64le :: proc "contextless" (buf: []byte, x: u64) {
	buf[0] = byte(x)
	buf[1] = byte(x >> 8)
	buf[2] = byte(x >> 16)
	buf[3] = byte(x >> 24)
	buf[4] = byte(x >> 32)
	buf[5] = byte(x >> 40)
	buf[6] = byte(x >> 48)
	buf[7] = byte(x >> 56)
}

