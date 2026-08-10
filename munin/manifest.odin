package munin

// Manifest read/write.
//
// header:
//   magic u64 | format_version u32 | bucket_bits u32
//   key_only u8 | has_filter u8 | prefix_len u16 | bits_per_key u32
//   run_count u32 | next_run_id u64 | crc32c u32 (over preceding bytes)
// then run_count records:
//   run_id u64 | bucket u32 | level u32 | entry_count u64 | file_size u64
//   min_key_len u16 | max_key_len u16 | min_key | max_key | crc32c u32
//
// Update protocol, non-negotiable ordering:
//   write MANIFEST.tmp -> fsync tmp -> rename -> fsync directory.

import "core:fmt"
import "core:os"

MANIFEST_MAGIC :: u64(0x4D554E494E4D414E) // "MUNINMAN"
MANIFEST_FORMAT_VERSION :: u32(1)
MANIFEST_HEADER_SIZE :: 8 + 4 + 4 + 1 + 1 + 2 + 4 + 4 + 8 + 4
MANIFEST_NAME :: "MANIFEST"
MANIFEST_TMP_NAME :: "MANIFEST.tmp"

Manifest_Run :: struct {
	run_id:      u64,
	bucket:      u32,
	level:       u32,
	entry_count: u64,
	file_size:   u64,
	min_key:     []byte, // owned by the manifest
	max_key:     []byte,
}

Manifest :: struct {
	format_version: u32,
	bucket_bits:    u32,
	key_only:       bool,
	has_filter:     bool,
	prefix_len:     u16,
	bits_per_key:   u32,
	next_run_id:    u64,
	runs:           [dynamic]Manifest_Run,
}

manifest_init :: proc(m: ^Manifest, cfg: Config, allocator := context.allocator) {
	m.format_version = MANIFEST_FORMAT_VERSION
	m.bucket_bits = cfg.bucket_bits
	m.key_only = cfg.key_only
	m.has_filter = cfg.filter_prefix_len > 0
	m.prefix_len = u16(cfg.filter_prefix_len)
	m.bits_per_key = u32(cfg.filter_bits_per_key)
	m.next_run_id = 1
	m.runs = make([dynamic]Manifest_Run, allocator)
}

manifest_destroy :: proc(m: ^Manifest, allocator := context.allocator) {
	for &r in m.runs {
		delete(r.min_key, allocator)
		delete(r.max_key, allocator)
	}
	delete(m.runs)
}

manifest_encode :: proc(m: ^Manifest, buf: ^[dynamic]byte) {
	clear(buf)
	hdr: [MANIFEST_HEADER_SIZE]byte
	put_u64le(hdr[0:], MANIFEST_MAGIC)
	put_u32le(hdr[8:], m.format_version)
	put_u32le(hdr[12:], m.bucket_bits)
	hdr[16] = u8(m.key_only)
	hdr[17] = u8(m.has_filter)
	hdr[18] = byte(m.prefix_len)
	hdr[19] = byte(m.prefix_len >> 8)
	put_u32le(hdr[20:], m.bits_per_key)
	put_u32le(hdr[24:], u32(len(m.runs)))
	put_u64le(hdr[28:], m.next_run_id)
	put_u32le(hdr[36:], crc32c(hdr[:36]))
	append(buf, ..hdr[:])

	rec: [40]byte
	for &r in m.runs {
		start := len(buf)
		put_u64le(rec[0:], r.run_id)
		put_u32le(rec[8:], r.bucket)
		put_u32le(rec[12:], r.level)
		put_u64le(rec[16:], r.entry_count)
		put_u64le(rec[24:], r.file_size)
		rec[32] = byte(len(r.min_key))
		rec[33] = byte(len(r.min_key) >> 8)
		rec[34] = byte(len(r.max_key))
		rec[35] = byte(len(r.max_key) >> 8)
		append(buf, ..rec[:36])
		append(buf, ..r.min_key)
		append(buf, ..r.max_key)
		crc := crc32c(buf[start:])
		u32le_append(buf, crc)
	}
}

manifest_decode :: proc(
	data: []byte,
	allocator := context.allocator,
) -> (
	m: Manifest,
	err: Error,
) {
	defer if err != nil {
		manifest_destroy(&m, allocator)
	}
	if len(data) < MANIFEST_HEADER_SIZE {
		return m, Corruption.Truncated
	}
	if get_u64le(data[0:]) != MANIFEST_MAGIC {
		return m, Corruption.Bad_Magic
	}
	if crc32c(data[:36]) != get_u32le(data[36:]) {
		return m, Corruption.Bad_Checksum
	}
	m.format_version = get_u32le(data[8:])
	if m.format_version > MANIFEST_FORMAT_VERSION {
		return m, Corruption.Bad_Format_Version
	}
	m.bucket_bits = get_u32le(data[12:])
	m.key_only = data[16] != 0
	m.has_filter = data[17] != 0
	m.prefix_len = get_u16le(data[18:])
	m.bits_per_key = get_u32le(data[20:])
	run_count := int(get_u32le(data[24:]))
	m.next_run_id = get_u64le(data[28:])
	m.runs = make([dynamic]Manifest_Run, allocator)

	rest := data[MANIFEST_HEADER_SIZE:]
	for _ in 0 ..< run_count {
		if len(rest) < 36 {
			return m, Corruption.Truncated
		}
		min_len := int(get_u16le(rest[32:]))
		max_len := int(get_u16le(rest[34:]))
		total := 36 + min_len + max_len + 4
		if len(rest) < total {
			return m, Corruption.Truncated
		}
		if crc32c(rest[:total - 4]) != get_u32le(rest[total - 4:]) {
			return m, Corruption.Bad_Checksum
		}
		r: Manifest_Run
		r.run_id = get_u64le(rest[0:])
		r.bucket = get_u32le(rest[8:])
		r.level = get_u32le(rest[12:])
		r.entry_count = get_u64le(rest[16:])
		r.file_size = get_u64le(rest[24:])
		r.min_key = make([]byte, min_len, allocator)
		copy(r.min_key, rest[36:36 + min_len])
		r.max_key = make([]byte, max_len, allocator)
		copy(r.max_key, rest[36 + min_len:36 + min_len + max_len])
		append(&m.runs, r)
		rest = rest[total:]
	}
	if len(rest) != 0 {
		return m, Corruption.Truncated
	}
	return m, nil
}

// manifest_write persists the manifest with the full durability protocol.
manifest_write :: proc(dir: string, m: ^Manifest) -> (err: Error) {
	buf := make([dynamic]byte, context.temp_allocator)
	manifest_encode(m, &buf)

	tmp_path := fmt.tprintf("%s/%s", dir, MANIFEST_TMP_NAME)
	final_path := fmt.tprintf("%s/%s", dir, MANIFEST_NAME)

	f, oerr := os.open(tmp_path, {.Write, .Create, .Trunc}, os.Permissions_Read_All + {.Write_User})
	if oerr != nil {
		return oerr
	}
	werr := write_all(f, buf[:])
	if werr == nil {
		// Assigning an os.Error into the Error union wraps even a nil
		// value into a non-nil union; only assign after a nil check.
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

manifest_read :: proc(
	dir: string,
	allocator := context.allocator,
) -> (
	m: Manifest,
	err: Error,
) {
	path := fmt.tprintf("%s/%s", dir, MANIFEST_NAME)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return m, rerr
	}
	return manifest_decode(data, allocator)
}

// dir_sync fsyncs a directory so renames and new directory entries are
// durable. The step everyone skips; we don't.
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
	// A nil os.Error must not be wrapped into the union: that would make a
	// non-nil Error whose payload is nil.
	return nil
}
