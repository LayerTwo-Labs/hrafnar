package hugin_tests

// Electrum protocol handler tests: full JSON-RPC lines in, responses
// parsed with core:encoding/json — the same discipline a wallet applies.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

import hugin "../../hugin"

@(private = "file")
e_call :: proc(t: ^testing.T, ctx: ^hugin.Electrum_Ctx, line: string, what: string) -> (result: json.Value, eobj: json.Object, ok: bool) {
	resp := hugin.electrum_handle(ctx, line, context.temp_allocator)
	testing.expectf(t, strings.has_suffix(resp, "\n"), "%s: missing newline", what)
	v, jerr := json.parse_string(resp, .JSON, false, context.temp_allocator)
	testing.expectf(t, jerr == nil, "%s: bad response json %v: %q", what, jerr, resp)
	if jerr != nil {return nil, nil, false}
	obj, ook := v.(json.Object)
	testing.expectf(t, ook, "%s: response not an object: %q", what, resp)
	if !ook {return nil, nil, false}
	if ev, has := obj["error"]; has {
		eo, _ := ev.(json.Object)
		return nil, eo, true
	}
	return obj["result"], nil, true
}

@(test)
test_electrum_handler :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA: [22]byte
	script_a := bb_script(0x7A, sbufA[:])
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

	ctx := hugin.Electrum_Ctx {
		idx     = idx,
		banner  = "test banner",
		version = "hrafnar test",
	}

	hexbuf: [64]byte
	sh_hex := strings.clone(hugin.txid_to_hex(sh_a, hexbuf[:])) // display order, as a client sends
	defer delete(sh_hex)
	cb0_hex := strings.clone(hugin.txid_to_hex(cb0_id, hexbuf[:]))
	defer delete(cb0_hex)

	// server.version
	res, _, ok := e_call(t, &ctx, `{"jsonrpc":"2.0","id":1,"method":"server.version","params":["testclient","1.4"]}`, "version")
	if arr, aok := res.(json.Array); ok && aok {
		testing.expect_value(t, len(arr), 2)
		if len(arr) == 2 {
			testing.expect_value(t, arr[0].(json.String), "hrafnar test")
			testing.expect_value(t, arr[1].(json.String), "1.4")
		}
	} else {
		testing.expect(t, false, "version: bad result")
	}

	// banner
	res, _, ok = e_call(t, &ctx, `{"id":2,"method":"server.banner","params":[]}`, "banner")
	if ok {testing.expect_value(t, res.(json.String), "test banner")}

	// get_balance
	res, _, ok = e_call(t, &ctx, fmt.tprintf(`{{"id":3,"method":"blockchain.scripthash.get_balance","params":["%s"]}}`, sh_hex), "balance")
	if obj, bok := res.(json.Object); ok && bok {
		testing.expect_value(t, obj["confirmed"].(json.Float), 2 * 50 * f64(COIN))
		testing.expect_value(t, obj["unconfirmed"].(json.Float), 0)
	} else {
		testing.expect(t, false, "balance: bad result")
	}

	// get_history: two coinbases, ascending heights, display-order txids
	res, _, ok = e_call(t, &ctx, fmt.tprintf(`{{"id":4,"method":"blockchain.scripthash.get_history","params":["%s"]}}`, sh_hex), "history")
	if arr, aok := res.(json.Array); ok && aok {
		testing.expect_value(t, len(arr), 2)
		if len(arr) == 2 {
			e0, _ := arr[0].(json.Object)
			testing.expect_value(t, e0["height"].(json.Float), 0)
			testing.expect_value(t, e0["tx_hash"].(json.String), cb0_hex)
		}
	} else {
		testing.expect(t, false, "history: bad result")
	}

	// headers.subscribe returns the tip
	res, _, ok = e_call(t, &ctx, `{"id":5,"method":"blockchain.headers.subscribe"}`, "headers.subscribe")
	if obj, hok := res.(json.Object); ok && hok {
		testing.expect_value(t, obj["height"].(json.Float), 1)
		hex, sok := obj["hex"].(json.String)
		testing.expect(t, sok, "headers.subscribe: hex missing")
		if sok {testing.expect_value(t, len(hex), 160)}
	}

	// scripthash.subscribe: status must equal sha256 over "txid:height:"
	res, _, ok = e_call(t, &ctx, fmt.tprintf(`{{"id":6,"method":"blockchain.scripthash.subscribe","params":["%s"]}}`, sh_hex), "subscribe")
	if status, sok := res.(json.String); ok && sok {
		entries, herr := hugin.query_history_resolved(idx, sh_a, 0, -1, context.temp_allocator)
		testing.expect_value(t, herr, nil)
		b := strings.builder_make(context.temp_allocator)
		for r in entries {
			hb: [64]byte
			fmt.sbprintf(&b, "%s:%d:", hugin.txid_to_hex(r.txid, hb[:]), r.entry.height)
		}
		digest := hugin.sha256(transmute([]byte)strings.to_string(b))
		want := strings.builder_make(context.temp_allocator)
		HEXD := "0123456789abcdef"
		for by in digest {
			strings.write_byte(&want, HEXD[by >> 4])
			strings.write_byte(&want, HEXD[by & 0xF])
		}
		testing.expect_value(t, string(status), strings.to_string(want))
	} else {
		testing.expect(t, false, "subscribe: bad result")
	}

	// transaction.get returns hex
	res, _, ok = e_call(t, &ctx, fmt.tprintf(`{{"id":7,"method":"blockchain.transaction.get","params":["%s"]}}`, cb0_hex), "tx.get")
	if hex, sok := res.(json.String); ok && sok {
		testing.expect(t, len(hex) > 0 && len(hex) % 2 == 0, "tx.get: odd hex")
	}

	// get_merkle on a single-tx block: empty branch
	res, _, ok = e_call(t, &ctx, fmt.tprintf(`{{"id":8,"method":"blockchain.transaction.get_merkle","params":["%s"]}}`, cb0_hex), "get_merkle")
	if obj, mok := res.(json.Object); ok && mok {
		testing.expect_value(t, obj["block_height"].(json.Float), 0)
		branch, brok := obj["merkle"].(json.Array)
		testing.expect(t, brok, "get_merkle: merkle missing")
		if brok {testing.expect_value(t, len(branch), 0)}
	}

	// broadcast without RPC: error object
	_, eobj, _ := e_call(t, &ctx, `{"id":9,"method":"blockchain.transaction.broadcast","params":["0100"]}`, "broadcast")
	testing.expect(t, eobj != nil, "broadcast: expected error without rpc")

	// estimatefee without RPC: -1
	res, _, ok = e_call(t, &ctx, `{"id":10,"method":"blockchain.estimatefee","params":[6]}`, "estimatefee")
	if ok {testing.expect_value(t, res.(json.Float), -1)}

	// fee histogram without mempool: []
	res, _, ok = e_call(t, &ctx, `{"id":11,"method":"mempool.get_fee_histogram"}`, "feehist")
	if arr, aok := res.(json.Array); ok && aok {
		testing.expect_value(t, len(arr), 0)
	}

	// unknown method
	_, eobj, _ = e_call(t, &ctx, `{"id":12,"method":"no.such.method"}`, "unknown")
	testing.expect(t, eobj != nil, "unknown method must error")
	if eobj != nil {
		testing.expect_value(t, eobj["code"].(json.Float), -32601)
	}

	// batch: two calls, array response
	bresp := hugin.electrum_handle(&ctx, `[{"id":13,"method":"server.ping"},{"id":14,"method":"server.ping"}]`, context.temp_allocator)
	bv, bjerr := json.parse_string(bresp, .JSON, false, context.temp_allocator)
	testing.expect_value(t, bjerr, nil)
	if barr, bok := bv.(json.Array); bok {
		testing.expect_value(t, len(barr), 2)
	} else {
		testing.expect(t, false, "batch: not an array")
	}

	// parse error
	presp := hugin.electrum_handle(&ctx, `{nope`, context.temp_allocator)
	testing.expect(t, strings.contains(presp, "-32700"), "bad json must yield parse error")
}

// Phase 2: subscriptions and push notifications, exercised without
// sockets — a fake connection collects pushed lines in its out queue.
@(test)
test_electrum_push :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbufA: [22]byte
	script_a := bb_script(0x9E, sbufA[:])
	sh_a := hugin.scripthash(script_a)

	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	h1, _ := world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}

	ctx := hugin.Electrum_Ctx {
		idx     = idx,
		banner  = "b",
		version = "hrafnar pushtest",
	}
	srv: hugin.Electrum_Server
	hugin.electrum_server_init(&srv, &ctx)
	defer hugin.electrum_server_destroy(&srv)
	conn := hugin.electrum_conn_new(&srv)

	hexbuf: [64]byte
	sh_hex := strings.clone(hugin.txid_to_hex(sh_a, hexbuf[:]))
	defer delete(sh_hex)

	// Subscribe through the real handler: actions carry the registration,
	// applied on the loop thread (here: directly).
	acts := make([dynamic]hugin.E_Sub_Action, context.temp_allocator)
	resp := hugin.electrum_handle(&ctx, fmt.tprintf(`{{"id":1,"method":"blockchain.scripthash.subscribe","params":["%s"]}}`, sh_hex), context.temp_allocator, &acts)
	testing.expect(t, strings.contains(resp, `"result":"`), "subscribe must return a status")
	resp = hugin.electrum_handle(&ctx, `{"id":2,"method":"blockchain.headers.subscribe"}`, context.temp_allocator, &acts)
	testing.expect(t, strings.contains(resp, `"height":1`), "headers.subscribe must return the tip")
	hugin.electrum_apply_actions(&srv, conn, acts[:])

	// A notify for an untouched set pushes nothing.
	empty_touched := make(map[[32]u8]struct {}, context.temp_allocator)
	hugin.electrum_notify(&srv, &empty_touched)
	testing.expect_value(t, len(conn.outq), 0)

	// Mine a new block paying the subscribed script; catch-up reports it.
	_, _ = world_coinbase(t, &w, h1, script_a, 3)
	world_flush(t, &w)
	rep: hugin.Catchup_Report
	rep.touched = make(map[[32]u8]struct {}, context.temp_allocator)
	testing.expect_value(t, hugin.catchup_run(w.cfg, &rep), nil)
	testing.expect(t, rep.tip_changed, "tip must have changed")
	testing.expect(t, sh_a in rep.touched, "subscribed scripthash must be in the touched set")

	// Refresh the index (as the daemon does), then push.
	hugin.index_close(idx)
	idx2, oerr2 := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr2, nil)
	if oerr2 != nil {return}
	defer hugin.index_close(idx2)
	ctx.idx = idx2

	hugin.electrum_notify_headers(&srv)
	hugin.electrum_notify(&srv, &rep.touched, rep.reorg)

	pushed := string(conn.outq[:])
	testing.expectf(t, strings.contains(pushed, `"method":"blockchain.headers.subscribe"`), "missing headers push: %q", pushed)
	testing.expectf(t, strings.contains(pushed, `"height":2`), "headers push must carry new tip: %q", pushed)
	testing.expectf(t, strings.contains(pushed, `"method":"blockchain.scripthash.subscribe"`), "missing status push: %q", pushed)
	testing.expectf(t, strings.contains(pushed, sh_hex), "status push must name the scripthash: %q", pushed)

	// Same touched set again: status unchanged, nothing new pushed.
	before := len(conn.outq)
	hugin.electrum_notify(&srv, &rep.touched)
	testing.expect_value(t, len(conn.outq), before)

	// Unsubscribe stops pushes.
	acts2 := make([dynamic]hugin.E_Sub_Action, context.temp_allocator)
	resp = hugin.electrum_handle(&ctx, fmt.tprintf(`{{"id":3,"method":"blockchain.scripthash.unsubscribe","params":["%s"]}}`, sh_hex), context.temp_allocator, &acts2)
	testing.expect(t, strings.contains(resp, "true"), "unsubscribe must return true")
	hugin.electrum_apply_actions(&srv, conn, acts2[:])
	clear(&conn.outq)
	hugin.electrum_notify(&srv, &rep.touched, true)
	testing.expect_value(t, len(conn.outq), 0)
}

// The history guard: oversized addresses are refused before any block
// read, so one client cannot stall the shared thread.
@(test)
test_electrum_history_guard :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbufA: [22]byte
	script_a := bb_script(0xAF, sbufA[:])
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
		idx         = idx,
		banner      = "b",
		version     = "hrafnar guardtest",
		max_history = 1, // the address has 2 entries: over the limit
	}
	hexbuf: [64]byte
	sh_hex := strings.clone(hugin.txid_to_hex(sh_a, hexbuf[:]))
	defer delete(sh_hex)

	for method in ([]string{"blockchain.scripthash.get_history", "blockchain.scripthash.listunspent", "blockchain.scripthash.subscribe"}) {
		resp := hugin.electrum_handle(&ctx, fmt.tprintf(`{{"id":1,"method":"%s","params":["%s"]}}`, method, sh_hex), context.temp_allocator)
		testing.expectf(t, strings.contains(resp, "history too large"), "%s: guard did not fire: %q", method, resp)
	}

	// Raise the limit: everything works again.
	ctx.max_history = 100
	resp := hugin.electrum_handle(&ctx, fmt.tprintf(`{{"id":2,"method":"blockchain.scripthash.get_history","params":["%s"]}}`, sh_hex), context.temp_allocator)
	testing.expect(t, strings.contains(resp, `"result":[`), "raised limit must serve history")

	// get_balance is cheap (no txid resolution) and stays uncapped.
	ctx.max_history = 1
	resp = hugin.electrum_handle(&ctx, fmt.tprintf(`{{"id":3,"method":"blockchain.scripthash.get_balance","params":["%s"]}}`, sh_hex), context.temp_allocator)
	testing.expect(t, strings.contains(resp, `"confirmed"`), "balance must not be capped")
}
