package hugin

// Header parse, DAG construction, cumulative-work chain selection.
//
// This is chain *selection*, not reorg handling: the blk files already
// contain the answer, we just have to find the most-work tip and walk back.

import "core:log"

Header_Entry :: struct {
	hash:    [32]u8,
	prev:    [32]u8,
	raw:     [80]u8,
	file_no: u32,
	offset:  u32, // byte offset of the block payload within the file
	length:  u32,
	tx_count: u32,
}

// header_entry_from_record parses the 80-byte header plus the tx-count
// varint out of a framed block record, de-obfuscating through the owning
// file's key when needed.
header_entry_from_record :: proc(f: ^Blk_File, rec: Blk_Record) -> (e: Header_Entry, err: Error) {
	pbuf: [89]byte
	prefix := blk_header_prefix(f, rec, pbuf[:])
	if len(prefix) < 81 {
		return {}, Corruption.Bad_Header
	}
	copy(e.raw[:], prefix[:80])
	copy(e.prev[:], prefix[4:36])
	e.hash = sha256d(prefix[:80])
	e.file_no = rec.file_no
	e.offset = rec.offset
	e.length = u32(len(rec.block))

	count, n := compact_size(prefix[80:])
	if n == 0 {
		return {}, Corruption.Bad_Header
	}
	if count > u64(max(u32)) {
		return {}, Corruption.Bad_Header
	}
	e.tx_count = u32(count)
	return e, nil
}

// compact_size decodes Bitcoin's CompactSize varint. n = 0 on truncation.
compact_size :: proc "contextless" (buf: []byte) -> (x: u64, n: int) {
	if len(buf) < 1 {return 0, 0}
	switch buf[0] {
	case 0 ..= 0xFC:
		return u64(buf[0]), 1
	case 0xFD:
		if len(buf) < 3 {return 0, 0}
		return u64(buf[1]) | u64(buf[2]) << 8, 3
	case 0xFE:
		if len(buf) < 5 {return 0, 0}
		return u64(buf[1]) | u64(buf[2]) << 8 | u64(buf[3]) << 16 | u64(buf[4]) << 24, 5
	case:
		if len(buf) < 9 {return 0, 0}
		return u64(buf[1]) |
			u64(buf[2]) << 8 |
			u64(buf[3]) << 16 |
			u64(buf[4]) << 24 |
			u64(buf[5]) << 32 |
			u64(buf[6]) << 40 |
			u64(buf[7]) << 48 |
			u64(buf[8]) << 56,
			9
	}
}

// ---------------------------------------------------------------------------
// Work

// work_from_bits computes 2^256 / (target + 1) exactly, the per-block work
// used for chain selection, from the compact nBits encoding. Returns 0 for
// a malformed target; callers treat such headers as unconnectable.
work_from_bits :: proc "contextless" (bits: u32) -> u128 {
	exponent := int(bits >> 24)
	mantissa := u64(bits & 0x007FFFFF)
	if bits & 0x00800000 != 0 {
		return 0 // negative target: invalid
	}
	if mantissa == 0 {
		return 0
	}
	// target = mantissa << (8*(exponent-3)); reject overflow past 256 bits.
	shift := 8 * (exponent - 3)
	if shift < 0 {
		mantissa >>= uint(-shift)
		shift = 0
		if mantissa == 0 {return 0}
	}
	// Number of significant bits of the target.
	msb := 63
	for msb > 0 && mantissa >> uint(msb) == 0 {msb -= 1}
	if shift + msb + 1 > 256 {
		return 0 // target wider than 256 bits
	}

	// Long division: floor(2^256 / d) where d = (mantissa << shift) + 1,
	// bitwise over the 257-bit dividend (a single 1 followed by 256
	// zeros). d and the remainder fit in 256 bits; the quotient can only
	// exceed u128 if the target is below 2^128, which no real chain
	// approaches — clamp defensively.
	d: [4]u64 // little-endian limbs of the divisor
	limb := shift / 64
	off := uint(shift % 64)
	d[limb] |= mantissa << off
	if off > 0 && limb + 1 < 4 {
		hi := mantissa >> (64 - off)
		if hi != 0 {d[limb + 1] |= hi}
	}
	// +1
	carry: u64 = 1
	for i in 0 ..< 4 {
		d[i] += carry
		carry = 1 if d[i] == 0 && carry == 1 else 0
		if carry == 0 {break}
	}

	r: [4]u64 // remainder
	q: u128
	for i := 256; i >= 0; i -= 1 {
		// r = r << 1 | bit_i(2^256)  (bit 256 is the only set bit)
		r[3] = r[3] << 1 | r[2] >> 63
		r[2] = r[2] << 1 | r[1] >> 63
		r[1] = r[1] << 1 | r[0] >> 63
		r[0] = r[0] << 1
		if i == 256 {
			r[0] |= 1
		}

		// if r >= d { r -= d; q |= 1 << i }
		ge := true
		for j := 3; j >= 0; j -= 1 {
			if r[j] > d[j] {break}
			if r[j] < d[j] {ge = false; break}
		}
		if ge {
			borrow: u64
			for j in 0 ..< 4 {
				v := r[j] - d[j] - borrow
				// Borrow out of limb j: r[j] < d[j], or equal with an
				// incoming borrow.
				if r[j] < d[j] || (r[j] == d[j] && borrow == 1) {
					borrow = 1
				} else {
					borrow = 0
				}
				r[j] = v
			}
			if i < 128 {
				q |= u128(1) << uint(i)
			} else {
				// Quotient exceeds u128: clamp. Unreachable for any real
				// difficulty target.
				return max(u128)
			}
		}
	}
	return q
}

// ---------------------------------------------------------------------------
// DAG and selection

Header_Dag :: struct {
	entries: [dynamic]Header_Entry,
	by_hash: map[[32]u8]int, // hash -> index into entries
}

header_dag_init :: proc(dag: ^Header_Dag, allocator := context.allocator) {
	dag.entries = make([dynamic]Header_Entry, allocator)
	dag.by_hash = make(map[[32]u8]int, allocator)
}

header_dag_destroy :: proc(dag: ^Header_Dag) {
	delete(dag.entries)
	delete(dag.by_hash)
}

// header_dag_add inserts an entry, ignoring duplicates (the same block can
// appear twice in the files after a Core re-download).
header_dag_add :: proc(dag: ^Header_Dag, e: Header_Entry) {
	if e.hash in dag.by_hash {
		return
	}
	append(&dag.entries, e)
	dag.by_hash[e.hash] = len(dag.entries) - 1
}

// header_dag_select_chain computes cumulative work for every connectable
// entry, picks the most-work tip, and returns entry indices ordered from
// genesis to tip.
header_dag_select_chain :: proc(
	dag: ^Header_Dag,
	allocator := context.allocator,
) -> (
	chain: []int,
	err: Error,
) {
	n := len(dag.entries)
	if n == 0 {
		return nil, Corruption.Bad_Header
	}

	ZERO_HASH: [32]u8

	cumwork := make([]u128, n, context.temp_allocator)
	state := make([]u8, n, context.temp_allocator) // 0 unknown, 1 resolved, 2 unconnectable

	stack := make([dynamic]int, context.temp_allocator)

	for start in 0 ..< n {
		if state[start] != 0 {continue}
		// Walk back to a resolved ancestor or genesis, then unwind.
		clear(&stack)
		append(&stack, start)
		for len(stack) > 0 {
			i := stack[len(stack) - 1]
			e := &dag.entries[i]
			if state[i] != 0 {
				resize(&stack, len(stack) - 1)
				continue
			}
			w := work_from_bits(bits_of(e))
			if w == 0 {
				state[i] = 2
				resize(&stack, len(stack) - 1)
				continue
			}
			if e.prev == ZERO_HASH {
				cumwork[i] = w
				state[i] = 1
				resize(&stack, len(stack) - 1)
				continue
			}
			pi, ok := dag.by_hash[e.prev]
			if !ok {
				state[i] = 2 // parent not on disk: pruned or foreign
				resize(&stack, len(stack) - 1)
				continue
			}
			switch state[pi] {
			case 1:
				cumwork[i] = cumwork[pi] + w
				state[i] = 1
				resize(&stack, len(stack) - 1)
			case 2:
				state[i] = 2
				resize(&stack, len(stack) - 1)
			case:
				append(&stack, pi)
			}
		}
	}

	best := -1
	for i in 0 ..< n {
		if state[i] != 1 {continue}
		if best < 0 || cumwork[i] > cumwork[best] {
			best = i
		}
	}
	if best < 0 {
		return nil, Corruption.Bad_Header
	}

	// Walk back from the tip collecting the path.
	path := make([dynamic]int, allocator)
	i := best
	for {
		append(&path, i)
		e := &dag.entries[i]
		if e.prev == ZERO_HASH {
			break
		}
		pi, ok := dag.by_hash[e.prev]
		if !ok {
			// Unreachable: tip resolved means every ancestor resolved.
			delete(path)
			return nil, Corruption.Bad_Header
		}
		i = pi
	}
	// Reverse in place: genesis first.
	for a, b := 0, len(path) - 1; a < b; a, b = a + 1, b - 1 {
		path[a], path[b] = path[b], path[a]
	}

	// Every catch-up cycle selects; only the cycle that finds a NEW tip is
	// worth an operator's attention (catchup logs that one).
	log.debugf(
		"hugin: selected chain height %d, tip work %v, %d orphans",
		len(path) - 1,
		cumwork[best],
		n - len(path),
	)
	return path[:], nil
}

@(private = "file")
bits_of :: proc(e: ^Header_Entry) -> u32 {
	return u32(e.raw[72]) | u32(e.raw[73]) << 8 | u32(e.raw[74]) << 16 | u32(e.raw[75]) << 24
}
