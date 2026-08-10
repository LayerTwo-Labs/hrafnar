package hugin_tests

// Compact-index tests: the same worlds as the exact suites, built with
// cfg.compact — prefix keys on disk, verification at query time. Balances
// and every lookup must come out identical to exact mode.

import "core:log"
import "core:testing"

import hugin "../../hugin"

@(test)
test_compact_queries :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)
	w.cfg.compact = true

	COIN :: u64(100_000_000)
	sbufA, sbufB: [22]byte
	script_a := bb_script(0xC1, sbufA[:])
	script_b := bb_script(0xC2, sbufB[:])
	sh_a := hugin.scripthash(script_a)
	sh_b := hugin.scripthash(script_b)

	// Block 0: coinbase -> A. Blocks 1-3: more coinbases, and a spend of
	// A's first output to B in block 3 (resolved during catch-up, through
	// the compact txloc path).
	h0, cb0_id := world_coinbase(t, &w, {}, script_a, 1)
	h1, _ := world_coinbase(t, &w, h0, script_a, 2)
	h2, _ := world_coinbase(t, &w, h1, script_a, 3)

	cb3, _ := bb_tx(nil, {{50 * COIN, script_a}}, 4)
	append(&w.tx_raws, cb3)
	spend, spend_id := bb_tx({{prev = {cb0_id, 0}}}, {{49 * COIN, script_b}})
	append(&w.tx_raws, spend)
	blk3, _ := bb_block(h2, {cb3, spend}, 4)
	append(&w.blocks, blk3)

	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	// Wrong-mode open must refuse. (The refusal logs an error by design;
	// silence it so the runner doesn't count it as a test failure.)
	{
		context.logger = log.nil_logger()
		wrong := w.cfg
		wrong.compact = false
		_, werr := hugin.index_open(wrong)
		testing.expect_value(t, werr, hugin.Error(hugin.Usage_Error.Bad_Config))
	}

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	// Balances: A funded 4x50, spent 50. B received 49.
	bal_a, berr := hugin.query_balance(idx, sh_a)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, bal_a, i64(3 * 50 * COIN))
	bal_b, berr2 := hugin.query_balance(idx, sh_b)
	testing.expect_value(t, berr2, nil)
	testing.expect_value(t, bal_b, i64(49 * COIN))

	// History: A has 4 fundings + 1 spend, txids and amounts exact.
	hist, herr := hugin.query_history_resolved(idx, sh_a, 0, -1, context.allocator)
	testing.expect_value(t, herr, nil)
	defer delete(hist)
	testing.expect_value(t, len(hist), 5)
	if len(hist) == 5 {
		testing.expect_value(t, hist[0].entry.height, u32(0))
		testing.expect_value(t, hist[0].entry.amount, 50 * COIN)
		testing.expect(t, hist[0].txid == cb0_id, "history[0] txid mismatch")
		last := hist[4]
		testing.expect_value(t, last.entry.direction, hugin.DIRECTION_SPEND)
		testing.expect_value(t, last.entry.amount, 50 * COIN)
		testing.expect(t, last.txid == spend_id, "spend txid mismatch")
	}

	// UTXOs: A's spent output is gone, three remain.
	utxos, uerr := hugin.query_utxos(idx, sh_a, context.allocator)
	testing.expect_value(t, uerr, nil)
	defer delete(utxos)
	testing.expect_value(t, len(utxos), 3)

	// Transaction fetch through the compact txloc scan.
	raw, height, found, terr := hugin.query_tx(idx, cb0_id)
	testing.expect_value(t, terr, nil)
	testing.expect(t, found, "cb0 must be found")
	testing.expect_value(t, height, u32(0))
	testing.expect(t, len(raw) > 0, "raw tx empty")

	// Outpoint: cb0:0 spent by the spend tx.
	sp, sfound, serr := hugin.query_outpoint(idx, cb0_id, 0)
	testing.expect_value(t, serr, nil)
	testing.expect(t, sfound, "cb0:0 must be spent")
	if sfound {
		testing.expect(t, sp.spender_txid == spend_id, "wrong spender")
	}

	// Merkle proof (self-verifying against the header root).
	_, pos, branch, mfound, merr := hugin.query_merkle(idx, spend_id)
	testing.expect_value(t, merr, nil)
	testing.expect(t, mfound, "merkle must resolve")
	testing.expect_value(t, pos, u32(1))
	delete(branch)
}

@(test)
test_compact_promotion :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 1) // horizon 1, promote_batch 1: promotion fires fast
	defer world_destroy(&w)
	w.cfg.compact = true

	COIN :: u64(100_000_000)
	sbufA: [22]byte
	script_a := bb_script(0xC3, sbufA[:])
	sh_a := hugin.scripthash(script_a)

	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	h1, _ := world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_a, i64(2 * 50 * COIN))

	// Extend the chain twice; catch-up promotes aged blocks through
	// compact_ingest into the main body.
	h2, _ := world_coinbase(t, &w, h1, script_a, 3)
	_, _ = world_coinbase(t, &w, h2, script_a, 4)
	world_flush(t, &w)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_a, i64(4 * 50 * COIN))

	// And again, so previously promoted compact rows are read back while
	// promoting more on top.
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_a, i64(4 * 50 * COIN))
}
