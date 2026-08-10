package hugin

// blk*.dat discovery, mmap, and record framing.
//
// A blk file is a bare concatenation of records:
//   magic (4) | block size u32le (4) | block bytes
//
// Records are in receive order, not chain order, and orphans are
// interleaved. Trailing zeros are normal (zero magic = end of useful data).
// The highest-numbered file may be growing under a live Core: capture the
// stat size once at open and never read past it. Pruned datadirs have gaps
// in the numbering: enumerate what exists.

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:simd"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

Blk_File :: struct {
	file_no: u32,
	path:    string, // owned
	data:    []byte, // live mmap; empty until blkfile_map
	mapped:  bool,
	// Bitcoin Core v28+ obfuscates blk files by XORing every byte with an
	// 8-byte key (blocks/xor.dat), keyed by absolute file offset. When
	// xored is set, data holds obfuscated bytes: use the blk_* helpers,
	// never the raw slice.
	key:     [8]u8,
	xored:   bool,
}

// blkfile_load_xor_key reads blocks/xor.dat. A missing file or an all-zero
// key means no obfuscation.
blkfile_load_xor_key :: proc(dir: string) -> (key: [8]u8, active: bool) {
	path := fmt.tprintf("%s/xor.dat", dir)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil || len(data) < 8 {
		return {}, false
	}
	copy(key[:], data[:8])
	for b in key {
		if b != 0 {
			return key, true
		}
	}
	return {}, false
}

// blkfile_enumerate finds every blk*.dat in dir, sorted by file number,
// and picks up the obfuscation key if the datadir carries one. Files are
// not yet mapped.
blkfile_enumerate :: proc(
	dir: string,
	allocator := context.allocator,
) -> (
	files: []Blk_File,
	err: Error,
) {
	entries, rerr := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if rerr != nil {
		return nil, rerr
	}

	key, xored := blkfile_load_xor_key(dir)

	out := make([dynamic]Blk_File, allocator)
	defer if err != nil {
		for &f in out {delete(f.path, allocator)}
		delete(out)
	}

	for e in entries {
		name := e.name
		if !strings.has_prefix(name, "blk") || !strings.has_suffix(name, ".dat") {
			continue
		}
		num_str := strings.trim_suffix(strings.trim_prefix(name, "blk"), ".dat")
		num, ok := strconv.parse_uint(num_str, 10)
		if !ok {
			continue
		}
		path, perr := strings.concatenate({dir, "/", name}, allocator)
		if perr != nil {
			return nil, os.Error(perr)
		}
		append(&out, Blk_File{file_no = u32(num), path = path, key = key, xored = xored})
	}

	slice.sort_by(out[:], proc(a, b: Blk_File) -> bool {return a.file_no < b.file_no})
	return out[:], nil
}

// blk_payload_bytes returns length bytes at offset, de-obfuscated. For a
// plain datadir this is a zero-copy slice into the mapping; for an XORed
// one the bytes are decoded into buf (resized as needed) and remain valid
// until the buffer's next use.
blk_payload_bytes :: proc(
	f: ^Blk_File,
	offset: u32,
	length: u32,
	buf: ^[dynamic]byte,
) -> (
	payload: []byte,
	err: Error,
) {
	if u64(offset) + u64(length) > u64(len(f.data)) {
		return nil, Corruption.Truncated
	}
	src := f.data[offset:offset + length]
	if !f.xored {
		return src, nil
	}
	resize(buf, int(length))
	blk_xor(buf[:], src, f.key, offset)
	return buf[:], nil
}

// blk_xor de-obfuscates src into dst. The key repeats every 8 bytes keyed
// by ABSOLUTE file offset, so the pattern is a fixed 8-byte cycle once
// rotated to `offset & 7` — which makes it a wide XOR against a repeated
// vector. Every block read on a Core v28+ datadir passes through here,
// including one per input during prevout resolution, so it is worth the
// vector path: a byte-at-a-time loop runs ~1-2 GB/s, this runs ~10x that.
blk_xor :: proc "contextless" (dst, src: []byte, key: [8]u8, offset: u32) {
	VEC :: 32 // 32-byte vectors: AVX2 on x86-64, two NEON registers on arm64
	n := len(src)
	rot := int(offset) & 7

	// Key rotated so that byte 0 of the pattern lines up with src[0].
	pattern: [8]u8
	#no_bounds_check for i in 0 ..< 8 {
		pattern[i] = key[(rot + i) & 7]
	}

	// The vector body needs the pattern replicated; 32 is a multiple of 8,
	// so one broadcast covers it.
	vkey: #simd[VEC]u8
	#no_bounds_check for i in 0 ..< VEC {
		vkey = simd.replace(vkey, u32(i), pattern[i & 7])
	}

	// UNALIGNED access is mandatory: src points into an mmapped blk file at
	// an arbitrary offset. Dereferencing a ^#simd pointer would emit an
	// aligned move (vmovdqa on x86-64) and fault — ARM tolerates it, x86
	// does not.
	i := 0
	#no_bounds_check for ; i + VEC <= n; i += VEC {
		v := intrinsics.unaligned_load((^#simd[VEC]u8)(&src[i]))
		intrinsics.unaligned_store((^#simd[VEC]u8)(&dst[i]), v ~ vkey)
	}
	// Tail: fewer than VEC bytes left.
	#no_bounds_check for ; i < n; i += 1 {
		dst[i] = src[i] ~ pattern[i & 7]
	}
}

// blk_header_prefix returns the first min(89, len) bytes of a record's
// block — enough for the 80-byte header plus the tx-count varint — using
// the caller's stack buffer when decoding is needed.
blk_header_prefix :: proc(f: ^Blk_File, rec: Blk_Record, buf: []byte) -> []byte {
	n := min(len(rec.block), 89)
	if !f.xored {
		return rec.block[:n]
	}
	for i in 0 ..< n {
		buf[i] = rec.block[i] ~ f.key[(int(rec.offset) + i) & 7]
	}
	return buf[:n]
}

blkfiles_destroy :: proc(files: []Blk_File, allocator := context.allocator) {
	for &f in files {
		blkfile_unmap(&f)
		delete(f.path, allocator)
	}
	delete(files, allocator)
}

// blkfile_map maps the file read-only with sequential advice. The size is
// captured here; growth after this point is invisible by design.
blkfile_map :: proc(f: ^Blk_File) -> (err: Error) {
	if f.mapped {
		return nil
	}
	handle := os.open(f.path, {.Read}) or_return
	defer os.close(handle)

	size := os.file_size(handle) or_return
	if size == 0 {
		f.data = nil
		f.mapped = true
		return nil
	}

	fd := posix.FD(os.fd(handle))
	ptr := posix.mmap(nil, c.size_t(size), {.READ}, {.SHARED}, fd, 0)
	if ptr == posix.MAP_FAILED {
		return os.Error(os.General_Error.Invalid_File)
	}
	posix.posix_madvise(ptr, c.size_t(size), .SEQUENTIAL)

	f.data = slice.bytes_from_ptr(ptr, int(size))
	f.mapped = true
	return nil
}

blkfile_unmap :: proc(f: ^Blk_File) {
	if f.mapped && len(f.data) > 0 {
		posix.munmap(raw_data(f.data), c.size_t(len(f.data)))
	}
	f.data = nil
	f.mapped = false
}

// ---------------------------------------------------------------------------
// Record iteration

Blk_Record :: struct {
	file_no: u32,
	offset:  u32, // byte offset of the block payload within the file
	block:   []byte, // slice into the mapping; never copied
}

Blk_Record_Iter :: struct {
	file:  ^Blk_File,
	magic: [4]u8,
	pos:   int,
	err:   Error,
}

blk_record_iter_init :: proc(it: ^Blk_Record_Iter, f: ^Blk_File, magic: [4]u8) {
	it.file = f
	it.magic = magic
	it.pos = 0
	it.err = nil
}

// blk_record_iter_next returns the next record. ok=false at end of data or
// on error; check it.err afterwards. A truncated final record is treated as
// end of data (the live tail may be mid-write under an active Core), never
// an error.
blk_record_iter_next :: proc(it: ^Blk_Record_Iter) -> (rec: Blk_Record, ok: bool) {
	f := it.file
	data := f.data
	for {
		if it.pos + 8 > len(data) {
			return {}, false
		}
		// The preallocated tail of the newest file is raw zeros on disk —
		// Core's obfuscation only XORs bytes it actually writes — so the
		// end-of-data check must look at the raw bytes BEFORE decoding.
		raw := data[it.pos:it.pos + 4]
		if raw[0] == 0 && raw[1] == 0 && raw[2] == 0 && raw[3] == 0 {
			return {}, false
		}

		// De-obfuscate the 8 framing bytes (magic + size); the block
		// payload itself stays encoded until a blk_* helper decodes it.
		frame: [8]byte
		copy(frame[:], data[it.pos:it.pos + 8])
		if f.xored {
			for &b, i in frame {
				b ~= f.key[(it.pos + i) & 7]
			}
		}
		m := frame[:4]
		if m[0] == 0 && m[1] == 0 && m[2] == 0 && m[3] == 0 {
			// Zero magic after decoding: explicitly written zero padding.
			return {}, false
		}
		if m[0] != it.magic[0] || m[1] != it.magic[1] || m[2] != it.magic[2] || m[3] != it.magic[3] {
			it.err = Corruption.Bad_Magic
			return {}, false
		}
		size := int(u32(frame[4]) | u32(frame[5]) << 8 | u32(frame[6]) << 16 | u32(frame[7]) << 24)
		if size < 80 {
			it.err = Corruption.Bad_Record
			return {}, false
		}
		start := it.pos + 8
		if start + size > len(data) {
			// Torn tail: a record extending past the captured size.
			return {}, false
		}
		rec = Blk_Record {
			file_no = it.file.file_no,
			offset  = u32(start),
			block   = data[start:start + size],
		}
		it.pos = start + size
		return rec, true
	}
}

