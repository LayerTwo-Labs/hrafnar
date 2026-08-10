package hugin

// Esplora-compatible REST API (Blockstream's schema, the one
// bdk_esplora deserializes). Pure request handler: method + path in,
// (status, content-type, body) out — the HTTP socket layer sits apart,
// and tests call this directly.
//
// Values are integer satoshis throughout, never BTC floats.

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

import "core:encoding/json"

import munin "../munin"

json_Object :: json.Object
json_Float :: json.Float
json_String :: json.String

ESPLORA_PAGE_TXS :: 25 // /txs pagination, matching Blockstream
ESPLORA_PAGE_BLOCKS :: 10 // /blocks summaries per page

// esplora_handle routes one request. Runs on a query worker; everything
// it reads is the request-scope snapshot (idx acquired, mempool
// shared-locked) exactly like electrum_handle.
esplora_handle :: proc(
	ctx: ^Electrum_Ctx,
	method: string,
	path: string,
	body: string,
	allocator := context.allocator,
) -> (
	status: int,
	ctype: string,
	resp: string,
) {
	segs := make([dynamic]string, 0, 8, context.temp_allocator)
	for part in strings.split(path, "/", context.temp_allocator) {
		if part != "" {append(&segs, part)}
	}

	if method == "POST" {
		if len(segs) == 1 && segs[0] == "tx" {
			return ea_broadcast(ctx, body, allocator)
		}
		return ea_text(404, "not found", allocator)
	}
	if method != "GET" {
		return ea_text(405, "method not allowed", allocator)
	}

	idx := ctx.idx
	switch {
	case len(segs) == 3 && segs[0] == "blocks" && segs[1] == "tip" && segs[2] == "height":
		return ea_text(200, fmt.tprintf("%d", index_tip_height(idx)), allocator)
	case len(segs) == 3 && segs[0] == "blocks" && segs[1] == "tip" && segs[2] == "hash":
		tip := index_tip_height(idx)
		if tip < 0 {return ea_text(404, "no tip", allocator)}
		hb: [64]byte
		return ea_text(200, txid_to_hex(idx.chain[tip].hash, hb[:]), allocator)
	case len(segs) == 1 && segs[0] == "blocks":
		return ea_blocks(ctx, index_tip_height(idx), allocator)
	case len(segs) == 2 && segs[0] == "blocks":
		start, ok := strconv.parse_int(segs[1], 10)
		if !ok {return ea_text(400, "bad height", allocator)}
		return ea_blocks(ctx, start, allocator)
	case len(segs) == 2 && segs[0] == "block-height":
		h, ok := strconv.parse_int(segs[1], 10)
		if !ok || h < 0 || h >= len(idx.chain) {
			return ea_text(404, "Block not found", allocator)
		}
		hb: [64]byte
		return ea_text(200, txid_to_hex(idx.chain[h].hash, hb[:]), allocator)
	case len(segs) >= 2 && segs[0] == "block":
		return ea_block_route(ctx, segs[:], allocator)
	case len(segs) >= 2 && segs[0] == "tx":
		return ea_tx_route(ctx, segs[:], allocator)
	case len(segs) >= 2 && segs[0] == "address":
		sh, aerr := address_to_scripthash(segs[1], idx.cfg.network)
		if aerr != nil {
			return ea_text(400, "Invalid Bitcoin address", allocator)
		}
		return ea_addr_route(ctx, sh, segs[1], segs[:], allocator)
	case len(segs) >= 2 && segs[0] == "scripthash":
		// Esplora scripthashes are FORWARD sha256 hex — unlike Electrum's
		// reversed convention (rust-bitcoin only byte-reverses txid-like
		// hashes for display, and esplora clients format plain sha256).
		shb, ok := hex_decode_32(segs[1])
		if !ok {
			return ea_text(400, "bad scripthash", allocator)
		}
		return ea_addr_route(ctx, shb, "", segs[:], allocator)
	case len(segs) == 1 && segs[0] == "mempool":
		return ea_mempool_info(ctx, allocator)
	case len(segs) == 2 && segs[0] == "mempool" && segs[1] == "txids":
		return ea_mempool_txids(ctx, allocator)
	case len(segs) == 1 && segs[0] == "fee-estimates":
		return ea_fee_estimates(ctx, allocator)
	}
	return ea_text(404, "not found", allocator)
}

// ---------------------------------------------------------------------------
// Small response helpers.

@(private = "file")
ea_text :: proc(status: int, s: string, allocator: runtime_Allocator) -> (int, string, string) {
	out, _ := clone_string(s, allocator)
	return status, "text/plain", out
}

@(private = "file")
ea_json :: proc(b: ^strings.Builder, allocator: runtime_Allocator) -> (int, string, string) {
	out, _ := clone_string(strings.to_string(b^), allocator)
	return 200, "application/json", out
}

@(private = "file")
runtime_Allocator :: runtime.Allocator

// ---------------------------------------------------------------------------
// Transactions.

@(private = "file")
Ea_Tx :: struct {
	raw:       []byte,
	height:    u32, // valid when confirmed
	confirmed: bool,
}

// ea_tx_load finds a transaction in the chain or, failing that, in the
// mempool.
@(private = "file")
ea_tx_load :: proc(
	ctx: ^Electrum_Ctx,
	txid: [32]u8,
	scratch: ^[dynamic]byte = nil,
) -> (
	t: Ea_Tx,
	found: bool,
	err: Error,
) {
	raw, height, cfound, terr := query_tx(ctx.idx, txid, scratch)
	if terr != nil {
		return {}, false, terr
	}
	if cfound {
		return Ea_Tx{raw = raw, height = height, confirmed = true}, true, nil
	}
	if ctx.mp != nil {
		if mtx, mok := ctx.mp.txs[txid]; mok {
			return Ea_Tx{raw = mtx.raw}, true, nil
		}
	}
	return {}, false, nil
}

// ea_prevout resolves the scriptPubKey and value an input spends,
// checking the mempool first (unconfirmed parents), then the chain.
// The returned script borrows temp memory.
@(private = "file")
ea_prevout :: proc(
	ctx: ^Electrum_Ctx,
	prev_txid: [32]u8,
	vout: u32,
	scratch: ^[dynamic]byte, // shared across a tx's inputs: one buffer, not one per input
) -> (
	spk: []byte,
	value: u64,
	ok: bool,
) {
	raw: []byte
	if ctx.mp != nil {
		if mtx, mok := ctx.mp.txs[prev_txid]; mok {
			raw = mtx.raw
		}
	}
	if raw == nil {
		craw, _, cfound, terr := query_tx(ctx.idx, prev_txid, scratch)
		if terr != nil || !cfound {
			return nil, 0, false
		}
		raw = craw
	}
	tx, consumed := tx_parse(raw, false)
	if consumed == 0 {
		return nil, 0, false
	}
	oit: Tx_Output_Iter
	tx_output_iter_init(&oit, &tx)
	for {
		o, v, ook := tx_output_iter_next(&oit)
		if !ook {break}
		if u32(v) == vout {
			return o.script, o.value, true
		}
	}
	return nil, 0, false
}

@(private = "file")
ea_tx_route :: proc(ctx: ^Electrum_Ctx, segs: []string, allocator: runtime_Allocator) -> (int, string, string) {
	txid, ok := txid_from_hex(segs[1])
	if !ok {
		return ea_text(400, "bad txid", allocator)
	}
	t, found, terr := ea_tx_load(ctx, txid)
	if terr != nil {
		return ea_text(500, fmt.tprintf("%v", terr), allocator)
	}
	if !found {
		return ea_text(404, "Transaction not found", allocator)
	}

	if len(segs) == 2 {
		b := strings.builder_make(context.temp_allocator)
		ea_tx_json(&b, ctx, t.raw, txid, t.height, t.confirmed)
		return ea_json(&b, allocator)
	}
	switch segs[2] {
	case "hex":
		b := strings.builder_make(context.temp_allocator)
		e_hex_pub(&b, t.raw)
		s := strings.to_string(b)
		out, _ := clone_string(s, allocator)
		return 200, "text/plain", out
	case "raw":
		out := make([]byte, len(t.raw), allocator)
		copy(out, t.raw)
		return 200, "application/octet-stream", string(out)
	case "status":
		b := strings.builder_make(context.temp_allocator)
		ea_status_json(&b, ctx, t.height, t.confirmed)
		return ea_json(&b, allocator)
	case "merkle-proof":
		height, pos, branch, mfound, merr := query_merkle(ctx.idx, txid, context.temp_allocator)
		if merr != nil || !mfound {
			return ea_text(404, "Transaction not found in any block", allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"block_height":%d,"merkle":[`, height)
		for node, i in branch {
			hb: [64]byte
			fmt.sbprintf(&b, `%s"%s"`, "," if i > 0 else "", txid_to_hex(node, hb[:]))
		}
		fmt.sbprintf(&b, `],"pos":%d}}`, pos)
		return ea_json(&b, allocator)
	case "outspends":
		tx, consumed := tx_parse(t.raw, false)
		if consumed == 0 {
			return ea_text(500, "bad tx", allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for v in 0 ..< tx.n_outputs {
			if v > 0 {strings.write_byte(&b, ',')}
			ea_outspend_json(&b, ctx, txid, u32(v))
		}
		strings.write_byte(&b, ']')
		return ea_json(&b, allocator)
	case "outspend":
		if len(segs) < 4 {
			return ea_text(400, "missing vout", allocator)
		}
		v, vok := strconv.parse_uint(segs[3], 10)
		if !vok {
			return ea_text(400, "bad vout", allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		ea_outspend_json(&b, ctx, txid, u32(v))
		return ea_json(&b, allocator)
	}
	return ea_text(404, "not found", allocator)
}

@(private = "file")
ea_outspend_json :: proc(b: ^strings.Builder, ctx: ^Electrum_Ctx, txid: [32]u8, vout: u32) {
	key: [SPENDS_KEY_LEN]byte
	txid := txid
	copy(key[0:32], txid[:])
	put_u32be(key[32:], vout)
	sv, sfound, serr := spends_lookup(ctx.idx, key)
	spender_in_mempool := false
	mp_spender: [32]u8
	if !sfound && serr == nil && ctx.mp != nil {
		mp_spender, spender_in_mempool = mempool_spender(ctx.mp, txid, vout)
	}
	if serr != nil || (!sfound && !spender_in_mempool) {
		strings.write_string(b, `{"spent":false}`)
		return
	}
	if spender_in_mempool {
		hb: [64]byte
		fmt.sbprintf(
			b,
			`{{"spent":true,"txid":"%s","vin":0,"status":{{"confirmed":false}}}}`,
			txid_to_hex(mp_spender, hb[:]),
		)
		return
	}
	spender, rerr := resolve_txid_at(ctx.idx, sv.height, sv.txnum)
	if rerr != nil {
		strings.write_string(b, `{"spent":true}`)
		return
	}
	hb: [64]byte
	fmt.sbprintf(b, `{{"spent":true,"txid":"%s","vin":%d,"status":`, txid_to_hex(spender, hb[:]), sv.vin)
	ea_status_json(b, ctx, sv.height, true)
	strings.write_byte(b, '}')
}

@(private = "file")
ea_status_json :: proc(b: ^strings.Builder, ctx: ^Electrum_Ctx, height: u32, confirmed: bool) {
	if !confirmed || int(height) >= len(ctx.idx.chain) {
		strings.write_string(b, `{"confirmed":false}`)
		return
	}
	hdr := &ctx.idx.chain[height]
	hb: [64]byte
	fmt.sbprintf(
		b,
		`{{"confirmed":true,"block_height":%d,"block_hash":"%s","block_time":%d}}`,
		height,
		txid_to_hex(hdr.hash, hb[:]),
		get_u32le(hdr.raw[68:72]),
	)
}

// ea_tx_json emits the full decoded transaction, prevouts resolved.
@(private = "file")
ea_tx_json :: proc(b: ^strings.Builder, ctx: ^Electrum_Ctx, raw: []byte, txid: [32]u8, height: u32, confirmed: bool) {
	tx, consumed := tx_parse(raw, false)
	if consumed == 0 {
		strings.write_string(b, "{}")
		return
	}
	hb: [64]byte
	fmt.sbprintf(
		b,
		`{{"txid":"%s","version":%d,"locktime":%d,"size":%d,"weight":%d,`,
		txid_to_hex(txid, hb[:]),
		get_u32le(raw[0:4]),
		get_u32le(raw[len(raw) - 4:]),
		len(raw),
		tx.weight,
	)

	is_cb := tx.is_coinbase
	in_sum, out_sum: u64
	have_all := true
	// One prevout buffer for every input of this transaction.
	pv_scratch := new([dynamic]byte, context.temp_allocator)
	pv_scratch^ = make([dynamic]byte, context.temp_allocator)

	strings.write_string(b, `"vin":[`)
	iit: Tx_Input_Iter
	tx_input_iter_init(&iit, &tx)
	first := true
	for {
		inp, vin, iok := tx_input_iter_next(&iit)
		if !iok {break}
		if !first {strings.write_byte(b, ',')}
		first = false
		fmt.sbprintf(
			b,
			`{{"txid":"%s","vout":%d,"is_coinbase":%v,"sequence":%d,"scriptsig":"`,
			txid_to_hex(inp.prev_txid, hb[:]),
			inp.vout,
			is_cb,
			inp.sequence,
		)
		e_hex_pub(b, inp.script)
		strings.write_string(b, `","scriptsig_asm":"`)
		ea_script_asm(b, inp.script)
		strings.write_byte(b, '"')
		ea_witness_json(b, &tx, vin)
		if !is_cb {
			if spk, value, pok := ea_prevout(ctx, inp.prev_txid, inp.vout, pv_scratch); pok {
				strings.write_string(b, `,"prevout":`)
				ea_spk_json(ctx, b, spk, value)
				in_sum += value
			} else {
				have_all = false
				strings.write_string(b, `,"prevout":null`)
			}
		} else {
			strings.write_string(b, `,"prevout":null`)
		}
		strings.write_byte(b, '}')
	}
	strings.write_string(b, `],"vout":[`)

	oit: Tx_Output_Iter
	tx_output_iter_init(&oit, &tx)
	firsto := true
	for {
		o, _, ook := tx_output_iter_next(&oit)
		if !ook {break}
		if !firsto {strings.write_byte(b, ',')}
		firsto = false
		ea_spk_json(ctx, b, o.script, o.value)
		out_sum += o.value
	}
	strings.write_string(b, `],`)

	fee: u64 = 0
	if !is_cb && have_all && in_sum >= out_sum {
		fee = in_sum - out_sum
	}
	fmt.sbprintf(b, `"fee":%d,"status":`, fee)
	ea_status_json(b, ctx, height, confirmed)
	strings.write_byte(b, '}')
}

// ea_witness_json emits the witness item array for one input, walking the
// raw witness section.
@(private = "file")
ea_witness_json :: proc(b: ^strings.Builder, tx: ^Tx, vin: int) {
	if !tx.segwit {return}
	strings.write_string(b, `,"witness":[`)
	defer strings.write_byte(b, ']')
	pos := tx.witness_off
	raw := tx.raw
	for i in 0 ..< tx.n_inputs {
		n_items, n0 := compact_size(raw[pos:])
		if n0 == 0 {return}
		pos += n0

		for j in 0 ..< int(n_items) {
			ilen, il := compact_size(raw[pos:])
			if il == 0 {return}
			pos += il
			if i == vin {
				if j > 0 {strings.write_byte(b, ',')}
				strings.write_byte(b, '"')
				e_hex_pub(b, raw[pos:pos + int(ilen)])
				strings.write_byte(b, '"')
			}
			pos += int(ilen)
		}
		if i == vin {
			return
		}
	}
}

// ea_spk_json: {scriptpubkey, asm, type, address?, value}.
@(private = "file")
ea_spk_json :: proc(ctx: ^Electrum_Ctx, b: ^strings.Builder, spk: []byte, value: u64) {
	strings.write_string(b, `{"scriptpubkey":"`)
	e_hex_pub(b, spk)
	strings.write_string(b, `","scriptpubkey_asm":"`)
	ea_script_asm(b, spk)
	strings.write_string(b, `","scriptpubkey_type":"`)
	strings.write_string(b, ea_script_type(spk))
	strings.write_byte(b, '"')
	if addr, aok := script_to_address(spk, ctx.idx.cfg.network, context.temp_allocator); aok {
		fmt.sbprintf(b, `,"scriptpubkey_address":"%s"`, addr)
	}
	fmt.sbprintf(b, `,"value":%d}}`, value)
}

@(private = "file")
ea_script_type :: proc(spk: []byte) -> string {
	#partial switch script_classify(spk) {
	case .P2PK:
		return "p2pk"
	case .P2PKH:
		return "p2pkh"
	case .P2SH:
		return "p2sh"
	case .P2WPKH:
		return "v0_p2wpkh"
	case .P2WSH:
		return "v0_p2wsh"
	case .P2TR:
		return "v1_p2tr"
	case .Op_Return:
		return "op_return"
	}
	return "unknown"
}

// ---------------------------------------------------------------------------
// Blocks.

@(private = "file")
ea_block_route :: proc(ctx: ^Electrum_Ctx, segs: []string, allocator: runtime_Allocator) -> (int, string, string) {
	height, hfound := ea_height_of_hash(ctx.idx, segs[1])
	if !hfound {
		return ea_text(404, "Block not found", allocator)
	}
	hdr := &ctx.idx.chain[height]

	if len(segs) == 2 {
		b := strings.builder_make(context.temp_allocator)
		ea_block_json(&b, ctx, height)
		return ea_json(&b, allocator)
	}
	switch segs[2] {
	case "status":
		tip := index_tip_height(ctx.idx)
		b := strings.builder_make(context.temp_allocator)
		if int(height) < len(ctx.idx.chain) {
			nb: [64]byte
			next := ""
			if int(height) < tip {
				next = fmt.tprintf(`,"next_best":"%s"`, txid_to_hex(ctx.idx.chain[height + 1].hash, nb[:]))
			}
			fmt.sbprintf(&b, `{{"in_best_chain":true,"height":%d%s}}`, height, next)
		} else {
			strings.write_string(&b, `{"in_best_chain":false}`)
		}
		return ea_json(&b, allocator)
	case "header":
		b := strings.builder_make(context.temp_allocator)
		e_hex_pub(&b, hdr.raw[:])
		s := strings.to_string(b)
		out, _ := clone_string(s, allocator)
		return 200, "text/plain", out
	case "txids":
		ids, err := ea_block_txids(ctx, height)
		if err != nil {
			return ea_text(500, fmt.tprintf("%v", err), allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for id, i in ids {
			hb: [64]byte
			fmt.sbprintf(&b, `%s"%s"`, "," if i > 0 else "", txid_to_hex(id, hb[:]))
		}
		strings.write_byte(&b, ']')
		return ea_json(&b, allocator)
	case "txs":
		start := 0
		if len(segs) >= 4 {
			s, sok := strconv.parse_int(segs[3], 10)
			if !sok || s < 0 || s % ESPLORA_PAGE_TXS != 0 {
				return ea_text(400, "start index must be a multiple of 25", allocator)
			}
			start = s
		}
		ids, err := ea_block_txids(ctx, height)
		if err != nil {
			return ea_text(500, fmt.tprintf("%v", err), allocator)
		}
		if start >= len(ids) && start != 0 {
			return ea_text(404, "start index out of range", allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		end := min(start + ESPLORA_PAGE_TXS, len(ids))
		page_scratch := new([dynamic]byte, context.temp_allocator)
		page_scratch^ = make([dynamic]byte, context.temp_allocator)
		for i in start ..< end {
			if i > start {strings.write_byte(&b, ',')}
			t, tfound, terr := ea_tx_load(ctx, ids[i], page_scratch)
			if terr != nil || !tfound {
				strings.write_string(&b, "null")
				continue
			}
			ea_tx_json(&b, ctx, t.raw, ids[i], t.height, t.confirmed)
		}
		strings.write_byte(&b, ']')
		return ea_json(&b, allocator)
	}
	return ea_text(404, "not found", allocator)
}

@(private = "file")
ea_blocks :: proc(ctx: ^Electrum_Ctx, start: int, allocator: runtime_Allocator) -> (int, string, string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	h := min(start, index_tip_height(ctx.idx))
	for h >= 0 && start - h < ESPLORA_PAGE_BLOCKS {
		if !first {strings.write_byte(&b, ',')}
		first = false
		ea_block_json(&b, ctx, u32(h))
		h -= 1
	}
	strings.write_byte(&b, ']')
	return ea_json(&b, allocator)
}

@(private = "file")
ea_block_json :: proc(b: ^strings.Builder, ctx: ^Electrum_Ctx, height: u32) {
	hdr := &ctx.idx.chain[height]
	hb, pb, mb: [64]byte
	prev: [32]u8
	copy(prev[:], hdr.raw[4:36])
	mroot: [32]u8
	copy(mroot[:], hdr.raw[36:68])
	fmt.sbprintf(
		b,
		`{{"id":"%s","height":%d,"version":%d,"timestamp":%d,"tx_count":%d,"size":%d,"merkle_root":"%s","previousblockhash":"%s","nonce":%d,"bits":%d}}`,
		txid_to_hex(hdr.hash, hb[:]),
		height,
		get_u32le(hdr.raw[0:4]),
		get_u32le(hdr.raw[68:72]),
		hdr.tx_count,
		hdr.length,
		txid_to_hex(mroot, mb[:]),
		txid_to_hex(prev, pb[:]),
		get_u32le(hdr.raw[76:80]),
		get_u32le(hdr.raw[72:76]),
	)
}

// ea_block_txids reads the block and collects every txid (cached walks).
@(private = "file")
ea_block_txids :: proc(ctx: ^Electrum_Ctx, height: u32) -> (ids: [][32]u8, err: Error) {
	idx := ctx.idx
	hdr := &idx.chain[height]
	fi, fok := idx.file_index[hdr.file_no]
	if !fok {
		return nil, Corruption.Truncated
	}
	f := &idx.files[fi]
	index_map_file(idx, f) or_return
	deobf := make([dynamic]byte, context.temp_allocator)
	block := blk_payload_bytes(f, hdr.offset, hdr.length, &deobf) or_return
	out := make([dynamic][32]u8, 0, hdr.tx_count, context.temp_allocator)
	it: Tx_Iter
	tx_iter_init(&it, block) or_return
	for {
		tx, ok := tx_iter_next(&it)
		if !ok {break}
		append(&out, tx.txid)
	}
	if it.err != nil {
		return nil, it.err
	}
	return out[:], nil
}

// ea_height_of_hash: linear-scan fallback with a lazily built map per
// index generation (built once under lock, ~35MB, worker-safe).
@(private = "file")
ea_height_of_hash :: proc(idx: ^Index, hash_hex: string) -> (height: u32, found: bool) {
	h, ok := txid_from_hex(hash_hex)
	if !ok {
		return 0, false
	}
	sync.mutex_lock(&idx.hash_index_mu)
	if idx.hash_index == nil {
		idx.hash_index = make(map[[32]u8]u32, len(idx.chain), idx.allocator)
		for &sh, i in idx.chain {
			idx.hash_index[sh.hash] = u32(i)
		}
	}
	hh, hfound := idx.hash_index[h]
	sync.mutex_unlock(&idx.hash_index_mu)
	return hh, hfound
}

// ---------------------------------------------------------------------------
// Addresses / scripthashes.

@(private = "file")
ea_addr_route :: proc(
	ctx: ^Electrum_Ctx,
	sh: [32]u8,
	addr_str: string,
	segs: []string,
	allocator: runtime_Allocator,
) -> (
	int,
	string,
	string,
) {
	if len(segs) == 2 {
		return ea_addr_summary(ctx, sh, addr_str, allocator)
	}
	switch segs[2] {
	case "utxo":
		return ea_addr_utxo(ctx, sh, allocator)
	case "txs":
		mode := ""
		last_seen := ""
		if len(segs) >= 4 {mode = segs[3]}
		if len(segs) >= 5 {last_seen = segs[4]}
		return ea_addr_txs(ctx, sh, mode, last_seen, allocator)
	}
	return ea_text(404, "not found", allocator)
}

@(private = "file")
ea_addr_summary :: proc(ctx: ^Electrum_Ctx, sh: [32]u8, addr_str: string, allocator: runtime_Allocator) -> (int, string, string) {
	if gcode, gmsg := ea_guard(ctx, sh); gcode != 0 {
		return ea_text(gcode, gmsg, allocator)
	}
	entries, herr := query_history_resolved(ctx.idx, sh, 0, -1, context.temp_allocator)
	if herr != nil {
		return ea_text(500, fmt.tprintf("%v", herr), allocator)
	}
	fc, sc, txn: int
	fs, ss: u64
	last_txnum := u32(0xFFFFFFFF)
	last_height := u32(0xFFFFFFFF)
	for &r in entries {
		if r.entry.direction == DIRECTION_FUNDING {
			fc += 1
			fs += r.entry.amount
		} else {
			sc += 1
			ss += r.entry.amount
		}
		if r.entry.height != last_height || r.entry.txnum != last_txnum {
			txn += 1
			last_height = r.entry.height
			last_txnum = r.entry.txnum
		}
	}
	mfc, msc, mtxn: int
	mfs, mss: u64
	if ctx.mp != nil {
		seen := make(map[[32]u8]struct {}, context.temp_allocator)
		for e in mempool_entries(ctx.mp, sh) {
			if e.direction == DIRECTION_FUNDING {
				mfc += 1
				mfs += e.amount
			} else {
				msc += 1
				mss += e.amount
			}
			if e.txid not_in seen {
				seen[e.txid] = {}
				mtxn += 1
			}
		}
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	hb: [64]byte
	if addr_str != "" {
		fmt.sbprintf(&b, `"address":"%s",`, addr_str)
	} else {
		sh := sh
		fwd := strings.builder_make(context.temp_allocator)
		e_hex_pub(&fwd, sh[:])
		fmt.sbprintf(&b, `"scripthash":"%s",`, strings.to_string(fwd))
	}
	fmt.sbprintf(
		&b,
		`"chain_stats":{{"funded_txo_count":%d,"funded_txo_sum":%d,"spent_txo_count":%d,"spent_txo_sum":%d,"tx_count":%d}},`,
		fc,
		fs,
		sc,
		ss,
		txn,
	)
	fmt.sbprintf(
		&b,
		`"mempool_stats":{{"funded_txo_count":%d,"funded_txo_sum":%d,"spent_txo_count":%d,"spent_txo_sum":%d,"tx_count":%d}}}}`,
		mfc,
		mfs,
		msc,
		mss,
		mtxn,
	)
	return ea_json(&b, allocator)
}

@(private = "file")
ea_addr_utxo :: proc(ctx: ^Electrum_Ctx, sh: [32]u8, allocator: runtime_Allocator) -> (int, string, string) {
	if gcode, gmsg := ea_guard(ctx, sh); gcode != 0 {
		return ea_text(gcode, gmsg, allocator)
	}
	utxos, uerr := query_utxos(ctx.idx, sh, context.temp_allocator)
	if uerr != nil {
		return ea_text(500, fmt.tprintf("%v", uerr), allocator)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	hb: [64]byte
	for &u in utxos {
		if ctx.mp != nil {
			if _, spending := mempool_spender(ctx.mp, u.txid, u.vout); spending {
				continue
			}
		}
		if !first {strings.write_byte(&b, ',')}
		first = false
		fmt.sbprintf(&b, `{{"txid":"%s","vout":%d,"status":`, txid_to_hex(u.txid, hb[:]), u.vout)
		ea_status_json(&b, ctx, u.height, true)
		fmt.sbprintf(&b, `,"value":%d}}`, u.amount)
	}
	if ctx.mp != nil {
		for e in mempool_entries(ctx.mp, sh) {
			if e.direction != DIRECTION_FUNDING {continue}
			if _, spending := mempool_spender(ctx.mp, e.txid, e.io_index); spending {continue}
			if !first {strings.write_byte(&b, ',')}
			first = false
			fmt.sbprintf(
				&b,
				`{{"txid":"%s","vout":%d,"status":{{"confirmed":false}},"value":%d}}`,
				txid_to_hex(e.txid, hb[:]),
				e.io_index,
				e.amount,
			)
		}
	}
	strings.write_byte(&b, ']')
	return ea_json(&b, allocator)
}

// ea_addr_txs serves /txs (mempool then newest chain page), /txs/mempool,
// and /txs/chain[/:last_seen_txid] with cursor pagination.
@(private = "file")
ea_addr_txs :: proc(
	ctx: ^Electrum_Ctx,
	sh: [32]u8,
	mode: string,
	last_seen: string,
	allocator: runtime_Allocator,
) -> (
	int,
	string,
	string,
) {
	// No history guard here. The page is bounded now: this walks rows (cheap)
	// and resolves txids only for the <=25 transactions it emits, so a busy
	// address costs a page, not its whole history. The summary and utxo
	// endpoints keep the guard — both still resolve every entry.
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true

	emit_mempool := mode == "" || mode == "mempool"
	emit_chain := mode == "" || mode == "chain"

	if emit_mempool && ctx.mp != nil {
		seen := make(map[[32]u8]struct {}, context.temp_allocator)
		for e in mempool_entries(ctx.mp, sh) {
			if e.txid in seen {continue}
			seen[e.txid] = {}
			if mtx, mok := ctx.mp.txs[e.txid]; mok {
				if !first {strings.write_byte(&b, ',')}
				first = false
				ea_tx_json(&b, ctx, mtx.raw, e.txid, 0, false)
			}
		}
	}

	if emit_chain {
		// Walk history ROWS only. Resolving a txid means reading — and on a
		// Core v28+ datadir de-obfuscating ~2MB of — the block it lives in,
		// so resolving the whole history to emit 25 transactions made EVERY
		// page cost what the deepest one costs: thousands of block reads to
		// return 25 entries. Rows are ~53 bytes in sorted blocks; walking
		// them is nothing by comparison.
		entries, herr := query_history(ctx.idx, sh, 0, -1, context.temp_allocator)
		if herr != nil {
			return ea_text(500, fmt.tprintf("%v", herr), allocator)
		}

		// Distinct transactions keyed by (height, txnum) — the same grouping
		// the txid gives, without needing the txid. Rows arrive sorted by
		// height then txnum, so duplicates are adjacent.
		Tx_Loc :: struct {
			height: u32,
			txnum:  u32,
		}
		uniq := make([dynamic]Tx_Loc, 0, 64, context.temp_allocator)
		for &e in entries {
			n := len(uniq)
			if n > 0 && uniq[n - 1].height == e.height && uniq[n - 1].txnum == e.txnum {
				continue
			}
			append(&uniq, Tx_Loc{e.height, e.txnum})
		}

		// newest first
		start := len(uniq) - 1
		if last_seen != "" {
			if cursor, cok := txid_from_hex(last_seen); cok {
				// One txloc lookup places the cursor instead of resolving
				// every txid until one matches. Txloc_Value carries height
				// but not txnum, so when an address appears in several
				// transactions in the SAME block the height alone is
				// ambiguous — resolve just those few to disambiguate.
				if loc, lfound, lerr := txloc_lookup(ctx.idx, cursor); lerr == nil && lfound {
					for i := len(uniq) - 1; i >= 0; i -= 1 {
						if uniq[i].height != loc.height {
							continue
						}
						same_height := 0
						for j := i; j >= 0 && uniq[j].height == loc.height; j -= 1 {
							same_height += 1
						}
						if same_height == 1 {
							start = i - 1
							break
						}
						matched := false
						for j := i; j >= 0 && uniq[j].height == loc.height; j -= 1 {
							if id, rerr := resolve_txid_at(ctx.idx, uniq[j].height, uniq[j].txnum);
							   rerr == nil && id == cursor {
								start = j - 1
								matched = true
								break
							}
						}
						if matched {
							break
						}
						// Cursor names a height in this history but no
						// transaction in it: treat as not found and serve
						// from the newest rather than silently skipping.
						break
					}
				}
			}
		}
		emitted := 0
		page_scratch := new([dynamic]byte, context.temp_allocator)
		page_scratch^ = make([dynamic]byte, context.temp_allocator)
		for i := start; i >= 0 && emitted < ESPLORA_PAGE_TXS; i -= 1 {
			txid, rerr := resolve_txid_at(ctx.idx, uniq[i].height, uniq[i].txnum)
			if rerr != nil {
				continue
			}
			t, tfound, terr := ea_tx_load(ctx, txid, page_scratch)
			if terr != nil || !tfound {continue}
			if !first {strings.write_byte(&b, ',')}
			first = false
			ea_tx_json(&b, ctx, t.raw, txid, t.height, t.confirmed)
			emitted += 1
		}
	}
	strings.write_byte(&b, ']')
	return ea_json(&b, allocator)
}

// ea_guard mirrors the Electrum history guard: on compact indexes (where
// history enumeration reads the chain) refuse oversized addresses; exact
// indexes enumerate from rows and stay uncapped.
@(private = "file")
ea_guard :: proc(ctx: ^Electrum_Ctx, sh: [32]u8) -> (status: int, msg: string) {
	if ctx.max_history <= 0 {
		return 0, ""
	}
	n, herr := query_history_count(ctx.idx, sh)
	if herr != nil {
		return 500, fmt.tprintf("%v", herr)
	}
	if n > ctx.max_history {
		return 400, fmt.tprintf(
			// The old wording suggested switching to an exact index, which
			// is no help to someone already running one — the summary walks
			// the whole history in either mode.
			"address history too large for this server (%d entries, limit %d); raise electrum_max_history to serve it",
			n,
			ctx.max_history,
		)
	}
	return 0, ""
}

// ---------------------------------------------------------------------------
// Mempool + fees + broadcast.

@(private = "file")
ea_mempool_info :: proc(ctx: ^Electrum_Ctx, allocator: runtime_Allocator) -> (int, string, string) {
	b := strings.builder_make(context.temp_allocator)
	if ctx.mp == nil {
		strings.write_string(&b, `{"count":0,"vsize":0,"total_fee":0,"fee_histogram":[]}`)
		return ea_json(&b, allocator)
	}
	count := len(ctx.mp.txs)
	vsize: u64
	total_fee: u64
	for _, mtx in ctx.mp.txs {
		vsize += u64(mtx.vsize)
		total_fee += mtx.fee
	}
	fmt.sbprintf(&b, `{{"count":%d,"vsize":%d,"total_fee":%d,"fee_histogram":[`, count, vsize, total_fee)
	bins := mempool_fee_histogram(ctx.mp, context.temp_allocator)
	for bin, i in bins {
		fmt.sbprintf(&b, "%s[%.2f,%d]", "," if i > 0 else "", bin.rate, bin.vsize)
	}
	strings.write_string(&b, "]}")
	return ea_json(&b, allocator)
}

@(private = "file")
ea_mempool_txids :: proc(ctx: ^Electrum_Ctx, allocator: runtime_Allocator) -> (int, string, string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	if ctx.mp != nil {
		first := true
		hb: [64]byte
		for txid in ctx.mp.txs {
			if !first {strings.write_byte(&b, ',')}
			first = false
			fmt.sbprintf(&b, `"%s"`, txid_to_hex(txid, hb[:]))
		}
	}
	strings.write_byte(&b, ']')
	return ea_json(&b, allocator)
}

@(private = "file")
ea_fee_estimates :: proc(ctx: ^Electrum_Ctx, allocator: runtime_Allocator) -> (int, string, string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	if ctx.rc != nil {
		TARGETS := [?]int{1, 2, 3, 4, 5, 6, 10, 20, 144, 504, 1008}
		first := true
		for tgt in TARGETS {
			e_mp_suspend(ctx)
			envelope, rerr := rpc_call(ctx.rc, "estimatesmartfee", fmt.tprintf("[%d]", tgt), context.temp_allocator)
			e_mp_resume(ctx)
			if rerr != nil {continue}
			env, eok := envelope.(json_Object)
			if !eok {continue}
			res, ook := env["result"].(json_Object)
			if !ook {continue}
			rate, fok := res["feerate"].(json_Float)
			if !fok {continue}
			if !first {strings.write_byte(&b, ',')}
			first = false
			// BTC/kvB -> sat/vB
			fmt.sbprintf(&b, `"%d":%.3f`, tgt, f64(rate) * 100_000.0)
		}
	}
	strings.write_byte(&b, '}')
	return ea_json(&b, allocator)
}

@(private = "file")
ea_broadcast :: proc(ctx: ^Electrum_Ctx, body: string, allocator: runtime_Allocator) -> (int, string, string) {
	raw := strings.trim_space(body)
	if !e_is_hex_pub(raw) {
		return ea_text(400, "invalid raw transaction hex", allocator)
	}
	if ctx.rc == nil {
		return ea_text(500, "bitcoind RPC is not configured", allocator)
	}
	e_mp_suspend(ctx)
	envelope, rerr := rpc_call(
		ctx.rc,
		"sendrawtransaction",
		fmt.tprintf(`["%s"]`, raw),
		context.temp_allocator,
		intercept_errors = false,
	)
	e_mp_resume(ctx)
	if rerr != nil {
		return ea_text(500, fmt.tprintf("broadcast failed: %v", rerr), allocator)
	}
	env, eok := envelope.(json_Object)
	if !eok {
		return ea_text(500, "malformed bitcoind response", allocator)
	}
	if errv, has := env["error"]; has {
		if errobj, ook := errv.(json_Object); ook {
			if msg, mok := errobj["message"].(json_String); mok {
				return ea_text(400, string(msg), allocator)
			}
		}
	}
	if txid, tok := env["result"].(json_String); tok {
		return ea_text(200, string(txid), allocator)
	}
	return ea_text(500, "malformed bitcoind response", allocator)
}

// ---------------------------------------------------------------------------
// Script asm rendering, esplora style: "OP_DUP OP_HASH160 OP_PUSHBYTES_20
// <hex> OP_EQUALVERIFY OP_CHECKSIG".

@(private = "file")
ea_script_asm :: proc(b: ^strings.Builder, script: []byte) {
	i := 0
	first := true
	for i < len(script) {
		if !first {strings.write_byte(b, ' ')}
		first = false
		op := script[i]
		i += 1
		switch {
		case op >= 1 && op <= 75:
			n := int(op)
			if i + n > len(script) {
				strings.write_string(b, "OP_INVALID")
				return
			}
			fmt.sbprintf(b, "OP_PUSHBYTES_%d ", n)
			e_hex_pub(b, script[i:i + n])
			i += n
		case op == 0x4C || op == 0x4D || op == 0x4E:
			nlen := 1 if op == 0x4C else 2 if op == 0x4D else 4
			if i + nlen > len(script) {
				strings.write_string(b, "OP_INVALID")
				return
			}
			n := 0
			for k in 0 ..< nlen {
				n |= int(script[i + k]) << uint(8 * k)
			}
			i += nlen
			if i + n > len(script) || n < 0 {
				strings.write_string(b, "OP_INVALID")
				return
			}
			fmt.sbprintf(b, "OP_PUSHDATA%d %d ", nlen, n)
			e_hex_pub(b, script[i:i + n])
			i += n
		case:
			strings.write_string(b, ea_opcode_name(op))
		}
	}
}

@(private = "file")
ea_opcode_name :: proc(op: byte) -> string {
	switch op {
	case 0x00:
		return "OP_0"
	case 0x4F:
		return "OP_PUSHNUM_NEG1"
	case 0x51 ..= 0x60:
		@(static, rodata)
		NUMS := [?]string {
			"OP_PUSHNUM_1", "OP_PUSHNUM_2", "OP_PUSHNUM_3", "OP_PUSHNUM_4",
			"OP_PUSHNUM_5", "OP_PUSHNUM_6", "OP_PUSHNUM_7", "OP_PUSHNUM_8",
			"OP_PUSHNUM_9", "OP_PUSHNUM_10", "OP_PUSHNUM_11", "OP_PUSHNUM_12",
			"OP_PUSHNUM_13", "OP_PUSHNUM_14", "OP_PUSHNUM_15", "OP_PUSHNUM_16",
		}
		return NUMS[op - 0x51]
	case 0x61:
		return "OP_NOP"
	case 0x63:
		return "OP_IF"
	case 0x64:
		return "OP_NOTIF"
	case 0x67:
		return "OP_ELSE"
	case 0x68:
		return "OP_ENDIF"
	case 0x69:
		return "OP_VERIFY"
	case 0x6A:
		return "OP_RETURN"
	case 0x76:
		return "OP_DUP"
	case 0x7C:
		return "OP_SWAP"
	case 0x82:
		return "OP_SIZE"
	case 0x87:
		return "OP_EQUAL"
	case 0x88:
		return "OP_EQUALVERIFY"
	case 0x93:
		return "OP_ADD"
	case 0xA6:
		return "OP_RIPEMD160"
	case 0xA8:
		return "OP_SHA256"
	case 0xA9:
		return "OP_HASH160"
	case 0xAA:
		return "OP_HASH256"
	case 0xAC:
		return "OP_CHECKSIG"
	case 0xAD:
		return "OP_CHECKSIGVERIFY"
	case 0xAE:
		return "OP_CHECKMULTISIG"
	case 0xAF:
		return "OP_CHECKMULTISIGVERIFY"
	case 0xB1:
		return "OP_CLTV"
	case 0xB2:
		return "OP_CSV"
	case 0xBA:
		return "OP_CHECKSIGADD"
	}
	return "OP_UNKNOWN"
}
