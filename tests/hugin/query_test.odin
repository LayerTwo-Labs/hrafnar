package hugin_tests

// Query layer and address decoding tests.

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"

import hugin "../../hugin"

// --- address decoding -------------------------------------------------------

// Local base58check encoder, independent of the library's decoder.
@(private = "file")
b58check_encode :: proc(payload: []byte, buf: []byte) -> string {
	ALPHABET := "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
	check := hugin.sha256d(payload)
	full := make([]byte, len(payload) + 4, context.temp_allocator)
	copy(full, payload)
	copy(full[len(payload):], check[:4])

	// Count leading zeros.
	zeros := 0
	for b in full {
		if b != 0 {break}
		zeros += 1
	}
	// Big-number to base58, least significant digit first.
	digits := make([dynamic]byte, context.temp_allocator)
	num := make([]byte, len(full), context.temp_allocator)
	copy(num, full)
	start := zeros
	for start < len(num) {
		rem := 0
		for i in start ..< len(num) {
			acc := rem << 8 | int(num[i])
			num[i] = byte(acc / 58)
			rem = acc % 58
		}
		append(&digits, ALPHABET[rem])
		for start < len(num) && num[start] == 0 {start += 1}
	}
	n := 0
	for _ in 0 ..< zeros {
		buf[n] = '1'
		n += 1
	}
	for i := len(digits) - 1; i >= 0; i -= 1 {
		buf[n] = digits[i]
		n += 1
	}
	return string(buf[:n])
}

@(test)
test_address_p2pkh_known :: proc(t: ^testing.T) {
	// The genesis address, hash160 well established.
	sh, err := hugin.address_to_scripthash("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", .Mainnet)
	testing.expect_value(t, err, nil)

	want_h160 := [20]u8 {
		0x62, 0xe9, 0x07, 0xb1, 0x5c, 0xbf, 0x27, 0xd5, 0x42, 0x53,
		0x99, 0xeb, 0xf6, 0xf0, 0xfb, 0x50, 0xeb, 0xb8, 0x8f, 0x18,
	}
	script: [25]byte
	script[0] = hugin.OP_DUP
	script[1] = hugin.OP_HASH160
	script[2] = 20
	copy(script[3:23], want_h160[:])
	script[23] = hugin.OP_EQUALVERIFY
	script[24] = hugin.OP_CHECKSIG
	testing.expect_value(t, sh, hugin.scripthash(script[:]))
}

@(test)
test_address_bech32_known :: proc(t: ^testing.T) {
	// BIP-173 example: P2WPKH for the all-test pubkey hash.
	sh, err := hugin.address_to_scripthash("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", .Mainnet)
	testing.expect_value(t, err, nil)

	prog := [20]u8 {
		0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4, 0x54, 0x94,
		0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23, 0xf1, 0x43, 0x3b, 0xd6,
	}
	script: [22]byte
	script[0] = hugin.OP_0
	script[1] = 20
	copy(script[2:], prog[:])
	testing.expect_value(t, sh, hugin.scripthash(script[:]))

	// Uppercase form is valid bech32; mixed case is not.
	_, uerr := hugin.address_to_scripthash("BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4", .Mainnet)
	testing.expect_value(t, uerr, nil)
	_, merr := hugin.address_to_scripthash("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kV8F3T4", .Mainnet)
	testing.expect_value(t, merr, hugin.Error(hugin.Usage_Error.Bad_Address))
}

@(test)
test_address_base58_round_trip :: proc(t: ^testing.T) {
	// P2PKH and P2SH payloads through the local encoder and library decoder.
	for version in ([]byte{0x00, 0x05}) {
		payload: [21]byte
		payload[0] = version
		for i in 1 ..< 21 {payload[i] = byte(i * 11)}
		abuf: [64]byte
		addr := b58check_encode(payload[:], abuf[:])

		sbuf: [34]byte
		script, serr := hugin.address_to_script(addr, .Mainnet, sbuf[:])
		testing.expect_value(t, serr, nil)
		testing.expect(t, script != nil, "must decode as address")
		if version == 0x00 {
			testing.expect_value(t, hugin.script_classify(script), hugin.Script_Class.P2PKH)
			testing.expect(t, bytes.compare(script[3:23], payload[1:21]) == 0)
		} else {
			testing.expect_value(t, hugin.script_classify(script), hugin.Script_Class.P2SH)
			testing.expect(t, bytes.compare(script[2:22], payload[1:21]) == 0)
		}
	}

	// A corrupted checksum must fail.
	payload: [21]byte
	abuf: [64]byte
	addr := b58check_encode(payload[:], abuf[:])
	bad := fmt.tprintf("%s%s", addr[:len(addr) - 1], "2" if addr[len(addr) - 1] == '3' else "3")
	sbuf: [34]byte
	script, _ := hugin.address_to_script(bad, .Mainnet, sbuf[:])
	testing.expect(t, script == nil, "bad checksum must not decode")
}

@(test)
test_address_raw_scripthash :: proc(t: ^testing.T) {
	sh, err := hugin.address_to_scripthash(
		"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
		.Mainnet,
	)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, sh[0], u8(0x00))
	testing.expect_value(t, sh[1], u8(0x11))
	testing.expect_value(t, sh[31], u8(0xff))

	_, gerr := hugin.address_to_scripthash("garbage", .Mainnet)
	testing.expect_value(t, gerr, hugin.Error(hugin.Usage_Error.Bad_Address))
}

@(test)
test_txid_hex :: proc(t: ^testing.T) {
	internal, ok := hugin.txid_from_hex(
		"4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b",
	)
	testing.expect(t, ok)
	// Display hex is byte-reversed relative to internal order.
	testing.expect_value(t, internal[0], u8(0x3b))
	testing.expect_value(t, internal[31], u8(0x4a))

	buf: [64]byte
	testing.expect_value(
		t,
		hugin.txid_to_hex(internal, buf[:]),
		"4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b",
	)
}

// --- query layer over a built index ----------------------------------------

@(test)
test_query_layer :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_query_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	datadir := fmt.aprintf("%s/blocks", dir)
	index_dir := fmt.aprintf("%s/index", dir)
	defer {delete(datadir); delete(index_dir)}
	testing.expect_value(t, os.make_directory_all(datadir), nil)

	sbufA, sbufB: [22]byte
	script_a := bb_script(0x11, sbufA[:])
	script_b := bb_script(0x22, sbufB[:])
	sh_a := hugin.scripthash(script_a)
	sh_b := hugin.scripthash(script_b)

	COIN :: u64(100_000_000)
	blocks := make([dynamic][]byte)
	tx_raws := make([dynamic][]byte)
	defer {
		for b in blocks {delete(b)}
		delete(blocks)
		for r in tx_raws {delete(r)}
		delete(tx_raws)
	}

	// height 0: coinbase -> A 50
	cb0, cb0_id := bb_tx(nil, {{50 * COIN, script_a}}, 1)
	append(&tx_raws, cb0)
	blk0, h0 := bb_block({}, {cb0}, 1)
	append(&blocks, blk0)

	// height 1: coinbase -> B 50; spend A -> B 49
	cb1, _ := bb_tx(nil, {{50 * COIN, script_b}}, 2)
	append(&tx_raws, cb1)
	tx1, tx1_id := bb_tx({{prev = {cb0_id, 0}}}, {{49 * COIN, script_b}})
	append(&tx_raws, tx1)
	blk1, _ := bb_block(h0, {cb1, tx1}, 2)
	append(&blocks, blk1)

	bb_write_blkfiles(t, datadir, blocks[:], 10)

	cfg := hugin.Config {
		datadir     = datadir,
		index_dir   = index_dir,
		network     = .Mainnet,
		bucket_bits = 4,
		workers     = 2,
	}
	// Bulk build covers up to tip - horizon; catch-up puts the rest in the
	// recent tier. With the default horizon that means height 0 in Munin
	// and height 1 in the tier, so these queries exercise the merge.
	testing.expect_value(t, hugin.build_index(cfg), nil)
	testing.expect_value(t, hugin.catchup_run(cfg), nil)

	idx, oerr := hugin.index_open(cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	testing.expect_value(t, hugin.index_tip_height(idx), 1)

	// Balances.
	bal_a, berr := hugin.query_balance(idx, sh_a)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, bal_a, 0)
	bal_b, berr2 := hugin.query_balance(idx, sh_b)
	testing.expect_value(t, berr2, nil)
	testing.expect_value(t, bal_b, i64(99 * COIN))

	// History for A: funding at 0, spend at 1 — chronological.
	hist, herr := hugin.query_history(idx, sh_a)
	testing.expect_value(t, herr, nil)
	defer delete(hist)
	testing.expect_value(t, len(hist), 2)
	if len(hist) == 2 {
		testing.expect_value(t, hist[0].height, u32(0))
		testing.expect_value(t, hist[0].direction, hugin.DIRECTION_FUNDING)
		testing.expect_value(t, hist[1].height, u32(1))
		testing.expect_value(t, hist[1].direction, hugin.DIRECTION_SPEND)
	}

	// from_height / limit.
	hist2, herr2 := hugin.query_history(idx, sh_a, 1)
	testing.expect_value(t, herr2, nil)
	defer delete(hist2)
	testing.expect_value(t, len(hist2), 1)
	hist3, herr3 := hugin.query_history(idx, sh_b, 0, 1)
	testing.expect_value(t, herr3, nil)
	defer delete(hist3)
	testing.expect_value(t, len(hist3), 1)

	// Tx retrieval: bytes straight from the mmap must hash to the txid.
	raw, height, found, terr := hugin.query_tx(idx, tx1_id)
	testing.expect_value(t, terr, nil)
	testing.expect(t, found)
	testing.expect_value(t, height, u32(1))
	testing.expect_value(t, hugin.sha256d(raw), tx1_id)

	// Missing tx.
	fake: [32]u8
	fake[5] = 0xEE
	_, _, tfound, _ := hugin.query_tx(idx, fake)
	testing.expect(t, !tfound)

	// Outpoint: A's coinbase output was spent by tx1 at height 1 vin 0.
	spend, sfound, serr := hugin.query_outpoint(idx, cb0_id, 0)
	testing.expect_value(t, serr, nil)
	testing.expect(t, sfound)
	testing.expect_value(t, spend.height, u32(1))
	testing.expect_value(t, spend.vin, u32(0))
	testing.expect_value(t, spend.spender_txid, tx1_id)

	// tx1's output is unspent.
	_, ufound, _ := hugin.query_outpoint(idx, tx1_id, 0)
	testing.expect(t, !ufound)

	// --- resolved history: txids recovered via block reads ----------------
	rhist, rerr := hugin.query_history_resolved(idx, sh_a)
	testing.expect_value(t, rerr, nil)
	defer delete(rhist)
	testing.expect_value(t, len(rhist), 2)
	if len(rhist) == 2 {
		testing.expect_value(t, rhist[0].txid, cb0_id) // funding: A's coinbase
		testing.expect_value(t, rhist[1].txid, tx1_id) // spend: tx1
	}

	// --- utxos ------------------------------------------------------------
	// A is fully spent: no utxos. B holds its coinbase (50) and tx1's
	// output (49); sum must equal the balance.
	utxos_a, uaerr := hugin.query_utxos(idx, sh_a)
	testing.expect_value(t, uaerr, nil)
	defer delete(utxos_a)
	testing.expect_value(t, len(utxos_a), 0)

	utxos_b, uberr := hugin.query_utxos(idx, sh_b)
	testing.expect_value(t, uberr, nil)
	defer delete(utxos_b)
	testing.expect_value(t, len(utxos_b), 2)
	total: u64
	saw_tx1 := false
	for u in utxos_b {
		total += u.amount
		if u.txid == tx1_id {
			saw_tx1 = true
			testing.expect_value(t, u.vout, u32(0))
			testing.expect_value(t, u.amount, u64(49 * COIN))
		}
	}
	testing.expect_value(t, i64(total), bal_b)
	testing.expect(t, saw_tx1, "tx1's output must be among B's utxos")

	// --- header -----------------------------------------------------------
	hdr, hfound := hugin.query_header(idx, 0)
	testing.expect(t, hfound)
	if hfound {
		testing.expect_value(t, hdr.hash, hugin.sha256d(hdr.raw[:]))
	}
	_, beyond := hugin.query_header(idx, 99)
	testing.expect(t, !beyond, "height beyond tip must not resolve")
}

// Merkle proofs: every tx of an odd-count block must produce a branch
// that folds back to the header's merkle root (query_merkle verifies
// internally; the fold here re-verifies independently).
@(test)
test_query_merkle :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_merkle_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	datadir := fmt.aprintf("%s/blocks", dir)
	index_dir := fmt.aprintf("%s/index", dir)
	defer {delete(datadir); delete(index_dir)}
	testing.expect_value(t, os.make_directory_all(datadir), nil)

	sbufA, sbufB: [22]byte
	script_a := bb_script(0x31, sbufA[:])
	script_b := bb_script(0x32, sbufB[:])

	COIN :: u64(100_000_000)
	blocks := make([dynamic][]byte)
	tx_raws := make([dynamic][]byte)
	defer {
		for b in blocks {delete(b)}
		delete(blocks)
		for r in tx_raws {delete(r)}
		delete(tx_raws)
	}

	// height 0: coinbase with two spendable outputs to A.
	cb0, cb0_id := bb_tx(nil, {{30 * COIN, script_a}, {20 * COIN, script_a}}, 1)
	append(&tx_raws, cb0)
	blk0, h0 := bb_block({}, {cb0}, 1)
	append(&blocks, blk0)

	// height 1: three transactions — odd count exercises duplicate-last.
	cb1, cb1_id := bb_tx(nil, {{50 * COIN, script_b}}, 2)
	append(&tx_raws, cb1)
	tx1, tx1_id := bb_tx({{prev = {cb0_id, 0}}}, {{29 * COIN, script_b}})
	append(&tx_raws, tx1)
	tx2, tx2_id := bb_tx({{prev = {cb0_id, 1}}}, {{19 * COIN, script_b}})
	append(&tx_raws, tx2)
	blk1, _ := bb_block(h0, {cb1, tx1, tx2}, 2)
	append(&blocks, blk1)

	bb_write_blkfiles(t, datadir, blocks[:], 10)

	cfg := hugin.Config {
		datadir     = datadir,
		index_dir   = index_dir,
		network     = .Mainnet,
		bucket_bits = 4,
		workers     = 2,
	}
	testing.expect_value(t, hugin.build_index(cfg), nil)
	testing.expect_value(t, hugin.catchup_run(cfg), nil)

	idx, oerr := hugin.index_open(cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	// The block's merkle root, straight from the header bytes.
	mroot: [32]u8
	copy(mroot[:], blk1[36:68])

	ids := [][32]u8{cb1_id, tx1_id, tx2_id}
	for want_id, want_pos in ids {
		height, pos, branch, found, merr := hugin.query_merkle(idx, want_id)
		testing.expect_value(t, merr, nil)
		testing.expectf(t, found, "tx %d not found", want_pos)
		if !found {continue}
		defer delete(branch)
		testing.expect_value(t, height, u32(1))
		testing.expect_value(t, pos, u32(want_pos))

		// Independent fold: leaf up to the root.
		acc := want_id
		p := int(pos)
		for &node in branch {
			if p & 1 == 1 {
				acc = hugin.sha256d_parts({node[:], acc[:]})
			} else {
				acc = hugin.sha256d_parts({acc[:], node[:]})
			}
			p >>= 1
		}
		testing.expectf(t, acc == mroot, "branch for pos %d does not fold to the root", want_pos)
	}

	// A single-tx block: empty branch, root == txid.
	height0, pos0, branch0, found0, merr0 := hugin.query_merkle(idx, cb0_id)
	testing.expect_value(t, merr0, nil)
	testing.expect(t, found0, "coinbase of block 0 must be found")
	defer delete(branch0)
	testing.expect_value(t, height0, u32(0))
	testing.expect_value(t, pos0, u32(0))
	testing.expect_value(t, len(branch0), 0)
}

// script_to_address must round-trip with address_to_scripthash for every
// encodable class — the esplora API's address rendering depends on it.
@(test)
test_script_to_address_roundtrip :: proc(t: ^testing.T) {
	// Known vector: the genesis-era P2PKH plus modern segwit forms.
	cases := [][2]string {
		{"76a914751e76e8199196d454941c45d1b3a323f1433bd688ac", "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"},
		{"0014751e76e8199196d454941c45d1b3a323f1433bd6", "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"},
		{"5120339ce7e165e67d93adb3fef88a6d4beed33f01fa876f05a225242b82a631abc0", "bc1pxwww0ct9ue7e8tdnlmug5m2tamfn7q06sahstg39ys4c9f3340qqxrdu9k"},
	}
	for c in cases {
		script_bytes := make([]byte, len(c[0]) / 2)
		defer delete(script_bytes)
		for i in 0 ..< len(script_bytes) {
			hi := hexv(c[0][i * 2])
			lo := hexv(c[0][i * 2 + 1])
			script_bytes[i] = byte(hi << 4 | lo)
		}
		addr, ok := hugin.script_to_address(script_bytes, .Mainnet)
		defer delete(addr)
		testing.expectf(t, ok, "no address for %s", c[0])
		testing.expect_value(t, addr, c[1])
	}
}

@(private = "file")
hexv :: proc(c: byte) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	}
	return 0
}


// Deep-address resolution on an XOR-obfuscated datadir must reuse ONE
// de-obfuscation buffer. Allocating per height (the regression) burned a
// block-sized copy per distinct height and OOM-killed the live daemon on
// a deep address. Plain datadirs read zero-copy, which is why only an
// obfuscated world reproduces it.
@(test)
test_history_resolve_scratch_reuse :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA: [22]byte
	script_a := bb_script(0xE1, sbufA[:])
	sh_a := hugin.scripthash(script_a)

	N :: 40
	prev: [32]u8
	for i in 0 ..< N {
		h, _ := world_coinbase(t, &w, prev, script_a, u32(i + 1))
		prev = h
	}
	world_flush(t, &w)
	world_obfuscate(t, &w) // Core v28+ style: every block read COPIES
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer hugin.index_close(idx)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	res: []hugin.Resolved_History_Entry
	herr: hugin.Error
	{
		ctx := context
		ctx.temp_allocator = mem.tracking_allocator(&track)
		context = ctx
		res, herr = hugin.query_history_resolved(idx, sh_a, 0, -1, context.allocator)
	}
	testing.expect_value(t, herr, nil)
	testing.expect_value(t, len(res), N)
	delete(res)

	// One shared buffer: peak scratch stays near a single block, not N.
	peak := int(track.peak_memory_allocated)
	testing.expectf(
		t,
		peak < 256 * 1024,
		"resolve peaked at %d bytes over %d heights — the scratch buffer is not being reused",
		peak,
		N,
	)
}
