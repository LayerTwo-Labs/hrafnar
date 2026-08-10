package hugin_tests

// End-to-end pipeline test on a synthetic chain: blocks with real spend
// graphs written into blk files, indexed with build_index, then verified
// through the Munin databases directly.

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"

import hugin "../../hugin"

// --- little serialization helpers (legacy txs only) ------------------------

bb_u32 :: proc(buf: ^[dynamic]byte, x: u32) {
	append(buf, byte(x), byte(x >> 8), byte(x >> 16), byte(x >> 24))
}

bb_u64 :: proc(buf: ^[dynamic]byte, x: u64) {
	for i in 0 ..< 8 {append(buf, byte(x >> uint(8 * i)))}
}

Outpoint :: struct {
	txid: [32]u8,
	vout: u32,
}

BB_Input :: struct {
	prev: Outpoint,
}

BB_Output :: struct {
	value:  u64,
	script: []byte,
}

// bb_tx builds a legacy transaction and returns (bytes, txid).
bb_tx :: proc(
	inputs: []BB_Input,
	outputs: []BB_Output,
	coinbase_tag: u32 = 0,
) -> (
	raw: []byte,
	txid: [32]u8,
) {
	buf := make([dynamic]byte)
	bb_u32(&buf, 2)
	if len(inputs) == 0 {
		// coinbase: one all-zero input
		append(&buf, 1)
		for _ in 0 ..< 32 {append(&buf, 0)}
		bb_u32(&buf, 0xFFFFFFFF)
		// scriptSig carries the tag so identical-looking coinbases differ
		// unless the caller wants BIP-30 twins (same tag).
		append(&buf, 5)
		append(&buf, 4, byte(coinbase_tag), byte(coinbase_tag >> 8), byte(coinbase_tag >> 16), byte(coinbase_tag >> 24))
		bb_u32(&buf, 0xFFFFFFFF)
	} else {
		append(&buf, byte(len(inputs)))
		for inp in inputs {
			inp := inp
			append(&buf, ..inp.prev.txid[:])
			bb_u32(&buf, inp.prev.vout)
			append(&buf, 2, 0xAB, 0xCD) // dummy scriptSig
			bb_u32(&buf, 0xFFFFFFFF)
		}
	}
	append(&buf, byte(len(outputs)))
	for out in outputs {
		bb_u64(&buf, out.value)
		append(&buf, byte(len(out.script)))
		append(&buf, ..out.script)
	}
	bb_u32(&buf, 0)
	raw = buf[:]
	txid = hugin.sha256d(raw)
	return
}

// bb_block frames txs into a block with a valid header. bits controls the
// claimed work, for fork-resolution tests.
bb_block :: proc(prev_hash: [32]u8, txs: [][]byte, nonce: u32, bits: u32 = 0x207fffff) -> (blk: []byte, hash: [32]u8) {
	prev_hash := prev_hash
	buf := make([dynamic]byte)
	// header
	bb_u32(&buf, 4)
	append(&buf, ..prev_hash[:])
	// Real merkle root (duplicate-last rule), so proof tests can verify
	// branches against the header.
	ids := make([dynamic][32]u8)
	defer delete(ids)
	for t in txs {
		tx, _ := hugin.tx_parse(t, false)
		append(&ids, tx.txid)
	}
	for len(ids) > 1 {
		n := 0
		i := 0
		for i < len(ids) {
			a := ids[i]
			b := ids[min(i + 1, len(ids) - 1)]
			ids[n] = hugin.sha256d_parts({a[:], b[:]})
			n += 1
			i += 2
		}
		resize(&ids, n)
	}
	append(&buf, ..ids[0][:])
	bb_u32(&buf, 0x60000000)
	bb_u32(&buf, bits)
	bb_u32(&buf, nonce)
	// txs
	append(&buf, byte(len(txs)))
	for t in txs {append(&buf, ..t)}
	blk = buf[:]
	hash = hugin.sha256d(blk[:80])
	return
}

bb_write_blkfiles :: proc(t: ^testing.T, dir: string, blocks: [][]byte, per_file: int) {
	i := 0
	file_no := 0
	for i < len(blocks) {
		buf := make([dynamic]byte)
		defer delete(buf)
		for j := 0; j < per_file && i < len(blocks); j += 1 {
			blk := blocks[i]
			append(&buf, 0xF9, 0xBE, 0xB4, 0xD9)
			n := u32(len(blk))
			append(&buf, byte(n), byte(n >> 8), byte(n >> 16), byte(n >> 24))
			append(&buf, ..blk)
			i += 1
		}
		path := fmt.tprintf("%s/blk%05d.dat", dir, file_no)
		testing.expect_value(t, os.write_entire_file(path, buf[:]), nil)
		file_no += 1
	}
}

// Simple P2WPKH-shaped script with a distinguishing payload byte.
bb_script :: proc(tag: byte, buf: []byte) -> []byte {
	buf[0] = hugin.OP_0
	buf[1] = 20
	for i in 2 ..< 22 {buf[i] = tag}
	return buf[:22]
}

Expected_Funding :: struct {
	sh:     [32]u8,
	height: u32,
	txnum:  u32,
	vout:   u32,
	amount: u64,
}

Expected_Spend :: struct {
	sh:     [32]u8,
	height: u32,
	txnum:  u32,
	vin:    u32,
	amount: u64,
}

@(test)
test_build_pipeline_end_to_end :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_build_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	datadir := fmt.aprintf("%s/blocks", dir)
	index_dir := fmt.aprintf("%s/index", dir)
	defer {delete(datadir); delete(index_dir)}
	testing.expect_value(t, os.make_directory_all(datadir), nil)

	// --- construct the chain ---------------------------------------------
	// Scripts A..E; track every expected row while building.
	sbufA, sbufB, sbufC, sbufD, sbufE: [22]byte
	script_a := bb_script(0xA1, sbufA[:])
	script_b := bb_script(0xB2, sbufB[:])
	script_c := bb_script(0xC3, sbufC[:])
	script_d := bb_script(0xD4, sbufD[:])
	script_e := bb_script(0xE5, sbufE[:])
	sh_a := hugin.scripthash(script_a)
	sh_b := hugin.scripthash(script_b)
	sh_c := hugin.scripthash(script_c)
	sh_d := hugin.scripthash(script_d)
	sh_e := hugin.scripthash(script_e)

	COIN :: u64(100_000_000)

	fundings := make([dynamic]Expected_Funding)
	spends := make([dynamic]Expected_Spend)
	spend_index := make(map[Outpoint][3]u32) // outpoint -> (height, txnum(spender), vin)
	txids := make([dynamic][32]u8)
	tx_heights := make([dynamic]u32)
	defer {delete(fundings); delete(spends); delete(spend_index); delete(txids); delete(tx_heights)}

	blocks := make([dynamic][]byte)
	tx_raws := make([dynamic][]byte)
	defer {
		for b in blocks {delete(b)}
		delete(blocks)
		for r in tx_raws {delete(r)}
		delete(tx_raws)
	}

	// Block 0: coinbase -> A (50).
	cb0, cb0_id := bb_tx(nil, {{50 * COIN, script_a}}, 100)
	append(&tx_raws, cb0)
	blk0, h0 := bb_block({}, {cb0}, 1)
	append(&blocks, blk0)
	append(&txids, cb0_id)
	append(&tx_heights, 0)
	append(&fundings, Expected_Funding{sh_a, 0, 0, 0, 50 * COIN})

	// Block 1: coinbase -> B (50); tx spends A's 50 -> C 30, D 20.
	cb1, cb1_id := bb_tx(nil, {{50 * COIN, script_b}}, 101)
	append(&tx_raws, cb1)
	tx1, tx1_id := bb_tx(
		{{prev = {cb0_id, 0}}},
		{{30 * COIN, script_c}, {20 * COIN, script_d}},
	)
	append(&tx_raws, tx1)
	blk1, h1 := bb_block(h0, {cb1, tx1}, 2)
	append(&blocks, blk1)
	append(&txids, cb1_id)
	append(&tx_heights, 1)
	append(&txids, tx1_id)
	append(&tx_heights, 1)
	append(&fundings, Expected_Funding{sh_b, 1, 0, 0, 50 * COIN})
	append(&fundings, Expected_Funding{sh_c, 1, 1, 0, 30 * COIN})
	append(&fundings, Expected_Funding{sh_d, 1, 1, 1, 20 * COIN})
	append(&spends, Expected_Spend{sh_a, 1, 1, 0, 50 * COIN})
	spend_index[{cb0_id, 0}] = {1, 1, 0}

	// Block 2: coinbase -> E; tx2 spends C's 30 and D's 20 -> E 45.
	cb2, cb2_id := bb_tx(nil, {{50 * COIN, script_e}}, 102)
	append(&tx_raws, cb2)
	tx2, tx2_id := bb_tx(
		{{prev = {tx1_id, 0}}, {prev = {tx1_id, 1}}},
		{{45 * COIN, script_e}},
	)
	append(&tx_raws, tx2)
	blk2, h2 := bb_block(h1, {cb2, tx2}, 3)
	append(&blocks, blk2)
	append(&txids, cb2_id)
	append(&tx_heights, 2)
	append(&txids, tx2_id)
	append(&tx_heights, 2)
	append(&fundings, Expected_Funding{sh_e, 2, 0, 0, 50 * COIN})
	append(&fundings, Expected_Funding{sh_e, 2, 1, 0, 45 * COIN})
	append(&spends, Expected_Spend{sh_c, 2, 1, 0, 30 * COIN})
	append(&spends, Expected_Spend{sh_d, 2, 1, 1, 20 * COIN})
	spend_index[{tx1_id, 0}] = {2, 1, 0}
	spend_index[{tx1_id, 1}] = {2, 1, 1}

	// Block 3: an orphan that must NOT be indexed (forks off block 1,
	// lighter than the main chain).
	cb_orph, _ := bb_tx(nil, {{50 * COIN, script_a}}, 999)
	append(&tx_raws, cb_orph)
	blk_orph, _ := bb_block(h1, {cb_orph}, 99)
	append(&blocks, blk_orph)

	// Block 4 (main, height 3): empty besides coinbase -> A.
	cb3, cb3_id := bb_tx(nil, {{50 * COIN, script_a}}, 103)
	append(&tx_raws, cb3)
	blk3, _ := bb_block(h2, {cb3}, 4)
	append(&blocks, blk3)
	append(&txids, cb3_id)
	append(&tx_heights, 3)
	append(&fundings, Expected_Funding{sh_a, 3, 0, 0, 50 * COIN})

	// Two blocks per file: exercises multi-file parallel scatter.
	bb_write_blkfiles(t, datadir, blocks[:], 2)

	// --- build + catch-up -------------------------------------------------
	// The bulk build stops the immutable main body at tip - horizon;
	// catch-up indexes the top blocks into the recent tier. With
	// horizon = 2 and tip = 3, heights 0-1 are in Munin and 2-3 in the
	// tier — the verification below reads through the query layer, which
	// merges both.
	cfg := hugin.Config {
		datadir     = datadir,
		index_dir   = index_dir,
		network     = .Mainnet,
		bucket_bits = 4,
		workers     = 3,
		horizon     = 2,
	}
	testing.expect_value(t, hugin.build_index(cfg), nil)
	testing.expect_value(t, hugin.catchup_run(cfg), nil)

	// --- verify headers store --------------------------------------------
	chain, cerr := hugin.headers_store_read(index_dir)
	testing.expect_value(t, cerr, nil)
	defer delete(chain)
	testing.expect_value(t, len(chain), 4) // orphan excluded

	idx, oerr := hugin.index_open(cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	// --- verify history ---------------------------------------------------
	// Every expected row, exact amounts, chronological order per script.
	for sh in ([][32]u8{sh_a, sh_b, sh_c, sh_d, sh_e}) {
		want := make([dynamic]hugin.History_Entry)
		defer delete(want)
		// Expected rows in key order: (height, txnum, direction, io).
		for f in fundings {
			if f.sh == sh {
				append(&want, hugin.History_Entry{f.height, f.txnum, hugin.DIRECTION_FUNDING, f.vout, f.amount})
			}
		}
		for s in spends {
			if s.sh == sh {
				append(&want, hugin.History_Entry{s.height, s.txnum, hugin.DIRECTION_SPEND, s.vin, s.amount})
			}
		}
		// Sort expected by (height, txnum, direction, io_index).
		for i in 1 ..< len(want) {
			for j := i; j > 0; j -= 1 {
				a, b := want[j - 1], want[j]
				before := a.height < b.height ||
					(a.height == b.height &&
							(a.txnum < b.txnum ||
									(a.txnum == b.txnum &&
											(a.direction < b.direction ||
													(a.direction == b.direction && a.io_index < b.io_index)))))
				if before {break}
				want[j - 1], want[j] = want[j], want[j - 1]
			}
		}

		got, herr := hugin.query_history(idx, sh)
		testing.expect_value(t, herr, nil)
		defer delete(got)
		testing.expect_value(t, len(got), len(want))
		if len(got) == len(want) {
			for w, i in want {
				testing.expect_value(t, got[i], w)
			}
		}
	}

	// Balance checks: A: 50+50-50=50, E: 95.
	check_balance := proc(t: ^testing.T, idx: ^hugin.Index, sh: [32]u8, want: i64) {
		bal, err := hugin.query_balance(idx, sh)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, bal, want)
	}
	check_balance(t, idx, sh_a, i64(50 * COIN))
	check_balance(t, idx, sh_b, i64(50 * COIN))
	check_balance(t, idx, sh_c, 0)
	check_balance(t, idx, sh_d, 0)
	check_balance(t, idx, sh_e, i64(95 * COIN))

	// --- verify tx retrieval ----------------------------------------------
	for txid, i in txids {
		raw, height, found, terr := hugin.query_tx(idx, txid)
		testing.expect_value(t, terr, nil)
		testing.expectf(t, found, "tx %d missing", i)
		if !found {continue}
		testing.expect_value(t, height, tx_heights[i])
		testing.expect_value(t, hugin.sha256d(raw), txid)
	}

	// --- verify spends ----------------------------------------------------
	for op, want in spend_index {
		spend, found, serr := hugin.query_outpoint(idx, op.txid, op.vout)
		testing.expect_value(t, serr, nil)
		testing.expect(t, found, "spends row missing")
		if !found {continue}
		testing.expect_value(t, spend.height, want[0])
		testing.expect_value(t, spend.vin, want[2])
	}

	// An unspent outpoint must not be present.
	_, found, _ := hugin.query_outpoint(idx, cb3_id, 0)
	testing.expect(t, !found, "unspent outpoint must have no spends row")
}

// Build failure: a block spending an outpoint that never existed must fail
// the build with Unknown_Outpoint, never index silently.
@(test)
test_build_unknown_outpoint_fails :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_badbuild_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	datadir := fmt.aprintf("%s/blocks", dir)
	index_dir := fmt.aprintf("%s/index", dir)
	defer {delete(datadir); delete(index_dir)}
	testing.expect_value(t, os.make_directory_all(datadir), nil)

	sbuf: [22]byte
	script := bb_script(0x77, sbuf[:])

	COIN :: u64(100_000_000)
	blocks := make([dynamic][]byte)
	tx_raws := make([dynamic][]byte)
	defer {
		for b in blocks {delete(b)}
		delete(blocks)
		for r in tx_raws {delete(r)}
		delete(tx_raws)
	}

	cb0, _ := bb_tx(nil, {{50 * COIN, script}}, 1)
	append(&tx_raws, cb0)
	blk0, h0 := bb_block({}, {cb0}, 1)
	append(&blocks, blk0)

	bogus: [32]u8
	bogus[0] = 0xEE
	cb1, _ := bb_tx(nil, {{50 * COIN, script}}, 2)
	append(&tx_raws, cb1)
	bad, _ := bb_tx({{prev = {bogus, 0}}}, {{1 * COIN, script}})
	append(&tx_raws, bad)
	blk1, h1 := bb_block(h0, {cb1, bad}, 2)
	append(&blocks, blk1)

	// Two more blocks so the bad one falls inside the main body with
	// horizon = 1, exercising the bulk join's failure path.
	cb2, _ := bb_tx(nil, {{50 * COIN, script}}, 3)
	append(&tx_raws, cb2)
	blk2, h2 := bb_block(h1, {cb2}, 3)
	append(&blocks, blk2)
	cb3, _ := bb_tx(nil, {{50 * COIN, script}}, 4)
	append(&tx_raws, cb3)
	blk3, _ := bb_block(h2, {cb3}, 4)
	append(&blocks, blk3)

	bb_write_blkfiles(t, datadir, blocks[:], 10)

	cfg := hugin.Config {
		datadir     = datadir,
		index_dir   = index_dir,
		network     = .Mainnet,
		bucket_bits = 4,
		workers     = 2,
		horizon     = 1,
	}
	// The library logs the unknown outpoint at error level by design; the
	// test runner treats error logs as failures, so run the build under a
	// nil logger. The returned error carries the verdict.
	err: hugin.Error
	{
		context.logger = log.nil_logger()
		err = hugin.build_index(cfg)
	}
	testing.expect_value(t, err, hugin.Error(hugin.Corruption.Unknown_Outpoint))
}

@(test)
test_build_status_roundtrip :: proc(t: ^testing.T) {
	hugin.build_status_set("phase 9: testing")
	buf: [160]byte
	testing.expect_value(t, hugin.build_status_get(buf[:]), "phase 9: testing")
	hugin.build_status_set("")
	buf2: [160]byte
	testing.expect_value(t, len(hugin.build_status_get(buf2[:])), 0)
}
