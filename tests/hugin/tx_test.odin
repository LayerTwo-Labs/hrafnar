package hugin_tests

// Transaction walker and script classification tests, on synthetic
// transactions serialized independently by the test.

import "core:bytes"
import "core:math/rand"
import "core:testing"

import hugin "../../hugin"

Test_Input :: struct {
	prev_txid: [32]u8,
	vout:      u32,
	script:   []byte,
	witness:  [][]byte, // nil = no witness items for this input
}

Test_Output :: struct {
	value:  u64,
	script: []byte,
}

@(private = "file")
put_compact :: proc(buf: ^[dynamic]byte, x: u64) {
	switch {
	case x <= 0xFC:
		append(buf, byte(x))
	case x <= 0xFFFF:
		append(buf, 0xFD, byte(x), byte(x >> 8))
	case x <= 0xFFFFFFFF:
		append(buf, 0xFE, byte(x), byte(x >> 8), byte(x >> 16), byte(x >> 24))
	case:
		append(buf, 0xFF)
		for i in 0 ..< 8 {append(buf, byte(x >> uint(8 * i)))}
	}
}

@(private = "file")
put_u32 :: proc(buf: ^[dynamic]byte, x: u32) {
	append(buf, byte(x), byte(x >> 8), byte(x >> 16), byte(x >> 24))
}

@(private = "file")
put_u64 :: proc(buf: ^[dynamic]byte, x: u64) {
	for i in 0 ..< 8 {append(buf, byte(x >> uint(8 * i)))}
}

// build_tx serializes a transaction both in full (with witness if any
// input has one) and in non-witness form. The walker's txid must equal
// sha256d of the latter.
@(private = "file")
build_tx :: proc(
	inputs: []Test_Input,
	outputs: []Test_Output,
	full: ^[dynamic]byte,
	nonwitness: ^[dynamic]byte,
) {
	segwit := false
	for inp in inputs {
		if inp.witness != nil {segwit = true}
	}

	clear(full)
	clear(nonwitness)

	core := make([dynamic]byte, context.temp_allocator)
	// inputs
	put_compact(&core, u64(len(inputs)))
	for inp in inputs {
		inp := inp
		append(&core, ..inp.prev_txid[:])
		put_u32(&core, inp.vout)
		put_compact(&core, u64(len(inp.script)))
		append(&core, ..inp.script)
		put_u32(&core, 0xFFFFFFFE) // sequence
	}
	// outputs
	put_compact(&core, u64(len(outputs)))
	for out in outputs {
		put_u64(&core, out.value)
		put_compact(&core, u64(len(out.script)))
		append(&core, ..out.script)
	}

	// non-witness serialization
	put_u32(nonwitness, 2) // version
	append(nonwitness, ..core[:])
	put_u32(nonwitness, 0) // locktime

	// full serialization
	put_u32(full, 2)
	if segwit {
		append(full, 0x00, 0x01)
	}
	append(full, ..core[:])
	if segwit {
		for inp in inputs {
			put_compact(full, u64(len(inp.witness)))
			for item in inp.witness {
				put_compact(full, u64(len(item)))
				append(full, ..item)
			}
		}
	}
	put_u32(full, 0)
}

@(private = "file")
rand_txid :: proc() -> (h: [32]u8) {
	for &b in h {b = byte(rand.int_max(256))}
	return
}

@(test)
test_tx_walker_legacy :: proc(t: ^testing.T) {
	full := make([dynamic]byte)
	nonwit := make([dynamic]byte)
	defer {delete(full); delete(nonwit)}

	sig := []byte{0x48, 1, 2, 3}
	spk := []byte{hugin.OP_DUP, hugin.OP_HASH160, 20, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, hugin.OP_EQUALVERIFY, hugin.OP_CHECKSIG}
	inputs := []Test_Input{{prev_txid = rand_txid(), vout = 3, script = sig}}
	outputs := []Test_Output{{value = 5_000_000_000, script = spk}}
	build_tx(inputs, outputs, &full, &nonwit)

	tx, consumed := hugin.tx_parse(full[:], false)
	testing.expect_value(t, consumed, len(full))
	testing.expect_value(t, tx.segwit, false)
	testing.expect_value(t, tx.is_coinbase, false)
	testing.expect_value(t, tx.n_inputs, 1)
	testing.expect_value(t, tx.n_outputs, 1)
	testing.expect_value(t, tx.txid, hugin.sha256d(nonwit[:]))

	iit: hugin.Tx_Input_Iter
	hugin.tx_input_iter_init(&iit, &tx)
	inp, vin, ok := hugin.tx_input_iter_next(&iit)
	testing.expect(t, ok)
	testing.expect_value(t, vin, 0)
	testing.expect_value(t, inp.prev_txid, inputs[0].prev_txid)
	testing.expect_value(t, inp.vout, u32(3))
	testing.expect(t, bytes.compare(inp.script, sig) == 0)
	_, _, ok = hugin.tx_input_iter_next(&iit)
	testing.expect(t, !ok)

	oit: hugin.Tx_Output_Iter
	hugin.tx_output_iter_init(&oit, &tx)
	out, vout, ook := hugin.tx_output_iter_next(&oit)
	testing.expect(t, ook)
	testing.expect_value(t, vout, 0)
	testing.expect_value(t, out.value, u64(5_000_000_000))
	testing.expect(t, bytes.compare(out.script, spk) == 0)
}

@(test)
test_tx_walker_segwit :: proc(t: ^testing.T) {
	full := make([dynamic]byte)
	nonwit := make([dynamic]byte)
	defer {delete(full); delete(nonwit)}

	wit0 := [][]byte{{0x30, 0x44, 1, 2}, {0x02, 0xAA, 0xBB}}
	spk1 := []byte{hugin.OP_0, 20, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}
	spk2 := []byte{hugin.OP_1, 32, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32}
	inputs := []Test_Input {
		{prev_txid = rand_txid(), vout = 0, script = nil, witness = wit0},
		{prev_txid = rand_txid(), vout = 7, script = nil, witness = [][]byte{}},
	}
	outputs := []Test_Output{{value = 1234, script = spk1}, {value = 999_999, script = spk2}}
	build_tx(inputs, outputs, &full, &nonwit)

	tx, consumed := hugin.tx_parse(full[:], false)
	testing.expect_value(t, consumed, len(full))
	testing.expect_value(t, tx.segwit, true)
	testing.expect_value(t, tx.n_inputs, 2)
	testing.expect_value(t, tx.n_outputs, 2)
	// The whole point: witness excluded from the txid.
	testing.expect_value(t, tx.txid, hugin.sha256d(nonwit[:]))

	oit: hugin.Tx_Output_Iter
	hugin.tx_output_iter_init(&oit, &tx)
	out0, _, _ := hugin.tx_output_iter_next(&oit)
	out1, _, ok1 := hugin.tx_output_iter_next(&oit)
	testing.expect(t, ok1)
	testing.expect_value(t, out0.value, u64(1234))
	testing.expect_value(t, out1.value, u64(999_999))
	testing.expect_value(t, hugin.script_classify(out0.script), hugin.Script_Class.P2WPKH)
	testing.expect_value(t, hugin.script_classify(out1.script), hugin.Script_Class.P2TR)
}

@(test)
test_tx_coinbase_detection :: proc(t: ^testing.T) {
	full := make([dynamic]byte)
	nonwit := make([dynamic]byte)
	defer {delete(full); delete(nonwit)}

	cb_script := []byte{4, 0xDE, 0xAD, 0xBE, 0xEF}
	inputs := []Test_Input{{prev_txid = {}, vout = 0xFFFFFFFF, script = cb_script}}
	outputs := []Test_Output{{value = 50 * 100_000_000, script = []byte{0x51}}}
	build_tx(inputs, outputs, &full, &nonwit)

	// Position 0 in the block: coinbase.
	tx, consumed := hugin.tx_parse(full[:], true)
	testing.expect(t, consumed > 0)
	testing.expect_value(t, tx.is_coinbase, true)

	// Same bytes not at position 0: not a coinbase.
	tx2, _ := hugin.tx_parse(full[:], false)
	testing.expect_value(t, tx2.is_coinbase, false)
}

@(test)
test_tx_block_iteration :: proc(t: ^testing.T) {
	// Assemble a synthetic block: 80-byte header + count + 3 txs.
	block := make([dynamic]byte)
	defer delete(block)
	for i in 0 ..< 80 {append(&block, byte(i))}
	append(&block, 3) // tx count

	txids: [3][32]u8
	full := make([dynamic]byte)
	nonwit := make([dynamic]byte)
	defer {delete(full); delete(nonwit)}
	for i in 0 ..< 3 {
		inputs := []Test_Input {
			{
				prev_txid = rand_txid() if i > 0 else {},
				vout      = 0xFFFFFFFF if i == 0 else u32(i),
				script    = {1, 2, 3},
				witness   = [][]byte{{0xAA}} if i == 2 else nil,
			},
		}
		outputs := []Test_Output{{value = u64(i * 1000), script = {hugin.OP_RETURN, 4, 1, 2, 3, 4}}}
		build_tx(inputs, outputs, &full, &nonwit)
		append(&block, ..full[:])
		txids[i] = hugin.sha256d(nonwit[:])
	}

	it: hugin.Tx_Iter
	testing.expect_value(t, hugin.tx_iter_init(&it, block[:]), nil)
	count := 0
	for {
		tx, ok := hugin.tx_iter_next(&it)
		if !ok {break}
		testing.expect_value(t, tx.txid, txids[count])
		testing.expect_value(t, tx.is_coinbase, count == 0)
		count += 1
	}
	testing.expect_value(t, it.err, nil)
	testing.expect_value(t, count, 3)

	// Truncating the block anywhere inside the tx region must produce a
	// clean error, never a panic.
	for cut in 82 ..< len(block) {
		tit: hugin.Tx_Iter
		if hugin.tx_iter_init(&tit, block[:cut]) != nil {continue}
		for {
			_, ok := hugin.tx_iter_next(&tit)
			if !ok {break}
		}
		// Either it errored or it stopped early; both are fine as long as
		// nothing crashed. A full parse of truncated data must not succeed:
		if tit.err == nil {
			testing.expect(t, tit.index < 3, "truncated block cannot yield all txs")
		}
	}
}

@(test)
test_script_classification :: proc(t: ^testing.T) {
	p2pkh := []byte{hugin.OP_DUP, hugin.OP_HASH160, 20, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, hugin.OP_EQUALVERIFY, hugin.OP_CHECKSIG}
	testing.expect_value(t, hugin.script_classify(p2pkh), hugin.Script_Class.P2PKH)
	testing.expect_value(t, len(hugin.script_payload(p2pkh, .P2PKH)), 20)

	p2sh := []byte{hugin.OP_HASH160, 20, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, hugin.OP_EQUAL}
	testing.expect_value(t, hugin.script_classify(p2sh), hugin.Script_Class.P2SH)

	p2wpkh := make([]byte, 22)
	defer delete(p2wpkh)
	p2wpkh[0] = hugin.OP_0
	p2wpkh[1] = 20
	testing.expect_value(t, hugin.script_classify(p2wpkh), hugin.Script_Class.P2WPKH)

	p2wsh := make([]byte, 34)
	defer delete(p2wsh)
	p2wsh[0] = hugin.OP_0
	p2wsh[1] = 32
	testing.expect_value(t, hugin.script_classify(p2wsh), hugin.Script_Class.P2WSH)

	p2tr := make([]byte, 34)
	defer delete(p2tr)
	p2tr[0] = hugin.OP_1
	p2tr[1] = 32
	testing.expect_value(t, hugin.script_classify(p2tr), hugin.Script_Class.P2TR)

	p2pk := make([]byte, 35)
	defer delete(p2pk)
	p2pk[0] = 33
	p2pk[34] = hugin.OP_CHECKSIG
	testing.expect_value(t, hugin.script_classify(p2pk), hugin.Script_Class.P2PK)

	opret := []byte{hugin.OP_RETURN, 2, 0xAB, 0xCD}
	testing.expect_value(t, hugin.script_classify(opret), hugin.Script_Class.Op_Return)

	weird := []byte{0xFF, 0xFE, 0xFD}
	testing.expect_value(t, hugin.script_classify(weird), hugin.Script_Class.Nonstandard)

	// Scripthash is defined for every script, standard or not.
	testing.expect_value(t, hugin.scripthash(weird), hugin.sha256(weird))
	empty: []byte
	testing.expect_value(t, hugin.scripthash(empty), hugin.sha256(empty))
}
