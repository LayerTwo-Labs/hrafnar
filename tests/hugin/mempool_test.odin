package hugin_tests

// Mempool tier tests: a synthetic Mempool_Source feeds unconfirmed
// transactions over a built index — no bitcoind involved.

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

import hugin "../../hugin"

// The fake node: a settable list of (txid, raw) pairs.
Fake_Node :: struct {
	txids: [dynamic][32]u8,
	raws:  map[[32]u8][]byte,
}

@(private = "file")
fake_list :: proc(user: rawptr) -> ([][32]u8, bool) {
	n := cast(^Fake_Node)user
	return n.txids[:], true
}

@(private = "file")
fake_fetch_many :: proc(user: rawptr, txids: [][32]u8) -> ([][]byte, bool) {
	n := cast(^Fake_Node)user
	raws := make([][]byte, len(txids), context.temp_allocator)
	for id, i in txids {
		if raw, ok := n.raws[id]; ok {
			raws[i] = raw
		}
	}
	return raws, true
}

@(private = "file")
fake_source :: proc(n: ^Fake_Node) -> hugin.Mempool_Source {
	return hugin.Mempool_Source{user = n, list = fake_list, fetch_many = fake_fetch_many}
}

@(private = "file")
fake_add :: proc(n: ^Fake_Node, raw: []byte, txid: [32]u8) {
	append(&n.txids, txid)
	n.raws[txid] = raw
}

@(private = "file")
fake_remove :: proc(n: ^Fake_Node, txid: [32]u8) {
	for i in 0 ..< len(n.txids) {
		if n.txids[i] == txid {
			n.txids[i] = n.txids[len(n.txids) - 1]
			resize(&n.txids, len(n.txids) - 1)
			break
		}
	}
	if raw, has := n.raws[txid]; has {
		delete(raw)
		delete_key(&n.raws, txid)
	}
}

@(test)
test_mempool_tier :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA, sbufB, sbufC: [22]byte
	script_a := bb_script(0x9A, sbufA[:])
	script_b := bb_script(0x9B, sbufB[:])
	script_c := bb_script(0x9C, sbufC[:])
	sh_a := hugin.scripthash(script_a)
	sh_b := hugin.scripthash(script_b)
	sh_c := hugin.scripthash(script_c)

	// Confirmed chain: A gets two coinbases.
	h0, cb0_id := world_coinbase(t, &w, {}, script_a, 1)
	_, _ = world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	node: Fake_Node
	node.raws = make(map[[32]u8][]byte)
	defer {
		for _, r in node.raws {delete(r)}
		delete(node.raws)
		delete(node.txids)
	}

	mp: hugin.Mempool
	hugin.mempool_init(&mp)
	defer hugin.mempool_destroy(&mp)

	// Unconfirmed tx1: spends A's first coinbase -> pays B 30, C 19.
	tx1, tx1_id := bb_tx({{prev = {cb0_id, 0}}}, {{30 * COIN, script_b}, {19 * COIN, script_c}})
	fake_add(&node, tx1, tx1_id)

	added, removed, _, serr := hugin.mempool_sync(&mp, idx, fake_source(&node))
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, added, 1)
	testing.expect_value(t, removed, 0)
	testing.expect_value(t, hugin.mempool_size(&mp), 1)

	// Deltas: A loses 50, B gains 30, C gains 19.
	da, pa := hugin.mempool_delta(&mp, sh_a)
	testing.expect_value(t, da, i64(-50) * i64(COIN))
	testing.expect_value(t, pa, 1)
	db, _ := hugin.mempool_delta(&mp, sh_b)
	testing.expect_value(t, db, i64(30) * i64(COIN))
	dc, _ := hugin.mempool_delta(&mp, sh_c)
	testing.expect_value(t, dc, i64(19) * i64(COIN))

	// The spent outpoint is flagged.
	spender, sfound := hugin.mempool_spender(&mp, cb0_id, 0)
	testing.expect(t, sfound)
	testing.expect_value(t, spender, tx1_id)

	// Chained unconfirmed tx2: spends tx1's output 0 -> pays C 29.
	tx2, tx2_id := bb_tx({{prev = {tx1_id, 0}}}, {{29 * COIN, script_c}})
	fake_add(&node, tx2, tx2_id)
	added, _, _, serr = hugin.mempool_sync(&mp, idx, fake_source(&node))
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, added, 1)

	// B: +30 (from tx1) then -30 (spent by tx2) = 0 across 2 entries.
	pb: int
	db, pb = hugin.mempool_delta(&mp, sh_b)
	testing.expect_value(t, db, 0)
	testing.expect_value(t, pb, 2)
	dc, _ = hugin.mempool_delta(&mp, sh_c)
	testing.expect_value(t, dc, i64(48) * i64(COIN))

	// Server output: balance with pending lines, utxos with spend-pending
	// annotation, tip with mempool count.
	hexbuf: [64]byte
	hex64_of :: proc(h: [32]u8, buf: []byte) -> string {
		HEXD := "0123456789abcdef"
		for b, i in h {
			buf[i * 2] = HEXD[b >> 4]
			buf[i * 2 + 1] = HEXD[b & 0xF]
		}
		return string(buf[:64])
	}
	resp := hugin.serve_request(idx, &mp, fmt.tprintf("balance %s", hex64_of(sh_a, hexbuf[:])), context.temp_allocator)
	testing.expect(t, strings.contains(resp, "confirmed"), "balance must show confirmed line")
	testing.expect(t, strings.contains(resp, "-5000000000 sat pending"), "balance must show pending delta")
	testing.expect(t, strings.contains(resp, "5000000000 sat (50.00000000 BTC) total"), "balance must total 50")

	resp = hugin.serve_request(idx, &mp, fmt.tprintf("utxos %s", hex64_of(sh_a, hexbuf[:])), context.temp_allocator)
	testing.expect(t, strings.contains(resp, "(spend pending)"), "utxo spend must be flagged")

	resp = hugin.serve_request(idx, &mp, "tip", context.temp_allocator)
	testing.expect(t, strings.contains(resp, "mempool 2 txs"), "tip must count mempool")

	// tx1 confirms (leaves the mempool): its effects and tx2's parent
	// remain consistent — tx2 stays, now resolving via the index? tx1 is
	// gone from the mempool map, but tx2 was already ingested, so nothing
	// changes for it.
	fake_remove(&node, tx1_id)
	added, removed, _, serr = hugin.mempool_sync(&mp, idx, fake_source(&node))
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, removed, 1)
	testing.expect_value(t, hugin.mempool_size(&mp), 1)

	// A's pending delta is gone (tx1 evicted); C keeps tx2's +29.
	da, pa = hugin.mempool_delta(&mp, sh_a)
	testing.expect_value(t, da, 0)
	testing.expect_value(t, pa, 0)
	pc: int
	dc, pc = hugin.mempool_delta(&mp, sh_c)
	testing.expect_value(t, dc, i64(29) * i64(COIN))
	testing.expect_value(t, pc, 1)

	// Orphan handling: a tx spending an unknown outpoint is skipped and
	// does not poison the tier.
	bogus: [32]u8
	bogus[7] = 0x99
	orphan, orphan_id := bb_tx({{prev = {bogus, 0}}}, {{1 * COIN, script_c}})
	fake_add(&node, orphan, orphan_id)
	added, _, _, serr = hugin.mempool_sync(&mp, idx, fake_source(&node))
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, added, 0)
	testing.expect_value(t, hugin.mempool_size(&mp), 1)
}

// The per-cycle cap keeps the serve loop responsive during a large
// backfill: excess transactions are reported as backlog and ingested on
// later cycles.
@(test)
test_mempool_backfill_cap :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA, sbufB: [22]byte
	script_a := bb_script(0xA7, sbufA[:])
	script_b := bb_script(0xB7, sbufB[:])

	h0, cb0_id := world_coinbase(t, &w, {}, script_a, 1)
	_, _ = world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	node: Fake_Node
	node.raws = make(map[[32]u8][]byte)
	defer {
		for _, r in node.raws {delete(r)}
		delete(node.raws)
		delete(node.txids)
	}

	mp: hugin.Mempool
	hugin.mempool_init(&mp)
	defer hugin.mempool_destroy(&mp)

	// A chain of 5 unconfirmed txs, each spending the previous.
	prev := cb0_id
	amount := u64(50) * COIN
	for _ in 0 ..< 5 {
		amount -= COIN
		tx, tx_id := bb_tx({{prev = {prev, 0}}}, {{amount, script_b}})
		fake_add(&node, tx, tx_id)
		prev = tx_id
	}

	// Cap of 2 per cycle: 5 txs land over 3 cycles.
	total_added := 0
	for cycle in 0 ..< 3 {
		added, _, backlog, serr := hugin.mempool_sync(&mp, idx, fake_source(&node), 2)
		testing.expect_value(t, serr, nil)
		total_added += added
		if cycle < 2 {
			testing.expect(t, backlog > 0, "early cycles must report backlog")
		}
	}
	testing.expect_value(t, total_added, 5)
	testing.expect_value(t, hugin.mempool_size(&mp), 5)
}

// Fee histogram: fees derive from resolved input amounts, vsize from the
// parsed tx; bins accumulate by descending rate.
@(test)
test_mempool_fee_histogram :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA, sbufB: [22]byte
	script_a := bb_script(0xA1, sbufA[:])
	script_b := bb_script(0xA2, sbufB[:])

	h0, cb0_id := world_coinbase(t, &w, {}, script_a, 1)
	_, cb1_id := world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	node: Fake_Node
	node.raws = make(map[[32]u8][]byte)
	defer {
		for _, r in node.raws {delete(r)}
		delete(node.raws)
		delete(node.txids)
	}
	mp: hugin.Mempool
	hugin.mempool_init(&mp)
	defer hugin.mempool_destroy(&mp)

	// tx1: fee 1 COIN. tx2: fee 2 COIN. Similar sizes, so tx2's rate is
	// higher and must come first in the histogram ordering.
	tx1, tx1_id := bb_tx({{prev = {cb0_id, 0}}}, {{49 * COIN, script_b}})
	tx2, tx2_id := bb_tx({{prev = {cb1_id, 0}}}, {{48 * COIN, script_b}})
	fake_add(&node, tx1, tx1_id)
	fake_add(&node, tx2, tx2_id)
	added, _, _, serr := hugin.mempool_sync(&mp, idx, fake_source(&node))
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, added, 2)

	p1, _ := hugin.tx_parse(tx1, false)
	p2, _ := hugin.tx_parse(tx2, false)
	testing.expect(t, p1.vsize > 0 && p2.vsize > 0, "vsize must be computed")

	bins := hugin.mempool_fee_histogram(&mp)
	defer delete(bins)
	// Both txs are far below the 100 kvB bin size: one bin, holding both,
	// tagged with the LOWER rate (tx1's).
	testing.expect_value(t, len(bins), 1)
	if len(bins) == 1 {
		testing.expect_value(t, bins[0].vsize, u64(p1.vsize + p2.vsize))
		want_rate := f64(1 * COIN) / f64(p1.vsize)
		testing.expectf(
			t,
			bins[0].rate > want_rate * 0.99 && bins[0].rate < want_rate * 1.01,
			"bin rate %.2f, want ~%.2f",
			bins[0].rate,
			want_rate,
		)
	}
	_ = tx2_id
}


// A wallet asks for every txid its history returned — and history
// includes UNCONFIRMED entries. Electrum's transaction.get must serve
// those from the mempool; answering "not found" aborts the wallet's whole
// sync, which is exactly how a pending send made a working server look
// broken. esplora already did this; both are asserted here.
@(test)
test_mempool_tx_served_by_both_protocols :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA, sbufB: [22]byte
	script_a := bb_script(0xF1, sbufA[:])
	script_b := bb_script(0xF2, sbufB[:])
	sh_a := hugin.scripthash(script_a)

	h0, cb0_id := world_coinbase(t, &w, {}, script_a, 1)
	_, _ = world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	node: Fake_Node
	node.raws = make(map[[32]u8][]byte)
	defer {
		for _, r in node.raws {delete(r)}
		delete(node.raws)
		delete(node.txids)
	}
	mp: hugin.Mempool
	hugin.mempool_init(&mp)
	defer hugin.mempool_destroy(&mp)

	// An unconfirmed spend of A's coinbase.
	pending, pending_id := bb_tx({{prev = {cb0_id, 0}}}, {{49 * COIN, script_b}})
	fake_add(&node, pending, pending_id)
	added, _, _, serr := hugin.mempool_sync(&mp, idx, fake_source(&node))
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, added, 1)

	ctx := hugin.Electrum_Ctx {
		idx     = idx,
		mp      = &mp,
		version = "hrafnar mempooltest",
	}
	hexbuf: [64]byte
	pending_hex := strings.clone(hugin.txid_to_hex(pending_id, hexbuf[:]))
	defer delete(pending_hex)

	// The history a wallet sees must include the pending tx...
	sh_hex := strings.clone(hugin.txid_to_hex(sh_a, hexbuf[:]))
	defer delete(sh_hex)
	hist := hugin.electrum_handle(
		&ctx,
		fmt.tprintf(`{{"id":1,"method":"blockchain.scripthash.get_history","params":["%s"]}}`, sh_hex),
		context.temp_allocator,
	)
	testing.expectf(t, strings.contains(hist, pending_hex), "history must list the pending tx: %q", hist)

	// ...and asking for it must succeed, not "transaction not found".
	got := hugin.electrum_handle(
		&ctx,
		fmt.tprintf(`{{"id":2,"method":"blockchain.transaction.get","params":["%s"]}}`, pending_hex),
		context.temp_allocator,
	)
	testing.expectf(t, !strings.contains(got, "not found"), "electrum must serve the mempool tx: %q", got)
	testing.expectf(t, strings.contains(got, `"result":"`), "electrum must return raw hex: %q", got)

	// esplora, same transaction.
	st, _, body := hugin.esplora_handle(&ctx, "GET", fmt.tprintf("/tx/%s/hex", pending_hex), "", context.temp_allocator)
	testing.expect_value(t, st, 200)
	testing.expect(t, len(body) > 0, "esplora must serve the mempool tx hex")
}


// The mempool runner syncs on its OWN thread. Its first act is to build a
// map from its temp allocator — which panicked ("allocation not aligned
// to a cache line") when that allocator was a mem.Dynamic_Arena, killing
// the daemon seconds after startup. Drive the real runner and require it
// to make progress.
@(test)
test_mempool_runner_thread :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA, sbufB: [22]byte
	script_a := bb_script(0xF5, sbufA[:])
	script_b := bb_script(0xF6, sbufB[:])

	h0, cb0_id := world_coinbase(t, &w, {}, script_a, 1)
	_, _ = world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	slot := hugin.Index_Slot{cur = idx}
	defer hugin.index_slot_swap(&slot, nil)

	node: Fake_Node
	node.raws = make(map[[32]u8][]byte)
	defer {
		for _, r in node.raws {delete(r)}
		delete(node.raws)
		delete(node.txids)
	}
	mp: hugin.Mempool
	hugin.mempool_init(&mp)
	defer hugin.mempool_destroy(&mp)

	pending, pending_id := bb_tx({{prev = {cb0_id, 0}}}, {{49 * COIN, script_b}})
	fake_add(&node, pending, pending_id)

	runner: hugin.Mempool_Runner
	hugin.mempool_runner_start(&runner, &mp, &slot, fake_source(&node))
	defer hugin.mempool_runner_stop(&runner)

	// The runner should pick the transaction up within a couple of cycles.
	seen := false
	for _ in 0 ..< 60 {
		if hugin.mempool_size(&mp) > 0 {
			seen = true
			break
		}
		time.sleep(100 * time.Millisecond)
	}
	testing.expect(t, seen, "runner thread never ingested the mempool tx")

	// And it must hand the touched scripthashes to the serve loop.
	touched := make(map[[32]u8]struct {})
	defer delete(touched)
	changed := false
	for _ in 0 ..< 20 {
		if hugin.mempool_runner_take(&runner, &touched) {
			changed = true
			break
		}
		time.sleep(100 * time.Millisecond)
	}
	testing.expect(t, changed, "runner reported no touched scripthashes")
	testing.expect(t, len(touched) > 0, "touched set should name the affected scripthashes")
}
