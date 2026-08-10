package hugin

// Transaction byte-walker. Walks the bytes, emits views, retains nothing —
// no Transaction struct is ever built. Every slice points into the mmapped
// block; nothing is copied.
//
// Wire format:
//   version i32
//   [marker 0x00, flag 0x01]           segwit only
//   input count varint
//     prev_txid 32 | vout u32 | script_len varint | script | sequence u32
//   output count varint
//     value u64 | script_len varint | script
//   [witness: per input, item count varint, items (len varint | bytes)]
//   locktime u32
//
// The txid is double-SHA256 over the NON-witness serialization: version,
// inputs, outputs, locktime — marker, flag, and witness excluded.

Tx :: struct {
	txid:        [32]u8,
	raw:         []byte, // full tx bytes including witness, into the mapping
	offset:      u32, // byte offset of the tx within the block payload
	is_coinbase: bool,
	segwit:      bool,
	vsize:       int, // virtual size: (3*stripped + total + 3) / 4
	weight:      int, // 3*stripped + total
	witness_off: int, // offset in raw of the witness section (segwit only)
	n_inputs:    int,
	n_outputs:   int,
	inputs_off:  int, // offset in raw of the first input (after the count)
	outputs_off: int, // offset in raw of the first output (after the count)
}

Tx_Input :: struct {
	prev_txid: [32]u8,
	vout:      u32,
	script:    []byte, // scriptSig, into the mapping
	sequence:  u32,
}

Tx_Output :: struct {
	value:  u64, // satoshis
	script: []byte, // scriptPubKey, into the mapping
}

// Tx_Iter walks the transactions of one block payload.
Tx_Iter :: struct {
	block:     []byte, // full block payload (header + count + txs)
	pos:       int,
	index:     int, // tx index within the block
	count:     int,
	err:       Error,
	skip_txid: bool, // zero value computes txids; set to walk hash-free
}

tx_iter_init :: proc(it: ^Tx_Iter, block: []byte) -> Error {
	if len(block) < 81 {
		return Corruption.Bad_Transaction
	}
	count, n := compact_size(block[80:])
	if n == 0 {
		return Corruption.Bad_Transaction
	}
	it.block = block
	it.pos = 80 + n
	it.index = 0
	it.count = int(count)
	it.err = nil
	return nil
}

// tx_iter_next walks one transaction. ok=false at the end or on error;
// check it.err.
tx_iter_next :: proc(it: ^Tx_Iter) -> (tx: Tx, ok: bool) {
	if it.index >= it.count {
		return {}, false
	}
	data := it.block
	start := it.pos

	consumed: int
	tx, consumed = tx_parse(data[start:], it.index == 0, !it.skip_txid)
	if consumed == 0 {
		it.err = Corruption.Bad_Transaction
		return {}, false
	}
	tx.offset = u32(start)
	it.pos = start + consumed
	it.index += 1
	if it.index == it.count && it.pos != len(data) {
		// Trailing bytes after the last tx: framing disagrees with content.
		it.err = Corruption.Bad_Transaction
		return {}, false
	}
	return tx, true
}

// tx_parse walks one transaction at the start of data. consumed = 0 on any
// malformation. Computes the txid.
tx_parse :: proc(data: []byte, coinbase_position: bool, want_txid := true) -> (tx: Tx, consumed: int) {
	if len(data) < 10 {
		return {}, 0
	}
	pos := 4 // version

	segwit := false
	if data[pos] == 0x00 {
		// Legacy txs cannot have zero inputs, so 0x00 here is the segwit
		// marker.
		if data[pos + 1] != 0x01 {
			return {}, 0
		}
		segwit = true
		pos += 2
	}

	inputs_count_off := pos
	n_inputs_u, n0 := compact_size(data[pos:])
	if n0 == 0 {return {}, 0}
	pos += n0
	n_inputs := int(n_inputs_u)
	if n_inputs <= 0 || n_inputs > len(data) {return {}, 0}

	inputs_off := pos
	for _ in 0 ..< n_inputs {
		if pos + 36 > len(data) {return {}, 0}
		pos += 36
		slen, sn := compact_size(data[pos:])
		if sn == 0 {return {}, 0}
		pos += sn
		if slen > u64(len(data) - pos) {return {}, 0}
		pos += int(slen)
		if pos + 4 > len(data) {return {}, 0}
		pos += 4 // sequence
	}

	n_outputs_u, n1 := compact_size(data[pos:])
	if n1 == 0 {return {}, 0}
	pos += n1
	n_outputs := int(n_outputs_u)
	if n_outputs <= 0 || n_outputs > len(data) {return {}, 0}

	outputs_off := pos
	for _ in 0 ..< n_outputs {
		if pos + 8 > len(data) {return {}, 0}
		pos += 8
		slen, sn := compact_size(data[pos:])
		if sn == 0 {return {}, 0}
		pos += sn
		if slen > u64(len(data) - pos) {return {}, 0}
		pos += int(slen)
	}

	witness_off := pos
	if segwit {
		for _ in 0 ..< n_inputs {
			n_items, wn := compact_size(data[pos:])
			if wn == 0 {return {}, 0}
			pos += wn
			for _ in 0 ..< n_items {
				ilen, iln := compact_size(data[pos:])
				if iln == 0 {return {}, 0}
				pos += iln
				if ilen > u64(len(data) - pos) {return {}, 0}
				pos += int(ilen)
			}
		}
	}

	if pos + 4 > len(data) {return {}, 0}
	locktime_off := pos
	pos += 4

	tx.raw = data[:pos]
	tx.segwit = segwit
	tx.witness_off = witness_off
	if segwit {
		stripped := 4 + (witness_off - inputs_count_off) + 4
		tx.weight = stripped * 3 + pos
		tx.vsize = (tx.weight + 3) / 4
	} else {
		tx.weight = pos * 4
		tx.vsize = pos
	}
	tx.n_inputs = n_inputs
	tx.n_outputs = n_outputs
	tx.inputs_off = inputs_off
	tx.outputs_off = outputs_off

	// Coinbase: single input from the all-zero txid with vout 0xffffffff.
	if coinbase_position && n_inputs == 1 {
		all_zero := true
		for b in data[inputs_off:inputs_off + 32] {
			if b != 0 {all_zero = false; break}
		}
		if all_zero {
			vout := get_u32le(data[inputs_off + 32:])
			tx.is_coinbase = vout == 0xFFFFFFFF
		}
	}

	// txid over the non-witness serialization. Callers walking a block to
	// a known position skip this — hashing every stepped-over transaction
	// dominates the walk otherwise.
	if !want_txid {
		return tx, pos
	}
	if segwit {
		tx.txid = sha256d_parts(
			{data[:4], data[inputs_count_off:witness_off], data[locktime_off:pos]},
		)
	} else {
		tx.txid = sha256d(data[:pos])
	}
	return tx, pos
}

// ---------------------------------------------------------------------------
// Input/output iteration over an already-validated Tx. These re-walk the
// verified bytes, so bounds are trusted.

Tx_Input_Iter :: struct {
	tx:  ^Tx,
	pos: int,
	i:   int,
}

tx_input_iter_init :: proc(it: ^Tx_Input_Iter, tx: ^Tx) {
	it.tx = tx
	it.pos = tx.inputs_off
	it.i = 0
}

tx_input_iter_next :: proc(it: ^Tx_Input_Iter) -> (input: Tx_Input, vin: int, ok: bool) {
	if it.i >= it.tx.n_inputs {
		return {}, 0, false
	}
	raw := it.tx.raw
	copy(input.prev_txid[:], raw[it.pos:it.pos + 32])
	input.vout = get_u32le(raw[it.pos + 32:])
	pos := it.pos + 36
	slen, sn := compact_size(raw[pos:])
	pos += sn
	input.script = raw[pos:pos + int(slen)]
	pos += int(slen)
	input.sequence = get_u32le(raw[pos:])
	pos += 4
	it.pos = pos
	vin = it.i
	it.i += 1
	return input, vin, true
}

Tx_Output_Iter :: struct {
	tx:  ^Tx,
	pos: int,
	i:   int,
}

tx_output_iter_init :: proc(it: ^Tx_Output_Iter, tx: ^Tx) {
	it.tx = tx
	it.pos = tx.outputs_off
	it.i = 0
}

tx_output_iter_next :: proc(it: ^Tx_Output_Iter) -> (output: Tx_Output, vout: int, ok: bool) {
	if it.i >= it.tx.n_outputs {
		return {}, 0, false
	}
	raw := it.tx.raw
	output.value = get_u64le(raw[it.pos:])
	pos := it.pos + 8
	slen, sn := compact_size(raw[pos:])
	pos += sn
	output.script = raw[pos:pos + int(slen)]
	pos += int(slen)
	it.pos = pos
	vout = it.i
	it.i += 1
	return output, vout, true
}
