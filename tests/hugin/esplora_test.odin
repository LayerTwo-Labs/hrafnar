package hugin_tests

// Esplora handler tests: routes in, JSON-parsed responses out, against
// the same synthetic worlds as everything else.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import hugin "../../hugin"

@(private = "file")
ea_get :: proc(t: ^testing.T, ctx: ^hugin.Electrum_Ctx, path: string, want_status: int, what: string) -> string {
	status, _, resp := hugin.esplora_handle(ctx, "GET", path, "", context.temp_allocator)
	testing.expectf(t, status == want_status, "%s: status %d, want %d (%q)", what, status, want_status, resp)
	return resp
}

@(test)
test_esplora_handler :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA, sbufB: [22]byte
	script_a := bb_script(0xD1, sbufA[:])
	script_b := bb_script(0xD2, sbufB[:])

	h0, cb0_id := world_coinbase(t, &w, {}, script_a, 1)
	cb1, _ := bb_tx(nil, {{50 * COIN, script_a}}, 2)
	append(&w.tx_raws, cb1)
	spend, spend_id := bb_tx({{prev = {cb0_id, 0}}}, {{49 * COIN, script_b}})
	append(&w.tx_raws, spend)
	blk1, _ := bb_block(h0, {cb1, spend}, 2)
	append(&w.blocks, blk1)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	ctx := hugin.Electrum_Ctx {
		idx     = idx,
		version = "hrafnar esploratest",
	}
	hexbuf: [64]byte
	spend_hex := strings.clone(hugin.txid_to_hex(spend_id, hexbuf[:]))
	defer delete(spend_hex)

	// tip height and hash
	resp := ea_get(t, &ctx, "/blocks/tip/height", 200, "tip height")
	testing.expect_value(t, resp, "1")
	tip_hash := strings.clone(ea_get(t, &ctx, "/blocks/tip/hash", 200, "tip hash"))
	defer delete(tip_hash)
	testing.expect_value(t, len(tip_hash), 64)

	// block-height -> hash -> block json roundtrip
	bh := ea_get(t, &ctx, "/block-height/1", 200, "block-height")
	testing.expect_value(t, bh, tip_hash)
	bj := ea_get(t, &ctx, fmt.tprintf("/block/%s", tip_hash), 200, "block json")
	bv, bjerr := json.parse_string(bj, .JSON, false, context.temp_allocator)
	testing.expect_value(t, bjerr, nil)
	if bobj, bok := bv.(json.Object); bok {
		testing.expect_value(t, bobj["height"].(json.Float), 1)
		testing.expect_value(t, bobj["tx_count"].(json.Float), 2)
	}

	// block txids
	txids_json := ea_get(t, &ctx, fmt.tprintf("/block/%s/txids", tip_hash), 200, "block txids")
	tv, tverr := json.parse_string(txids_json, .JSON, false, context.temp_allocator)
	testing.expect_value(t, tverr, nil)
	if tarr, tok := tv.(json.Array); tok {
		testing.expect_value(t, len(tarr), 2)
		testing.expect_value(t, tarr[1].(json.String), spend_hex)
	}

	// decoded tx: prevout resolved, fee exact (50 - 49 = 1 BTC)
	txj := ea_get(t, &ctx, fmt.tprintf("/tx/%s", spend_hex), 200, "tx json")
	xv, xerr := json.parse_string(txj, .JSON, false, context.temp_allocator)
	testing.expect_value(t, xerr, nil)
	if xobj, xok := xv.(json.Object); xok {
		testing.expect_value(t, xobj["fee"].(json.Float), f64(1 * COIN))
		vin := xobj["vin"].(json.Array)
		if len(vin) == 1 {
			in0 := vin[0].(json.Object)
			prevout, pok := in0["prevout"].(json.Object)
			testing.expect(t, pok, "prevout missing")
			if pok {
				testing.expect_value(t, prevout["value"].(json.Float), f64(50 * COIN))
			}
		}
		st := xobj["status"].(json.Object)
		testing.expect_value(t, st["confirmed"].(json.Boolean), true)
		testing.expect_value(t, st["block_height"].(json.Float), 1)
	}

	// outspend of cb0:0 -> spent by spend tx
	cb0_hex := strings.clone(hugin.txid_to_hex(cb0_id, hexbuf[:]))
	defer delete(cb0_hex)
	osj := ea_get(t, &ctx, fmt.tprintf("/tx/%s/outspend/0", cb0_hex), 200, "outspend")
	ov, oerr2 := json.parse_string(osj, .JSON, false, context.temp_allocator)
	testing.expect_value(t, oerr2, nil)
	if oobj, ook := ov.(json.Object); ook {
		testing.expect_value(t, oobj["spent"].(json.Boolean), true)
		testing.expect_value(t, oobj["txid"].(json.String), spend_hex)
	}

	// address summary: A funded 2x50, spent 50
	// (bb_script scripts aren't standard classes, so use scripthash route)
	sh_a := hugin.scripthash(script_a)
	sh_hex := strings.clone(hex64(sh_a, hexbuf[:])) // esplora: forward hex
	defer delete(sh_hex)
	sj := ea_get(t, &ctx, fmt.tprintf("/scripthash/%s", sh_hex), 200, "scripthash summary")
	sv, serr := json.parse_string(sj, .JSON, false, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	if sobj, sok := sv.(json.Object); sok {
		cs := sobj["chain_stats"].(json.Object)
		testing.expect_value(t, cs["funded_txo_count"].(json.Float), 2)
		testing.expect_value(t, cs["funded_txo_sum"].(json.Float), f64(100 * COIN))
		testing.expect_value(t, cs["spent_txo_sum"].(json.Float), f64(50 * COIN))
		testing.expect_value(t, cs["tx_count"].(json.Float), 3)
	}

	// utxo list for A: one remaining coinbase output
	uj := ea_get(t, &ctx, fmt.tprintf("/scripthash/%s/utxo", sh_hex), 200, "utxo")
	uv, uerr := json.parse_string(uj, .JSON, false, context.temp_allocator)
	testing.expect_value(t, uerr, nil)
	if uarr, uok := uv.(json.Array); uok {
		testing.expect_value(t, len(uarr), 1)
	}

	// txs listing: newest first, both txs of A present
	tj := ea_get(t, &ctx, fmt.tprintf("/scripthash/%s/txs", sh_hex), 200, "txs")
	tv2, tverr2 := json.parse_string(tj, .JSON, false, context.temp_allocator)
	testing.expect_value(t, tverr2, nil)
	if tarr2, tok2 := tv2.(json.Array); tok2 {
		testing.expect_value(t, len(tarr2), 3)
	}

	// unknown route
	_ = ea_get(t, &ctx, "/definitely/not/a/route", 404, "unknown route")
	// mempool info without a mempool: zeros
	mj := ea_get(t, &ctx, "/mempool", 200, "mempool")
	testing.expect(t, strings.contains(mj, `"count":0`), "mempool should be empty")
}

// End-to-end HTTP: real daemon, real TCP, real GET.
@(test)
test_esplora_http :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbufA: [22]byte
	script_a := bb_script(0xD3, sbufA[:])
	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	_, _ = world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	box := Daemon_Box {
		cfg = w.cfg,
	}
	box.cfg.electrum = false
	box.cfg.esplora = true
	box.cfg.esplora_bind = "127.0.0.1:43121"
	box.cfg.mempool_off = true

	th := thread.create(daemon_thread)
	th.data = &box
	th.init_context = context
	thread.start(th)
	defer {
		sync.atomic_store(&box.stop, true)
		thread.join(th)
		thread.destroy(th)
	}

	sock: net.TCP_Socket
	connected := false
	for _ in 0 ..< 100 {
		s, derr := net.dial_tcp("127.0.0.1:43121")
		if derr == nil {
			sock = s
			connected = true
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, connected, "esplora port never opened")
	if !connected {return}

	req := "GET /blocks/tip/height HTTP/1.1\r\nHost: x\r\n\r\n"
	_, serr := net.send_tcp(sock, transmute([]byte)req)
	testing.expect_value(t, serr, nil)
	buf: [4096]byte
	total := 0
	deadline := time.now()
	for {
		if time.duration_seconds(time.since(deadline)) > 5 {break}
		n, rerr := net.recv_tcp(sock, buf[total:])
		if rerr != nil || n == 0 {break}
		total += n
		if strings.contains(string(buf[:total]), "\r\n\r\n") &&
		   strings.has_suffix(string(buf[:total]), "1") {break}
	}
	resp := string(buf[:total])
	testing.expectf(t, strings.contains(resp, "200 OK"), "bad response: %q", resp)
	testing.expectf(t, strings.has_suffix(resp, "\r\n\r\n1"), "body should be tip height 1: %q", resp)

	// keep-alive: second request on the same connection
	req2 := "GET /blocks/tip/hash HTTP/1.1\r\nHost: x\r\n\r\n"
	_, serr2 := net.send_tcp(sock, transmute([]byte)req2)
	testing.expect_value(t, serr2, nil)
	total2 := 0
	buf2: [4096]byte
	deadline = time.now()
	for {
		if time.duration_seconds(time.since(deadline)) > 5 {break}
		n, rerr := net.recv_tcp(sock, buf2[total2:])
		if rerr != nil || n == 0 {break}
		total2 += n
		if strings.contains(string(buf2[:total2]), "\r\n\r\n") {
			body_at := strings.index(string(buf2[:total2]), "\r\n\r\n")
			if total2 - body_at - 4 >= 64 {break}
		}
	}
	resp2 := string(buf2[:total2])
	testing.expectf(t, strings.contains(resp2, "200 OK"), "keep-alive request failed: %q", resp2)

	net.close(sock)
	time.sleep(300 * time.Millisecond)
}

// Concurrency: parallel HTTP clients, every response correct.
@(private = "file")
H_Hammer :: struct {
	port: int,
	n:    int,
	got:  int,
	fail: bool,
}

@(private = "file")
h_hammer_thread :: proc(t: ^thread.Thread) {
	box := (^H_Hammer)(t.data)
	sock, derr := net.dial_tcp(fmt.tprintf("127.0.0.1:%d", box.port))
	if derr != nil {
		box.fail = true
		return
	}
	defer net.close(sock)
	buf: [8192]byte
	for _ in 0 ..< box.n {
		req := "GET /blocks/tip/height HTTP/1.1\r\nHost: x\r\n\r\n"
		if _, serr := net.send_tcp(sock, transmute([]byte)req); serr != nil {
			box.fail = true
			return
		}
		total := 0
		deadline := time.now()
		done := false
		for !done {
			if time.duration_seconds(time.since(deadline)) > 5 {
				box.fail = true
				return
			}
			n, rerr := net.recv_tcp(sock, buf[total:])
			if rerr != nil || n == 0 {
				box.fail = true
				return
			}
			total += n
			s := string(buf[:total])
			if strings.contains(s, "\r\n\r\n1") {done = true}
		}
		box.got += 1
	}
}

@(test)
test_esplora_concurrent :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbufA: [22]byte
	script_a := bb_script(0xD4, sbufA[:])
	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	_, _ = world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	box := Daemon_Box {
		cfg = w.cfg,
	}
	box.cfg.electrum = false
	box.cfg.esplora = true
	box.cfg.esplora_bind = "127.0.0.1:43123"
	box.cfg.mempool_off = true

	th := thread.create(daemon_thread)
	th.data = &box
	th.init_context = context
	thread.start(th)
	defer {
		sync.atomic_store(&box.stop, true)
		thread.join(th)
		thread.destroy(th)
	}

	ready := false
	for _ in 0 ..< 100 {
		s, derr := net.dial_tcp("127.0.0.1:43123")
		if derr == nil {
			net.close(s)
			ready = true
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, ready, "esplora port never opened")
	if !ready {return}

	N :: 4
	M :: 15
	boxes: [N]H_Hammer
	clients: [N]^thread.Thread
	for i in 0 ..< N {
		boxes[i] = H_Hammer {
			port = 43123,
			n    = M,
		}
		clients[i] = thread.create(h_hammer_thread)
		clients[i].data = &boxes[i]
		clients[i].init_context = context
		thread.start(clients[i])
	}
	for i in 0 ..< N {
		thread.join(clients[i])
		thread.destroy(clients[i])
	}
	for i in 0 ..< N {
		testing.expectf(t, !boxes[i].fail, "client %d failed", i)
		testing.expect_value(t, boxes[i].got, M)
	}
	time.sleep(300 * time.Millisecond)
}

// Scripthash wire conventions — the bug that made a real wallet see an
// empty history while the CLI showed it correctly.
//
// Electrum sends sha256(spk) REVERSED (protocol spec: hashes are
// little-endian in hex). Esplora clients send it FORWARD (rust-bitcoin
// only reverses txid-like hashes; a plain sha256 prints big-endian).
// Both must land on the same index rows, and both must agree with the
// address route.
@(test)
test_scripthash_wire_conventions :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA: [22]byte
	script_a := bb_script(0xE7, sbufA[:]) // P2WPKH: a real, addressable script
	sh_a := hugin.scripthash(script_a)

	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	_, _ = world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	ctx := hugin.Electrum_Ctx {
		idx     = idx,
		version = "hrafnar wiretest",
	}

	hexbuf: [64]byte
	forward := strings.clone(hex64(sh_a, hexbuf[:])) // sha256 as-is
	defer delete(forward)
	reversed := strings.clone(hugin.txid_to_hex(sh_a, hexbuf[:])) // display order
	defer delete(reversed)
	testing.expect(t, forward != reversed, "test vector is a palindrome; pick another script")

	addr, aok := hugin.script_to_address(script_a, .Mainnet)
	testing.expect(t, aok, "P2WPKH script must render as an address")
	defer delete(addr)

	// --- Electrum: REVERSED hex resolves; forward must NOT ---------------
	er := hugin.electrum_handle(
		&ctx,
		fmt.tprintf(`{{"id":1,"method":"blockchain.scripthash.get_history","params":["%s"]}}`, reversed),
		context.temp_allocator,
	)
	testing.expectf(t, strings.count(er, "tx_hash") == 2, "electrum reversed hex must find 2 entries: %q", er)

	ew := hugin.electrum_handle(
		&ctx,
		fmt.tprintf(`{{"id":2,"method":"blockchain.scripthash.get_history","params":["%s"]}}`, forward),
		context.temp_allocator,
	)
	testing.expectf(t, strings.count(ew, "tx_hash") == 0, "electrum forward hex must find nothing: %q", ew)

	// --- Esplora /scripthash: FORWARD hex resolves -----------------------
	st, _, sr := hugin.esplora_handle(&ctx, "GET", fmt.tprintf("/scripthash/%s/txs", forward), "", context.temp_allocator)
	testing.expect_value(t, st, 200)
	testing.expectf(t, strings.count(sr, `"txid"`) >= 2, "esplora forward scripthash must find 2 txs: %q", sr)

	sum_status, _, sum := hugin.esplora_handle(&ctx, "GET", fmt.tprintf("/scripthash/%s", forward), "", context.temp_allocator)
	testing.expect_value(t, sum_status, 200)
	testing.expectf(t, strings.contains(sum, `"funded_txo_count":2`), "esplora scripthash summary wrong: %q", sum)

	// --- Esplora /address: must match the scripthash route ---------------
	at, _, ar := hugin.esplora_handle(&ctx, "GET", fmt.tprintf("/address/%s", addr), "", context.temp_allocator)
	testing.expect_value(t, at, 200)
	testing.expectf(t, strings.contains(ar, `"funded_txo_count":2`), "esplora address summary wrong: %q", ar)
	testing.expectf(
		t,
		strings.contains(ar, fmt.tprintf(`"funded_txo_sum":%d`, 2 * 50 * COIN)),
		"esplora address sum wrong: %q",
		ar,
	)
}


// bdk_esplora rebuilds each transaction from the JSON (version, locktime,
// inputs with prevout/scriptsig/SEQUENCE/witness, outputs) and derives its
// txid. A wrong field there yields a wrong txid and the wallet silently
// discards everything — which is exactly how a placeholder "sequence":0
// produced an empty wallet against a perfectly good index. Assert the
// fields a rebuild depends on.
@(test)
test_esplora_tx_rebuildable :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA, sbufB: [22]byte
	script_a := bb_script(0xE9, sbufA[:])
	script_b := bb_script(0xEA, sbufB[:])

	h0, cb0_id := world_coinbase(t, &w, {}, script_a, 1)
	cb1, _ := bb_tx(nil, {{50 * COIN, script_a}}, 2)
	append(&w.tx_raws, cb1)
	spend, spend_id := bb_tx({{prev = {cb0_id, 0}}}, {{49 * COIN, script_b}})
	append(&w.tx_raws, spend)
	blk1, _ := bb_block(h0, {cb1, spend}, 2)
	append(&w.blocks, blk1)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	ctx := hugin.Electrum_Ctx{idx = idx, version = "hrafnar rebuild"}
	hexbuf: [64]byte
	spend_hex := strings.clone(hugin.txid_to_hex(spend_id, hexbuf[:]))
	defer delete(spend_hex)

	_, _, body := hugin.esplora_handle(&ctx, "GET", fmt.tprintf("/tx/%s", spend_hex), "", context.temp_allocator)
	v, jerr := json.parse_string(body, .JSON, false, context.temp_allocator)
	testing.expect_value(t, jerr, nil)
	obj, ok := v.(json.Object)
	testing.expect(t, ok, "tx json must be an object")
	if !ok {return}

	// The real transaction, for comparison.
	real_tx, consumed := hugin.tx_parse(spend, false)
	testing.expect(t, consumed > 0, "test tx must parse")

	testing.expect_value(t, obj["txid"].(json.String), spend_hex)
	testing.expect_value(t, obj["size"].(json.Float), f64(len(spend)))
	testing.expect_value(t, obj["weight"].(json.Float), f64(real_tx.weight))

	vin, vok := obj["vin"].(json.Array)
	testing.expect(t, vok && len(vin) == 1, "one input expected")
	if !vok || len(vin) != 1 {return}
	in0 := vin[0].(json.Object)

	// Sequence must be the REAL value from the wire, never a placeholder.
	iit: hugin.Tx_Input_Iter
	hugin.tx_input_iter_init(&iit, &real_tx)
	inp, _, iok := hugin.tx_input_iter_next(&iit)
	testing.expect(t, iok, "input must iterate")
	testing.expect_value(t, in0["sequence"].(json.Float), f64(inp.sequence))
	testing.expectf(t, inp.sequence != 0, "test vector should use a nonzero sequence (got %d)", inp.sequence)

	testing.expect_value(t, in0["txid"].(json.String), strings.clone(hugin.txid_to_hex(cb0_id, hexbuf[:]), context.temp_allocator))
	testing.expect_value(t, in0["vout"].(json.Float), 0)
	testing.expect_value(t, obj["version"].(json.Float), f64(u32(spend[0]) | u32(spend[1])<<8 | u32(spend[2])<<16 | u32(spend[3])<<24))
	testing.expect_value(t, obj["locktime"].(json.Float), f64(u32(spend[len(spend)-4]) | u32(spend[len(spend)-3])<<8 | u32(spend[len(spend)-2])<<16 | u32(spend[len(spend)-1])<<24))
}

// Paging through an address's transactions must be BOUNDED and CORRECT.
//
// It used to resolve the address's ENTIRE history to emit one 25-entry page,
// so every page cost what the deepest page costs — thousands of block reads
// to return 25 rows on a busy address. That is why the endpoint carried a
// history guard at all. It now walks rows (cheap) and resolves txids only
// for the page it emits, so the guard is gone from this route.
//
// The delicate part is the cursor: Txloc_Value carries height but not txnum,
// so when an address appears in several transactions in the SAME block,
// height alone does not say where to resume.
//
// The fixture is shaped to actually exercise that. SEVEN transactions per
// block means a 25-entry page ends 4 transactions into a block (25 = 3*7+4),
// so the cursor is NOT the top entry at its height. With 3 per block the
// boundary always lands on a block's first entry and a cursor that ignores
// txnum passes anyway — verified, which is why the shape matters. The
// coinbase also pays the address 8 times, so several history rows share one
// (height, txnum) and the dedupe is exercised too.
@(test)
test_esplora_txs_pagination_is_bounded_and_exact :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbuf: [22]byte
	script := bb_script(0xE7, sbuf[:])

	Spendable :: struct {
		id:   [32]u8,
		vout: u32,
	}
	pool := make([dynamic]Spendable, 0, 128, context.allocator)
	defer delete(pool)

	BLOCKS :: 14
	PER_BLOCK_SPENDS :: 6
	total_txs := 0
	prev: [32]u8
	for b in 0 ..< BLOCKS {
		txs := make([dynamic][]byte, 0, 8, context.allocator)
		defer delete(txs)

		cb_outs := make([dynamic]BB_Output, 0, 8, context.temp_allocator)
		for _ in 0 ..< 8 {
			append(&cb_outs, BB_Output{6 * COIN, script})
		}
		cb, cb_id := bb_tx(nil, cb_outs[:], u32(1000 + b))
		append(&w.tx_raws, cb)
		append(&txs, cb)

		fresh := make([dynamic]Spendable, 0, 16, context.temp_allocator)
		for v in 0 ..< 8 {
			append(&fresh, Spendable{cb_id, u32(v)})
		}
		spends := 0
		for len(pool) > 0 && spends < PER_BLOCK_SPENDS {
			src := pool[len(pool) - 1]
			pop(&pool)
			raw, id := bb_tx({{prev = {src.id, src.vout}}}, {{5 * COIN, script}})
			append(&w.tx_raws, raw)
			append(&txs, raw)
			append(&fresh, Spendable{id, 0})
			spends += 1
		}
		for sp in fresh {
			append(&pool, sp)
		}
		total_txs += len(txs)

		blk, h := bb_block(prev, txs[:], u32(1000 + b))
		append(&w.blocks, blk)
		prev = h
	}
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	testing.expectf(t, total_txs > 25, "fixture must exceed one page, got %d", total_txs)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	ctx := hugin.Electrum_Ctx {
		idx         = idx,
		version     = "hrafnar pagetest",
		// Deliberately BELOW this address's history size: a bounded page must
		// serve it anyway. This is the guard that used to reject the route.
		max_history = 5,
	}

	sh := hugin.scripthash(script)
	hexbuf: [64]byte
	sh_hex := strings.clone(hex64(sh, hexbuf[:])) // esplora: forward hex
	defer delete(sh_hex)

	seen := make([dynamic]string, 0, 128, context.temp_allocator)
	dedupe := make(map[string]bool, context.temp_allocator)
	heights := make([dynamic]int, 0, 128, context.temp_allocator)
	cursor := ""
	for _ in 0 ..< 20 {
		path := fmt.tprintf("/scripthash/%s/txs/chain", sh_hex)
		if cursor != "" {
			path = fmt.tprintf("/scripthash/%s/txs/chain/%s", sh_hex, cursor)
		}
		body := ea_get(t, &ctx, path, 200, "txs page")
		parsed, perr := json.parse_string(body, .JSON, false, context.temp_allocator)
		testing.expect_value(t, perr, nil)
		arr, aok := parsed.(json.Array)
		if !aok || len(arr) == 0 {break}
		for v in arr {
			obj, ook := v.(json.Object)
			if !ook {continue}
			id, idok := obj["txid"].(json.String)
			if !idok {continue}
			if id in dedupe {
				testing.expectf(t, false, "txid %s was served on more than one page", id)
			}
			dedupe[id] = true
			append(&seen, id)
			if st, sok := obj["status"].(json.Object); sok {
				if hf, hok := st["block_height"].(json.Float); hok {
					append(&heights, int(hf))
				}
			}
		}
		cursor = seen[len(seen) - 1]
	}

	testing.expectf(
		t,
		len(seen) == total_txs,
		"paging returned %d of %d transactions — pages drop or repeat entries across same-height boundaries",
		len(seen),
		total_txs,
	)
	for i in 1 ..< len(heights) {
		testing.expectf(
			t,
			heights[i] <= heights[i - 1],
			"pages are not newest-first across the boundary: height %d followed %d",
			heights[i],
			heights[i - 1],
		)
	}
}
