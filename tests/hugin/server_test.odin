package hugin_tests

// Request/response protocol tests over a built index — the layer shared by
// the daemon and the CLI's direct path.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

import hugin "../../hugin"

hex64 :: proc(h: [32]u8, buf: []byte) -> string {
	HEXD := "0123456789abcdef"
	for b, i in h {
		buf[i * 2] = HEXD[b >> 4]
		buf[i * 2 + 1] = HEXD[b & 0xF]
	}
	return string(buf[:64])
}

@(test)
test_serve_request :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA: [22]byte
	script_a := bb_script(0x5A, sbufA[:])
	sh_a := hugin.scripthash(script_a)

	h0, cb0_id := world_coinbase(t, &w, {}, script_a, 1)
	h1, _ := world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	hexbuf: [64]byte

	// balance
	resp := hugin.serve_request(idx, nil, fmt.tprintf("balance %s", hex64(sh_a, hexbuf[:])), context.temp_allocator)
	testing.expect_value(t, resp, "OK\n10000000000 sat (100.00000000 BTC)\n")

	// history
	resp = hugin.serve_request(idx, nil, fmt.tprintf("history %s 0 -1", hex64(sh_a, hexbuf[:])), context.temp_allocator)
	testing.expect(t, strings.has_prefix(resp, "OK\n"), "history must succeed")
	testing.expect(t, strings.contains(resp, "2 entries"), "history must list both fundings")

	// history with limit
	resp = hugin.serve_request(idx, nil, fmt.tprintf("history %s 0 1", hex64(sh_a, hexbuf[:])), context.temp_allocator)
	testing.expect(t, strings.contains(resp, "1 entries"), "limit must apply")

	// tx metadata + raw
	resp = hugin.serve_request(idx, nil, fmt.tprintf("tx %s 0", hex64(cb0_id, hexbuf[:])), context.temp_allocator)
	testing.expect(t, strings.has_prefix(resp, "OK\ntxid   "), "tx must succeed")
	testing.expect(t, strings.contains(resp, "height 0"), "tx height")
	resp = hugin.serve_request(idx, nil, fmt.tprintf("tx %s 1", hex64(cb0_id, hexbuf[:])), context.temp_allocator)
	testing.expect(t, strings.has_prefix(resp, "OK\n02000000"), "raw tx must start with version bytes")

	// outpoint (unspent coinbase)
	resp = hugin.serve_request(idx, nil, fmt.tprintf("outpoint %s 0", hex64(cb0_id, hexbuf[:])), context.temp_allocator)
	testing.expect_value(t, resp, "OK\nunspent (or unknown outpoint)\n")

	// history lines carry resolved txids
	{
		hb: [64]byte
		want_txid := hugin.txid_to_hex(cb0_id, hb[:])
		resp = hugin.serve_request(idx, nil, fmt.tprintf("history %s 0 -1", hex64(sh_a, hexbuf[:])), context.temp_allocator)
		testing.expect(t, strings.contains(resp, want_txid), "history must include the funding txid")
	}

	// utxos: both coinbases unspent, total = balance
	resp = hugin.serve_request(idx, nil, fmt.tprintf("utxos %s", hex64(sh_a, hexbuf[:])), context.temp_allocator)
	testing.expect(t, strings.has_prefix(resp, "OK\n"), "utxos must succeed")
	testing.expect(t, strings.contains(resp, "2 utxos, 10000000000 sat"), "utxos summary")

	// header
	resp = hugin.serve_request(idx, nil, "header 0", context.temp_allocator)
	testing.expect(t, strings.has_prefix(resp, "OK\nheight  0\n"), "header 0")
	testing.expect(t, strings.contains(resp, "txs     1"), "header tx count")
	resp = hugin.serve_request(idx, nil, "header 999", context.temp_allocator)
	testing.expect_value(t, resp, "ERR height beyond tip\n")

	// tip
	resp = hugin.serve_request(idx, nil, "tip", context.temp_allocator)
	testing.expect(t, strings.has_prefix(resp, "OK\nheight 1\n"), "tip height")

	// errors: unknown command, malformed hex, bad arity
	resp = hugin.serve_request(idx, nil, "frobnicate", context.temp_allocator)
	testing.expect_value(t, resp, "ERR unknown command\n")
	resp = hugin.serve_request(idx, nil, "balance zzzz", context.temp_allocator)
	testing.expect_value(t, resp, "ERR bad scripthash\n")
	resp = hugin.serve_request(idx, nil, "balance", context.temp_allocator)
	testing.expect_value(t, resp, "ERR usage: balance <scripthash>\n")
	resp = hugin.serve_request(idx, nil, "", context.temp_allocator)
	testing.expect_value(t, resp, "ERR empty request\n")

	// missing tx
	fake: [32]u8
	fake[3] = 0x77
	resp = hugin.serve_request(idx, nil, fmt.tprintf("tx %s 0", hex64(fake, hexbuf[:])), context.temp_allocator)
	testing.expect_value(t, resp, "ERR transaction not found\n")
	_ = h1
}

// Every command's json variant must return valid JSON with the expected
// top-level fields — parsed with core:encoding/json, not eyeballed.
@(test)
test_serve_request_json :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA: [22]byte
	script_a := bb_script(0x6A, sbufA[:])
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

	hexbuf: [64]byte

	parse_ok :: proc(t: ^testing.T, resp: string, what: string) -> json.Value {
		testing.expectf(t, strings.has_prefix(resp, "OK\n"), "%s: not OK: %q", what, resp)
		if !strings.has_prefix(resp, "OK\n") {return nil}
		v, jerr := json.parse_string(resp[3:], .JSON, false, context.temp_allocator)
		testing.expectf(t, jerr == nil, "%s: bad json %v: %q", what, jerr, resp)
		return v
	}

	v := parse_ok(t, hugin.serve_request(idx, nil, fmt.tprintf("json balance %s", hex64(sh_a, hexbuf[:])), context.temp_allocator), "balance")
	if obj, ok := v.(json.Object); ok {
		testing.expect_value(t, obj["confirmed"].(json.Float), 2 * 50 * f64(COIN))
		testing.expect_value(t, obj["mempool"].(json.Boolean), false)
	} else {
		testing.expect(t, false, "balance: not an object")
	}

	v = parse_ok(t, hugin.serve_request(idx, nil, fmt.tprintf("json history %s 0 -1", hex64(sh_a, hexbuf[:])), context.temp_allocator), "history")
	if obj, ok := v.(json.Object); ok {
		entries, eok := obj["entries"].(json.Array)
		testing.expect(t, eok, "history: entries missing")
		if eok {testing.expect_value(t, len(entries), 2)}
	}

	v = parse_ok(t, hugin.serve_request(idx, nil, fmt.tprintf("json utxos %s", hex64(sh_a, hexbuf[:])), context.temp_allocator), "utxos")
	if obj, ok := v.(json.Object); ok {
		testing.expect_value(t, obj["total"].(json.Float), 2 * 50 * f64(COIN))
	}

	v = parse_ok(t, hugin.serve_request(idx, nil, "json tip", context.temp_allocator), "tip")
	if obj, ok := v.(json.Object); ok {
		testing.expect_value(t, obj["height"].(json.Float), f64(1))
		_, is_null := obj["mempool"].(json.Null)
		testing.expect(t, is_null, "tip: mempool should be null without a daemon")
	}

	v = parse_ok(t, hugin.serve_request(idx, nil, fmt.tprintf("json tx %s 0", hex64(cb0_id, hexbuf[:])), context.temp_allocator), "tx")
	if obj, ok := v.(json.Object); ok {
		testing.expect_value(t, obj["height"].(json.Float), f64(0))
	}

	v = parse_ok(t, hugin.serve_request(idx, nil, fmt.tprintf("json merkle %s", hex64(cb0_id, hexbuf[:])), context.temp_allocator), "merkle")
	if obj, ok := v.(json.Object); ok {
		branch, bok := obj["branch"].(json.Array)
		testing.expect(t, bok, "merkle: branch missing")
		if bok {testing.expect_value(t, len(branch), 0)}
	}

	v = parse_ok(t, hugin.serve_request(idx, nil, fmt.tprintf("json outpoint %s 0", hex64(cb0_id, hexbuf[:])), context.temp_allocator), "outpoint")
	if obj, ok := v.(json.Object); ok {
		testing.expect_value(t, obj["spent"].(json.Boolean), false)
	}

	v = parse_ok(t, hugin.serve_request(idx, nil, fmt.tprintf("json header %d", 0), context.temp_allocator), "header")
	if obj, ok := v.(json.Object); ok {
		testing.expect_value(t, obj["height"].(json.Float), f64(0))
	}
}
