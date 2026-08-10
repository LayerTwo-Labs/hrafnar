package munin

// Per-run bloom filter over a key prefix.
//
// The workload is seek(prefix)-then-scan; a full-key filter cannot answer
// "does this run contain anything starting with P", so the filter hashes
// key[:prefix_len].
//
// Payload layout (§2.4):
//   prefix_len u32 | num_probes u32 | num_bits u32 | bit array
//
// Hash: XXH64 of the prefix, split into two 32-bit halves for double
// hashing (h_i = h1 + i*h2).

import "core:hash/xxhash"

FILTER_HEADER_SIZE :: 12

Filter_Builder :: struct {
	prefix_len:   int,
	bits_per_key: int,
	hashes:       [dynamic]u64,
	last_prefix:  [dynamic]byte,
	has_last:     bool,
	payload:      [dynamic]byte,
}

filter_builder_init :: proc(
	fb: ^Filter_Builder,
	prefix_len: int,
	bits_per_key: int,
	allocator := context.allocator,
) {
	fb.prefix_len = prefix_len
	fb.bits_per_key = bits_per_key
	fb.hashes = make([dynamic]u64, allocator)
	fb.last_prefix = make([dynamic]byte, allocator)
	fb.has_last = false
	fb.payload = make([dynamic]byte, allocator)
}

filter_builder_destroy :: proc(fb: ^Filter_Builder) {
	delete(fb.hashes)
	delete(fb.last_prefix)
	delete(fb.payload)
}

// filter_builder_add records the key's prefix. Keys arrive sorted, so equal
// prefixes are adjacent and deduplicate with a single comparison.
filter_builder_add :: proc(fb: ^Filter_Builder, key: []byte) {
	p := key[:min(len(key), fb.prefix_len)]
	if fb.has_last && len(p) == len(fb.last_prefix) {
		same := true
		for b, i in p {
			if fb.last_prefix[i] != b {
				same = false
				break
			}
		}
		if same {return}
	}
	append(&fb.hashes, xxhash.XXH64(p, 0))
	resize(&fb.last_prefix, len(p))
	copy(fb.last_prefix[:], p)
	fb.has_last = true
}

// filter_builder_finish builds the filter payload, borrowed from the
// builder until destroy.
filter_builder_finish :: proc(fb: ^Filter_Builder) -> []byte {
	n := len(fb.hashes)
	num_bits := max(64, n * fb.bits_per_key)
	num_probes := clamp(int(f64(fb.bits_per_key) * 0.693147 + 0.5), 1, 30)

	resize(&fb.payload, FILTER_HEADER_SIZE + (num_bits + 7) / 8)
	for &b in fb.payload {b = 0}
	put_u32le(fb.payload[0:], u32(fb.prefix_len))
	put_u32le(fb.payload[4:], u32(num_probes))
	put_u32le(fb.payload[8:], u32(num_bits))

	bits := fb.payload[FILTER_HEADER_SIZE:]
	for h in fb.hashes {
		h1 := u32(h)
		h2 := u32(h >> 32)
		for i in 0 ..< num_probes {
			bit := (h1 + u32(i) * h2) % u32(num_bits)
			bits[bit / 8] |= 1 << (bit % 8)
		}
	}
	return fb.payload[:]
}

// ---------------------------------------------------------------------------

Filter :: struct {
	prefix_len: int,
	num_probes: int,
	num_bits:   int,
	bits:       []byte, // borrowed from the run's filter payload
}

filter_init :: proc(f: ^Filter, payload: []byte) -> Error {
	if len(payload) < FILTER_HEADER_SIZE {
		return Corruption.Bad_Block
	}
	f.prefix_len = int(get_u32le(payload[0:]))
	f.num_probes = int(get_u32le(payload[4:]))
	f.num_bits = int(get_u32le(payload[8:]))
	if f.num_probes < 1 || f.num_bits < 1 {
		return Corruption.Bad_Block
	}
	if len(payload) - FILTER_HEADER_SIZE < (f.num_bits + 7) / 8 {
		return Corruption.Bad_Block
	}
	f.bits = payload[FILTER_HEADER_SIZE:]
	return nil
}

// filter_may_contain_prefix reports whether any indexed key had this
// prefix. False positives at the configured rate; never false negatives.
// The query must pass exactly the prefix that was indexed: key[:prefix_len]
// (or the whole key if shorter).
filter_may_contain_prefix :: proc(f: ^Filter, prefix: []byte) -> bool {
	h := xxhash.XXH64(prefix, 0)
	h1 := u32(h)
	h2 := u32(h >> 32)
	for i in 0 ..< f.num_probes {
		bit := (h1 + u32(i) * h2) % u32(f.num_bits)
		if f.bits[bit / 8] & (1 << (bit % 8)) == 0 {
			return false
		}
	}
	return true
}

// filter_check applies the filter to a lookup key, truncating to the
// filter's prefix length the same way the builder did.
filter_check :: proc(f: ^Filter, key: []byte) -> bool {
	return filter_may_contain_prefix(f, key[:min(len(key), f.prefix_len)])
}
