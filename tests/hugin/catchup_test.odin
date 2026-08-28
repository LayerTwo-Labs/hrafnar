package hugin_tests

// Catch-up: extension, shallow reorg unwind, deep reorg refusal,
// promotion past the horizon, and torn recent.log recovery — all on
// synthetic forks, per the build order's step 9.

import "core:fmt"
import "core:log"
import "core:os"
import "core:mem"
import "core:testing"
import "core:time"

import hugin "../../hugin"
import munin "../../munin"

Catchup_World :: struct {
	dir:       string,
	datadir:   string,
	index_dir: string,
	cfg:       hugin.Config,
	blocks:    [dynamic][]byte, // every block ever written, in write order
	tx_raws:   [dynamic][]byte,
}

world_init :: proc(t: ^testing.T, w: ^Catchup_World, horizon: u32) {
	dir, derr := os.make_directory_temp("", "hugin_catchup_*", context.allocator)
	testing.expect_value(t, derr, nil)
	w.dir = dir
	w.datadir = fmt.aprintf("%s/blocks", dir)
	w.index_dir = fmt.aprintf("%s/index", dir)
	testing.expect_value(t, os.make_directory_all(w.datadir), nil)
	w.cfg = hugin.Config {
		datadir     = w.datadir,
		index_dir   = w.index_dir,
		network     = .Mainnet,
		bucket_bits = 4,
		workers     = 2,
		horizon     = horizon,
		promote_batch = 1,
	}
}

world_destroy :: proc(w: ^Catchup_World) {
	for b in w.blocks {delete(b)}
	delete(w.blocks)
	for r in w.tx_raws {delete(r)}
	delete(w.tx_raws)
	os.remove_all(w.dir)
	delete(w.datadir)
	delete(w.index_dir)
	delete(w.dir)
}

// world_flush rewrites the blk files with every block written so far
// (equivalent to Core appending records; orphans stay on disk).
world_flush :: proc(t: ^testing.T, w: ^Catchup_World) {
	bb_write_blkfiles(t, w.datadir, w.blocks[:], 100)
}

world_coinbase :: proc(t: ^testing.T, w: ^Catchup_World, prev: [32]u8, script: []byte, tag: u32, bits: u32 = 0x207fffff) -> (hash: [32]u8, txid: [32]u8) {
	COIN :: u64(100_000_000)
	cb, cb_id := bb_tx(nil, {{50 * COIN, script}}, tag)
	append(&w.tx_raws, cb)
	blk, h := bb_block(prev, {cb}, tag, bits)
	append(&w.blocks, blk)
	return h, cb_id
}

expect_balance :: proc(t: ^testing.T, cfg: hugin.Config, sh: [32]u8, want: i64, loc := #caller_location) {
	idx, oerr := hugin.index_open(cfg)
	testing.expect_value(t, oerr, nil, loc)
	if oerr != nil {return}
	defer hugin.index_close(idx)
	bal, berr := hugin.query_balance(idx, sh)
	testing.expect_value(t, berr, nil, loc)
	testing.expect_value(t, bal, want, loc)
}

@(test)
test_catchup_extend_reorg_promote :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2) // horizon = 2
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA, sbufF, sbufG: [22]byte
	script_a := bb_script(0x0A, sbufA[:])
	script_f := bb_script(0x0F, sbufF[:])
	script_g := bb_script(0x1B, sbufG[:])
	sh_a := hugin.scripthash(script_a)
	sh_f := hugin.scripthash(script_f)
	sh_g := hugin.scripthash(script_g)

	// Heights 0..3, all paying A.
	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	h1, _ := world_coinbase(t, &w, h0, script_a, 2)
	h2, _ := world_coinbase(t, &w, h1, script_a, 3)
	h3, _ := world_coinbase(t, &w, h2, script_a, 4)
	world_flush(t, &w)

	// Bulk build: main body to height 1 (tip 3 - horizon 2); catch-up puts
	// 2 and 3 into the recent tier.
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_a, i64(4 * 50 * COIN))

	// --- extend: height 4 pays F -----------------------------------------
	h4, _ := world_coinbase(t, &w, h3, script_f, 5)
	world_flush(t, &w)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_f, i64(50 * COIN))
	expect_balance(t, w.cfg, sh_a, i64(4 * 50 * COIN))

	// Promotion happened: cutoff = 4 - 2 = 2, so heights <= 2 are in the
	// main body and the tier holds 3 and 4.
	{
		rt, rerr := hugin.recent_open(w.index_dir)
		testing.expect_value(t, rerr, nil)
		if rerr == nil {
			testing.expect_value(t, len(rt.blocks), 2)
			testing.expect_value(t, rt.blocks[0].height, u32(3))
			testing.expect_value(t, rt.blocks[1].height, u32(4))
			hugin.recent_close(rt)
		}
	}

	// --- shallow reorg: replace height 4 with heavier 4' and 5' ----------
	// Fork point is height 3, inside the tier. The orphaned coinbase paid
	// F; the replacements pay G.
	HEAVY :: u32(0x1f00ffff)
	h4b, _ := world_coinbase(t, &w, h3, script_g, 6, HEAVY)
	h5b, _ := world_coinbase(t, &w, h4b, script_g, 7, HEAVY)
	world_flush(t, &w)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	// F's block is orphaned: balance gone. G has both replacements.
	expect_balance(t, w.cfg, sh_f, 0)
	expect_balance(t, w.cfg, sh_g, i64(2 * 50 * COIN))
	expect_balance(t, w.cfg, sh_a, i64(4 * 50 * COIN))

	// The orphaned tx must no longer resolve; the new tip must.
	{
		idx, oerr := hugin.index_open(w.cfg)
		testing.expect_value(t, oerr, nil)
		if oerr == nil {
			defer hugin.index_close(idx)
			testing.expect_value(t, hugin.index_tip_height(idx), 5)
		}
	}
	_ = h4
	_ = h5b
}

@(test)
test_catchup_deep_reorg_refused :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 1) // horizon = 1: almost everything is immutable
	defer world_destroy(&w)

	sbufA, sbufG: [22]byte
	script_a := bb_script(0x2A, sbufA[:])
	script_g := bb_script(0x2B, sbufG[:])

	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	h1, _ := world_coinbase(t, &w, h0, script_a, 2)
	h2, _ := world_coinbase(t, &w, h1, script_a, 3)
	h3, _ := world_coinbase(t, &w, h2, script_a, 4)
	world_flush(t, &w)

	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	// main body holds 0..2, tier holds 3.

	// A heavier fork off height 1 — below the immutable main body tip.
	HEAVY :: u32(0x1f00ffff)
	h2b, _ := world_coinbase(t, &w, h1, script_g, 10, HEAVY)
	h3b, _ := world_coinbase(t, &w, h2b, script_g, 11, HEAVY)
	world_flush(t, &w)

	// Refuse loudly; never serve wrong balances. The fatal log is
	// intentional, so run under a nil logger for the test runner's sake.
	err: hugin.Error
	{
		context.logger = log.nil_logger()
		err = hugin.catchup_run(w.cfg)
	}
	testing.expect_value(t, err, hugin.Error(hugin.Usage_Error.Reorg_Too_Deep))
	_ = h3
	_ = h3b
}

@(test)
test_catchup_torn_log_recovery :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbufA: [22]byte
	script_a := bb_script(0x3A, sbufA[:])
	sh_a := hugin.scripthash(script_a)
	COIN :: u64(100_000_000)

	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	h1, _ := world_coinbase(t, &w, h0, script_a, 2)
	h2, _ := world_coinbase(t, &w, h1, script_a, 3)
	world_flush(t, &w)

	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_a, i64(3 * 50 * COIN))

	// Tear the log: append garbage simulating a crash mid-append.
	log_path := fmt.tprintf("%s/recent.log", w.index_dir)
	data, rerr := os.read_entire_file(log_path, context.allocator)
	testing.expect_value(t, rerr, nil)
	defer delete(data)
	torn := make([dynamic]byte)
	defer delete(torn)
	append(&torn, ..data)
	append(&torn, 0x52, 0x47, 0x55, 0x48, 0x01, 0x02) // half a header
	testing.expect_value(t, os.write_entire_file(log_path, torn[:]), nil)

	// Reopen: the torn tail is dropped, the good records survive, and the
	// next catch-up re-indexes anything lost.
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_a, i64(3 * 50 * COIN))
	_ = h2
}

// Simulates the promotion crash the SIGPIPE era produced in the wild:
// promotion commits rows into the main body, but the process dies before
// the recent tier drops its copies. Queries would then hit Duplicate_Key.
// The next catch-up must detect the overlap and heal the tier — no
// rebuild.
@(test)
test_promotion_crash_reconcile :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2) // horizon = 2
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA: [22]byte
	script_a := bb_script(0x4A, sbufA[:])
	sh_a := hugin.scripthash(script_a)

	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	h1, _ := world_coinbase(t, &w, h0, script_a, 2)
	h2, _ := world_coinbase(t, &w, h1, script_a, 3)
	h3, _ := world_coinbase(t, &w, h2, script_a, 4)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	// Tier now holds heights 2 and 3.

	// Snapshot the tier log BEFORE the promoting catch-up.
	log_path := fmt.tprintf("%s/recent.log", w.index_dir)
	pre_log, prerr := os.read_entire_file(log_path, context.allocator)
	testing.expect_value(t, prerr, nil)
	defer delete(pre_log)

	// Extend by two blocks; catch-up promotes heights <= 3 into the main
	// body and drops them from the tier.
	h4, _ := world_coinbase(t, &w, h3, script_a, 5)
	_, _ = world_coinbase(t, &w, h4, script_a, 6)
	world_flush(t, &w)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	// CRASH SIMULATION: a real crash between munin's commit and the tier
	// drop leaves the log with the promoted blocks (2,3) STILL PRESENT,
	// followed by the newly appended ones (4,5). Reconstruct exactly that:
	// pre-promotion records + the post-promotion survivors.
	post_log, posterr := os.read_entire_file(log_path, context.allocator)
	testing.expect_value(t, posterr, nil)
	defer delete(post_log)
	crashed := make([dynamic]byte)
	defer delete(crashed)
	append(&crashed, ..pre_log)
	append(&crashed, ..post_log)
	testing.expect_value(t, os.write_entire_file(log_path, crashed[:]), nil)

	// Sanity: with the overlap in place, a balance query must fail loudly
	// with Duplicate_Key (never a silent wrong answer).
	{
		idx, oerr := hugin.index_open(w.cfg)
		testing.expect_value(t, oerr, nil)
		if oerr == nil {
			_, berr := hugin.query_balance(idx, sh_a)
			testing.expect(t, berr != nil, "overlapping tiers must error, not lie")
			hugin.index_close(idx)
		}
	}

	// The next catch-up heals it...
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	// ...and every satoshi is intact, exactly once.
	expect_balance(t, w.cfg, sh_a, i64(6 * 50 * COIN))
}

// A crash between a tier append and the checkpoint write leaves the log
// with blocks the checkpoint doesn't know about; the interrupted-and-
// restarted run then re-indexed and re-appended them, duplicating every
// row (the live Duplicate_Key incident). Replay must drop the duplicate
// records.
@(test)
test_catchup_duplicate_log_records :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbufA: [22]byte
	script_a := bb_script(0x4A, sbufA[:])
	sh_a := hugin.scripthash(script_a)
	COIN :: u64(100_000_000)

	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	h1, _ := world_coinbase(t, &w, h0, script_a, 2)
	h2, _ := world_coinbase(t, &w, h1, script_a, 3)
	world_flush(t, &w)

	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_a, i64(3 * 50 * COIN))

	// Simulate the re-append: every record in the log appears twice.
	log_path := fmt.tprintf("%s/recent.log", w.index_dir)
	data, rerr := os.read_entire_file(log_path, context.allocator)
	testing.expect_value(t, rerr, nil)
	defer delete(data)
	doubled := make([dynamic]byte)
	defer delete(doubled)
	append(&doubled, ..data)
	append(&doubled, ..data)
	testing.expect_value(t, os.write_entire_file(log_path, doubled[:]), nil)

	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_a, i64(3 * 50 * COIN))

	// The heal must also rewrite the file: replaying it again is silent.
	healed, herr := os.read_entire_file(log_path, context.allocator)
	testing.expect_value(t, herr, nil)
	defer delete(healed)
	testing.expectf(t, len(healed) <= len(data), "log not rewritten: %d > %d bytes", len(healed), len(data))
	_ = h2
}

// A crash after tier appends but before the checkpoint write: the next
// run must resume above the tier's top block, not re-index from the
// stale checkpoint (which would append duplicates).
@(test)
test_catchup_checkpoint_behind_tier :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbufA: [22]byte
	script_a := bb_script(0x4B, sbufA[:])
	sh_a := hugin.scripthash(script_a)
	COIN :: u64(100_000_000)

	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	h1, _ := world_coinbase(t, &w, h0, script_a, 2)
	h2, _ := world_coinbase(t, &w, h1, script_a, 3)
	h3, _ := world_coinbase(t, &w, h2, script_a, 4)
	world_flush(t, &w)

	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_a, i64(4 * 50 * COIN))

	// Roll the checkpoint back two blocks; the tier still holds the top
	// blocks, as after a crash mid-cycle.
	chain, cerr := hugin.headers_store_read(w.index_dir, context.allocator)
	testing.expect_value(t, cerr, nil)
	defer delete(chain)
	cp := len(chain) - 3
	testing.expect_value(
		t,
		hugin.checkpoint_write(w.index_dir, u32(cp), chain[cp].hash),
		nil,
	)

	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_a, i64(4 * 50 * COIN))
	_ = h3
}

// The txid cache and the hash-free block walk must produce the same
// txids as a full walk, on both the cold and warm paths.
@(test)
test_txid_cache :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 1)
	defer world_destroy(&w)

	sbufA: [22]byte
	script_a := bb_script(0x5C, sbufA[:])
	sh_a := hugin.scripthash(script_a)

	h0, id0 := world_coinbase(t, &w, {}, script_a, 1)
	h1, id1 := world_coinbase(t, &w, h0, script_a, 2)
	_, id2 := world_coinbase(t, &w, h1, script_a, 3)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	want := [][32]u8{id0, id1, id2}
	for pass in 0 ..< 2 { // cold, then cache-warm
		res, rerr := hugin.query_history_resolved(idx, sh_a)
		testing.expect_value(t, rerr, nil)
		testing.expect_value(t, len(res), 3)
		if len(res) == 3 {
			for id, k in want {
				testing.expectf(t, res[k].txid == id, "pass %d entry %d wrong txid", pass, k)
			}
		}
		delete(res)
	}
}

// A block with 150 stored-resolution inputs crosses PARALLEL_RESOLVE_MIN,
// so this exercises the worker-thread resolution path end to end and
// checks the balances come out exact.
@(test)
test_catchup_parallel_resolution :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 1) // horizon 1: block 0 lands in the main body
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA, sbufB: [22]byte
	script_a := bb_script(0xB1, sbufA[:])
	script_b := bb_script(0xB2, sbufB[:])
	sh_a := hugin.scripthash(script_a)
	sh_b := hugin.scripthash(script_b)

	// Block 0: one coinbase with 200 outputs of 1 BTC to A.
	outs := make([]BB_Output, 200)
	defer delete(outs)
	for i in 0 ..< 200 {
		outs[i] = BB_Output{1 * COIN, script_a}
	}
	cb0, cb0_id := bb_tx(nil, outs, 1)
	append(&w.tx_raws, cb0)
	blk0, h0 := bb_block({}, {cb0}, 1)
	append(&w.blocks, blk0)

	// Block 1: coinbase to B, plus one tx spending 150 of A's outputs.
	cb1, _ := bb_tx(nil, {{50 * COIN, script_b}}, 2)
	append(&w.tx_raws, cb1)
	ins := make([]BB_Input, 150)
	defer delete(ins)
	for i in 0 ..< 150 {
		ins[i] = BB_Input{prev = {cb0_id, u32(i)}}
	}
	tx1, _ := bb_tx(ins, {{149 * COIN, script_b}})
	append(&w.tx_raws, tx1)
	blk1, _ := bb_block(h0, {cb1, tx1}, 2)
	append(&w.blocks, blk1)

	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	// A: 200 funded, 150 spent. B: coinbase 50 + received 149.
	expect_balance(t, w.cfg, sh_a, i64(50 * COIN))
	expect_balance(t, w.cfg, sh_b, i64((50 + 149) * COIN))
}

// Catch-up runs on its own thread so an arriving block never stops the
// daemon from serving (a load test across a block arrival showed a ~3.1s
// stall in every category when it ran inline). Drive the real runner:
// extend the chain underneath it and require it to index, refresh the
// index generation, and report what changed.
@(test)
test_catchup_runner_thread :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA: [22]byte
	script_a := bb_script(0xF8, sbufA[:])
	sh_a := hugin.scripthash(script_a)

	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	h1, _ := world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	slot := hugin.Index_Slot{cur = idx}
	defer hugin.index_slot_swap(&slot, nil)
	start_tip := hugin.index_tip_height(idx)

	// The runner carries its OWN cancellation, so a neighbouring daemon
	// test setting the process-global stop flag cannot abort it.
	runner: hugin.Catchup_Runner
	hugin.catchup_runner_start(&runner, w.cfg, &slot, 1)
	defer hugin.catchup_runner_stop(&runner)

	// Two new blocks appear while the runner is live.
	h2, _ := world_coinbase(t, &w, h1, script_a, 3)
	_, _ = world_coinbase(t, &w, h2, script_a, 4)
	world_flush(t, &w)

	touched := make(map[[32]u8]struct {})
	defer delete(touched)
	tip_changed, refreshed := false, false
	for _ in 0 ..< 80 {
		tc, _, rf := hugin.catchup_runner_take(&runner, &touched)
		tip_changed ||= tc
		refreshed ||= rf
		if tip_changed && refreshed {break}
		time.sleep(100 * time.Millisecond)
	}
	testing.expect(t, tip_changed, "runner never reported a tip change")
	testing.expect(t, refreshed, "runner never published a new index generation")
	testing.expect(t, sh_a in touched, "the funded scripthash should be in the touched set")

	// The slot now holds a newer index, and the old one stayed valid for
	// anyone still holding it (refcounted).
	fresh := hugin.index_slot_get(&slot)
	defer hugin.index_release(fresh)
	testing.expectf(
		t,
		hugin.index_tip_height(fresh) > start_tip,
		"slot tip %d should exceed the starting tip %d",
		hugin.index_tip_height(fresh),
		start_tip,
	)
	testing.expect_value(t, hugin.index_tip_height(idx), start_tip) // old generation intact
	old_bal, old_err := hugin.query_balance(idx, sh_a)
	testing.expect_value(t, old_err, nil)
	testing.expect_value(t, old_bal, i64(2 * 50 * COIN))
}

// A long catch-up must not let memory grow with the number of blocks.
// Two failure modes did exactly that and OOM-killed the live daemon after
// two days offline: a fresh de-obfuscation buffer per resolved input, and
// batch_txs holding every transaction of every block in the run. An
// obfuscated world is required — plain datadirs read zero-copy and hide it.
@(test)
test_catchup_memory_bounded :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA, sbufB: [22]byte
	script_a := bb_script(0xC7, sbufA[:])
	script_b := bb_script(0xC8, sbufB[:])

	// Two blocks indexed up front, then a long tail of blocks that each
	// SPEND an earlier output — the path that resolves through blk files.
	h0, cb0_id := world_coinbase(t, &w, {}, script_a, 1)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	N :: 40
	prev := h0
	prev_id := cb0_id
	for i in 0 ..< N {
		cb, cb_id := bb_tx(nil, {{50 * COIN, script_a}}, u32(100 + i))
		append(&w.tx_raws, cb)
		spend, spend_id := bb_tx({{prev = {prev_id, 0}}}, {{49 * COIN, script_b}})
		append(&w.tx_raws, spend)
		blk, h := bb_block(prev, {cb, spend}, u32(100 + i))
		append(&w.blocks, blk)
		prev = h
		prev_id = cb_id
	}
	world_flush(t, &w)
	world_obfuscate(t, &w) // Core v28+ style: every block read COPIES

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		ctx := context
		ctx.allocator = mem.tracking_allocator(&track)
		ctx.temp_allocator = mem.tracking_allocator(&track)
		context = ctx
		testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	}

	// Peak must reflect a couple of blocks in flight, not all N of them.
	// Generous ceiling: this is guarding against growth proportional to
	// the catch-up length, not against a few hundred KB.
	peak := int(track.peak_memory_allocated)
	testing.expectf(
		t,
		peak < 32 * 1024 * 1024,
		"catch-up of %d blocks peaked at %d MB — memory is scaling with the number of blocks",
		N,
		peak / (1024 * 1024),
	)
}

// The tier's own append path must not allocate in proportion to the tier's
// SIZE on every block. It used to: recent_resort took its radix scratch
// from the temp allocator, so a catch-up appending N blocks allocated
// O(N * tier) bytes that the caller's temp allocator did not reset until
// the whole run finished. On a real 350-block catch-up that reached tens of
// gigabytes and the daemon was OOM-killed.
//
// test_catchup_memory_bounded above did not catch this because its blocks
// hold two transactions each — the tier never gets big enough for the
// quadratic term to show. This one uses a realistically sized tier and
// asserts on CUMULATIVE allocation, which is where quadratic growth lives
// (peak hides it: each individual scratch is freed-by-reset eventually).
@(test)
test_recent_append_allocation_is_linear :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_recent_*", context.allocator)
	testing.expect_value(t, derr, nil)
	if derr != nil {return}
	defer {os.remove_all(dir); delete(dir)}

	rt, oerr := hugin.recent_open(dir)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.recent_close(rt)

	N :: 64
	ROWS :: 200 // history rows per block — a small but non-trivial block

	h_rows := make([]byte, ROWS * hugin.HISTORY_ROW_SIZE)
	t_rows := make([]byte, ROWS * hugin.TXLOC_ROW_SIZE)
	s_rows := make([]byte, ROWS * hugin.SPENDS_ROW_SIZE)
	defer {delete(h_rows); delete(t_rows); delete(s_rows)}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	{
		ctx := context
		ctx.temp_allocator = mem.tracking_allocator(&track)
		context = ctx

		for i in 0 ..< N {
			// Vary the bytes so the radix sort does real work rather than
			// walking an already-sorted array.
			for j in 0 ..< len(h_rows) {h_rows[j] = u8((j * 31 + i * 7) & 0xFF)}
			for j in 0 ..< len(t_rows) {t_rows[j] = u8((j * 17 + i * 5) & 0xFF)}
			for j in 0 ..< len(s_rows) {s_rows[j] = u8((j * 13 + i * 3) & 0xFF)}
			hash: [32]u8
			hash[0] = u8(i)
			err := hugin.recent_append_block(rt, u32(i), hash, h_rows, t_rows, s_rows)
			testing.expect_value(t, err, nil)
		}
	}

	// Final tier is N*ROWS*53 ~= 678 KB. Linear behaviour allocates a few
	// multiples of that; the quadratic version allocated ~21 MB here and
	// grows as the square of the catch-up length.
	total := int(track.total_memory_allocated)
	testing.expectf(
		t,
		total < 8 * 1024 * 1024,
		"appending %d blocks allocated %d KB of temp — recent_append_block is scaling with tier size",
		N,
		total / 1024,
	)
}

// The daemon holds the current index in TWO places: the Index_Slot that
// worker threads read through, and the serve loop's own `idx` handle used
// for push notifications. Each needs its own reference. index_open returns
// exactly one, so the loop must acquire a second — otherwise the first new
// block releases that generation twice (the runner's index_slot_swap, then
// the loop's own index_release) and the daemon reads through freed mmaps
// and database handles. This pins the accounting the daemon depends on.
@(test)
test_index_slot_refcount_accounting :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbuf: [22]byte
	script := bb_script(0x5C, sbuf[:])
	h0, _ := world_coinbase(t, &w, {}, script, 1)
	h1, _ := world_coinbase(t, &w, h0, script, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}

	slot := hugin.Index_Slot {
		cur = idx,
	}
	hugin.index_acquire(idx) // the serve loop's own handle
	testing.expectf(t, idx.refs == 2, "after daemon-style init refs = %d, want 2 (slot + loop)", idx.refs)

	// One refresh cycle, exactly as the daemon runs it: the runner opens a
	// new generation and swaps it in, then the loop adopts it.
	gen2, gerr := hugin.index_open(w.cfg)
	testing.expect_value(t, gerr, nil)
	if gerr != nil {return}
	hugin.index_slot_swap(&slot, gen2) // releases the slot's ref on gen1

	testing.expectf(
		t,
		idx.refs == 1,
		"after swap the old generation has refs = %d, want 1 — the loop still holds it and must not have been closed",
		idx.refs,
	)

	adopted := hugin.index_slot_get(&slot) // +1 on gen2
	testing.expect_value(t, adopted, gen2)
	hugin.index_release(idx) // loop drops gen1: this is the release that used to be the second one
	idx = adopted
	testing.expectf(t, gen2.refs == 2, "after adopt refs = %d, want 2 (slot + loop)", gen2.refs)

	hugin.index_release(idx)
	hugin.index_slot_swap(&slot, nil)
}

// The compaction sweep walks thousands of buckets in one call, and
// db_compact_bucket takes its run list, k-way merge iterator and old-id set
// from the temp allocator. Without a reset between buckets, memory grows
// with the number of buckets compacted — the daemon was OOM-killed partway
// through a full 12,288-bucket sweep.
//
// The signal this asserts on: with the fix the sweep allocates from its own
// per-bucket scratch (reset after every bucket), so it contributes almost
// nothing to the CALLER's temp allocator. Without it, every bucket's merge
// state lands in the caller's temp and stays there for the whole sweep.
@(test)
test_compaction_sweep_allocation_bounded :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 1) // horizon 1: every cycle promotes
	defer world_destroy(&w)

	COIN :: u64(100_000_000)

	// Many distinct scripts so rows spread over every bucket, making the
	// sweep touch many buckets rather than one.
	NSCRIPTS :: 24
	sbufs: [NSCRIPTS][22]byte
	scripts: [NSCRIPTS][]byte
	for i in 0 ..< NSCRIPTS {
		scripts[i] = bb_script(u8(0x80 + i), sbufs[i][:])
	}

	outs := make([dynamic]BB_Output, context.allocator)
	defer delete(outs)
	for i in 0 ..< NSCRIPTS {
		append(&outs, BB_Output{2 * COIN, scripts[i]})
	}

	cb0, _ := bb_tx(nil, outs[:], 1)
	append(&w.tx_raws, cb0)
	blk0, prev := bb_block({}, {cb0}, 1)
	append(&w.blocks, blk0)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	// Each cycle promotes a block, adding one run to every bucket it
	// touches. COMPACT_RUN_THRESHOLD is 4, so this crosses it everywhere.
	CYCLES :: 9
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	for i in 0 ..< CYCLES {
		cb, _ := bb_tx(nil, outs[:], u32(200 + i))
		append(&w.tx_raws, cb)
		blk, h := bb_block(prev, {cb}, u32(200 + i))
		append(&w.blocks, blk)
		prev = h
		world_flush(t, &w)
		ctx := context
		ctx.temp_allocator = mem.tracking_allocator(&track)
		context = ctx
		testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	}

	total := int(track.total_memory_allocated)
	log.infof("compaction sweep: caller temp total = %d KB", total / 1024)
	testing.expectf(
		t,
		total < 4 * 1024 * 1024,
		"the sweep put %d KB through the caller's temp allocator — it is not using per-bucket scratch",
		total / 1024,
	)
}

// A caller-supplied cancel flag must not hide process shutdown from
// long-running loops. The daemon's catch-up runner passes its own flag,
// and cancelled() used to consult the process-global stop flag ONLY when
// the caller passed nil — so SIGTERM was invisible to catch-up and to the
// compaction sweep, and a daemon asked to stop kept merging buckets for
// minutes until it was finally SIGKILLed.
@(test)
test_stop_signal_cancels_despite_caller_flag :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbuf: [22]byte
	script := bb_script(0x6D, sbuf[:])
	h0, _ := world_coinbase(t, &w, {}, script, 1)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	// Real work pending, so a run that ignores the stop flag would succeed.
	h1, _ := world_coinbase(t, &w, h0, script, 2)
	_ = h1
	world_flush(t, &w)

	// (a) A set caller flag must cancel. No global involved, so this is
	//     safe to run alongside anything.
	own_cancel := true
	err := hugin.catchup_run(w.cfg, nil, &own_cancel)
	testing.expectf(t, err == hugin.Usage_Error.Cancelled, "caller flag ignored: got %v", err)

	// (b) A CLEAR caller flag must not cancel. Together with (a) this pins
	//     that the caller's flag is actually consulted in both directions.
	quiet := false
	testing.expect(t, !hugin.cancel_check(&quiet), "a clear caller flag must not cancel")

	// NOT TESTED HERE, deliberately: that cancelled() also consults the
	// process-global stop flag when SIGTERM arrives. That global is
	// process-wide, and Odin's test runner executes tests in parallel — so
	// setting it for even two statements cancels the builds and catch-ups
	// of whatever else is running, which is exactly how CI went red (four
	// unrelated tests failing with Not_Exist because their index never got
	// built). daemon_run's per-instance stop flag is what in-process
	// callers use; the global remains the signal path for the real daemon
	// and is one line, exercised every time the binary is stopped.
}

@(private = "file")
always_yield :: proc(user: rawptr) -> bool {
	n := (^int)(user)
	n^ += 1
	return true
}

// A compaction sweep that yields to an incoming block must be SAFE and must
// make PROGRESS: safe because it stops between committed buckets, so every
// row is still readable; progress because the buckets it skipped get picked
// up on later cycles instead of waiting for the next promotion.
//
// This is the property the daemon depends on — a full sweep used to hold the
// catch-up thread for ~48 minutes, so wallets saw no confirmations until it
// finished.
@(test)
test_compaction_sweep_yields_safely_and_progresses :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 1) // horizon 1: every cycle promotes
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	NSCRIPTS :: 24
	sbufs: [NSCRIPTS][22]byte
	scripts: [NSCRIPTS][]byte
	shs: [NSCRIPTS][32]u8
	for i in 0 ..< NSCRIPTS {
		scripts[i] = bb_script(u8(0xA0 + i), sbufs[i][:])
		shs[i] = hugin.scripthash(scripts[i])
	}
	outs := make([dynamic]BB_Output, context.allocator)
	defer delete(outs)
	for i in 0 ..< NSCRIPTS {
		append(&outs, BB_Output{2 * COIN, scripts[i]})
	}

	cb0, _ := bb_tx(nil, outs[:], 1)
	append(&w.tx_raws, cb0)
	blk0, prev := bb_block({}, {cb0}, 1)
	append(&w.blocks, blk0)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	// Compaction must run on cycles that INDEX BLOCKS, not only on idle
	// ones. Gating it on idle cycles meant that on a chain producing blocks
	// faster than the poll interval it never ran at all, and run files grew
	// without bound — which makes every index reopen more expensive, since
	// index_open parses the whole manifest.
	//
	// The yield fires after every bucket, so each cycle compacts at most one
	// while promotions keep adding runs. If compaction were still gated on
	// idle cycles, `yields` would stay at zero here.
	yields := 0
	y := hugin.Yield_Check {
		fn   = always_yield,
		user = &yields,
	}
	CYCLES :: 9
	for i in 0 ..< CYCLES {
		cb, _ := bb_tx(nil, outs[:], u32(300 + i))
		append(&w.tx_raws, cb)
		blk, h := bb_block(prev, {cb}, u32(300 + i))
		append(&w.blocks, blk)
		prev = h
		world_flush(t, &w)
		testing.expect_value(t, hugin.catchup_run(w.cfg, nil, nil, &y), nil)
	}
	testing.expect(
		t,
		yields > 0,
		"compaction never ran on a cycle that indexed blocks — it is gated on idle cycles again, which lets run files grow without bound on a fast chain",
	)

	total_blocks := 1 + CYCLES
	want := i64(u64(total_blocks) * 2 * COIN)
	for i in 0 ..< NSCRIPTS {
		expect_balance(t, w.cfg, shs[i], want)
	}

	// The daemon's PRE-SERVING catch-up must not work off this debt: its
	// ports are not open yet, so a full sweep there takes the whole index
	// offline for as long as the backlog lasts. yield_always is what keeps
	// startup to a single bucket.
	{
		db, oerr := munin.db_open(fmt.tprintf("%s/history", w.index_dir))
		testing.expect_value(t, oerr, nil)
		before := 0
		if oerr == nil {
			for b in 0 ..< 1 << w.cfg.bucket_bits {
				if munin.db_bucket_run_count(db, u32(b)) > 4 {before += 1}
			}
			munin.db_close(db)
		}
		testing.expect(t, before > 1, "fixture did not build enough compaction debt to test with")

		sy := hugin.Yield_Check {
			fn = hugin.yield_always,
		}
		testing.expect_value(t, hugin.catchup_run(w.cfg, nil, nil, &sy), nil)

		db2, oerr2 := munin.db_open(fmt.tprintf("%s/history", w.index_dir))
		testing.expect_value(t, oerr2, nil)
		after := 0
		if oerr2 == nil {
			for b in 0 ..< 1 << w.cfg.bucket_bits {
				if munin.db_bucket_run_count(db2, u32(b)) > 4 {after += 1}
			}
			munin.db_close(db2)
		}
		testing.expectf(
			t,
			after >= before - 1,
			"a startup catch-up compacted %d buckets (%d -> %d) — it must stop after one, or the daemon serves nothing until the backlog clears",
			before - after,
			before,
			after,
		)
	}

	// Keep going with the same hostile interleaving — one bucket of forward
	// progress per pass, every interruption landing between committed
	// buckets.
	for _ in 0 ..< 20 {
		testing.expect_value(t, hugin.catchup_run(w.cfg, nil, nil, &y), nil)
		// Every row must remain readable after every interruption.
		expect_balance(t, w.cfg, shs[0], want)
	}
	// Now let it drain with no block pressure, checking after every pass
	// that the data is still complete — an interrupted sweep must never
	// leave a bucket half-merged or a row unreachable.
	for _ in 0 ..< 60 {
		testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
		expect_balance(t, w.cfg, shs[0], want)
	}

	// Progress: the interrupted sweeps must have actually drained the debt,
	// not merely restarted. Every bucket should now be at or below threshold.
	{
		db, oerr := munin.db_open(fmt.tprintf("%s/history", w.index_dir))
		testing.expect_value(t, oerr, nil)
		if oerr == nil {
			defer munin.db_close(db)
			over := 0
			for b in 0 ..< 1 << w.cfg.bucket_bits {
				if munin.db_bucket_run_count(db, u32(b)) > 4 {over += 1}
			}
			testing.expectf(t, over == 0, "%d buckets still over-full — yielding sweeps are not draining the debt", over)
		}
	}

	// And the data is still exactly right after all that churn.
	for i in 0 ..< NSCRIPTS {
		expect_balance(t, w.cfg, shs[i], want)
	}
}

// Bitcoin Core PREALLOCATES blk files in 16 MiB chunks, so appending a
// block usually writes into space the file already had — the size does not
// change, only the modification time does. A tip watch that compares size
// alone therefore misses most blocks. That was survivable while a 30s
// fallback poll covered it, and became a live bug the moment a compaction
// sweep started relying on the watch to know when to step aside: the daemon
// sat a block behind the network for the length of the sweep.
@(test)
test_tip_watch_sees_inplace_append :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_tipwatch_*", context.allocator)
	testing.expect_value(t, derr, nil)
	if derr != nil {return}
	defer {os.remove_all(dir); delete(dir)}

	path := fmt.tprintf("%s/blk00000.dat", dir)
	// Preallocated-looking file: real size up front, contents written later.
	buf := make([]byte, 1 << 16)
	defer delete(buf)
	testing.expect_value(t, os.write_entire_file(path, buf), nil)

	cfg := hugin.Config {
		datadir = dir,
		network = .Mainnet,
	}
	w: hugin.Tip_Watch
	defer hugin.tip_watch_destroy(&w)
	hugin.tip_watch_refresh(&w, cfg)
	testing.expect(t, !hugin.tip_watch_changed(&w), "nothing has been written yet")

	// Write IN PLACE: same length, new contents — exactly what Core does
	// when it appends a block into preallocated space.
	for i in 0 ..< len(buf) {buf[i] = 0xAB}
	testing.expect_value(t, os.write_entire_file(path, buf), nil)

	testing.expect(
		t,
		hugin.tip_watch_changed(&w),
		"an in-place append went unnoticed — the watch is comparing size only, so most new blocks are invisible to it",
	)
}

// The daemon opens a fresh Index every time the tip moves. The resolved-txid
// cache lives on that Index, so without carrying it over it started empty
// roughly every ten minutes and nearly every address query paid full price
// (measured 1.6s cold vs 0.25s warm on a busy address). Entries are safe to
// keep because only heights below the reorg horizon are ever cached, and a
// reorg that deep is refused outright.
//
// The delicate part is ownership: the old generation may still be serving
// in-flight queries when its cache is taken, and both generations get closed
// eventually — so this runs under a tracking allocator to catch a double
// free or a leak.
@(test)
test_txid_cache_survives_index_refresh :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 1)
	defer world_destroy(&w)

	sbuf: [22]byte
	script := bb_script(0x3E, sbuf[:])
	h0, _ := world_coinbase(t, &w, {}, script, 1)
	h1, _ := world_coinbase(t, &w, h0, script, 2)
	_ = h1
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	tracked := mem.tracking_allocator(&track)

	want := [32]u8{}
	want[0] = 0xD1
	want[31] = 0x7C

	old_idx, oerr := hugin.index_open(w.cfg, tracked)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	hugin.txid_cache_put(old_idx, 0, 0, want)
	got, hit := hugin.txid_cache_get(old_idx, 0, 0)
	testing.expect(t, hit, "cache should hold what was just put in it")

	// A new generation, exactly as the daemon opens one on a new block.
	new_idx, nerr := hugin.index_open(w.cfg, tracked)
	testing.expect_value(t, nerr, nil)
	if nerr != nil {hugin.index_close(old_idx); return}

	_, cold := hugin.txid_cache_get(new_idx, 0, 0)
	testing.expect(t, !cold, "a freshly opened index should start cold")

	hugin.index_adopt_txid_cache(new_idx, old_idx)

	got, hit = hugin.txid_cache_get(new_idx, 0, 0)
	testing.expect(t, hit, "the new generation did not inherit the cache — every block resets queries to cold")
	testing.expect_value(t, got, want)

	// The old generation must have given the entries up, not shared them:
	// both get closed, and only one may own the memory.
	_, still := hugin.txid_cache_get(old_idx, 0, 0)
	testing.expect(t, !still, "the old generation still holds the cache — it is now owned twice")

	hugin.index_close(old_idx)
	hugin.index_close(new_idx)

	leaked := 0
	for _, entry in track.allocation_map {
		leaked += entry.size
	}
	testing.expectf(t, leaked == 0, "%d bytes leaked across the cache handover", leaked)
	testing.expectf(t, len(track.bad_free_array) == 0, "%d bad frees during the cache handover", len(track.bad_free_array))
}
