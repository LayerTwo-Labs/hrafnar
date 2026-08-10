package hugin_tests

// Bitcoin Core v28+ XOR obfuscation: the same build/catch-up/query flow
// must work when every blk file is XORed with the key in blocks/xor.dat.

import "core:fmt"
import "core:os"
import "core:testing"

import hugin "../../hugin"

@(private = "file")
xor_test_key := [8]u8{0xDE, 0xAD, 0xBE, 0xEF, 0x13, 0x37, 0xC0, 0xDE}

// world_obfuscate XORs every blk file in place and writes xor.dat, exactly
// as a v28+ Core datadir looks.
world_obfuscate :: proc(t: ^testing.T, w: ^Catchup_World) {
	entries, rerr := os.read_directory_by_path(w.datadir, -1, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	for e in entries {
		path := fmt.tprintf("%s/%s", w.datadir, e.name)
		data, derr := os.read_entire_file(path, context.temp_allocator)
		testing.expect_value(t, derr, nil)
		for &b, i in data {
			b ~= xor_test_key[i & 7]
		}
		testing.expect_value(t, os.write_entire_file(path, data), nil)
	}
	key := xor_test_key
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/xor.dat", w.datadir), key[:]), nil)
}

@(test)
test_xor_obfuscated_datadir :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	COIN :: u64(100_000_000)
	sbufA, sbufB: [22]byte
	script_a := bb_script(0x7A, sbufA[:])
	script_b := bb_script(0x7B, sbufB[:])
	sh_a := hugin.scripthash(script_a)
	sh_b := hugin.scripthash(script_b)

	// Heights 0..3: three coinbases to A, then a block whose tx spends A's
	// first coinbase to B — so the join and spend resolution both run over
	// obfuscated bytes.
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

	world_obfuscate(t, &w)

	// Bulk build + catch-up on the obfuscated datadir.
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	// Balances through the query layer (merges main body + recent tier).
	expect_balance(t, w.cfg, sh_a, i64(3 * 50 * COIN))
	expect_balance(t, w.cfg, sh_b, i64(49 * COIN))

	idx, oerr := hugin.index_open(w.cfg)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}

	// Raw tx retrieval must return DE-obfuscated bytes that hash to the
	// txid.
	raw, height, found, terr := hugin.query_tx(idx, spend_id)
	testing.expect_value(t, terr, nil)
	testing.expect(t, found, "spend tx must be found")
	if found {
		testing.expect_value(t, height, u32(3))
		testing.expect_value(t, hugin.sha256d(raw), spend_id)
	}

	// Outpoint lookup.
	sp, sfound, serr := hugin.query_outpoint(idx, cb0_id, 0)
	testing.expect_value(t, serr, nil)
	testing.expect(t, sfound, "spent outpoint must be found")
	if sfound {
		testing.expect_value(t, sp.spender_txid, spend_id)
	}
	hugin.index_close(idx)

	// Extend the chain (still obfuscated) and catch up again: exercises
	// the incremental path over XORed data, including funding-tx reads
	// from the main body.
	h3 := hugin.sha256d(blk3[:80])
	cb4, _ := bb_tx(nil, {{50 * COIN, script_b}}, 5)
	append(&w.tx_raws, cb4)
	blk4, _ := bb_block(h3, {cb4}, 5)
	append(&w.blocks, blk4)
	world_flush(t, &w)
	world_obfuscate(t, &w)

	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)
	expect_balance(t, w.cfg, sh_b, i64(99 * COIN))
	expect_balance(t, w.cfg, sh_a, i64(3 * 50 * COIN))
}

// The newest blk file is preallocated: its unwritten tail is raw zeros on
// disk, NOT obfuscated zeros. Iteration must treat that as end-of-data,
// never Bad_Magic. This is exactly what a live Core v28 datadir looks
// like.
@(test)
test_xor_preallocated_tail :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbuf: [22]byte
	script := bb_script(0x7C, sbuf[:])
	h0, _ := world_coinbase(t, &w, {}, script, 1)
	_, _ = world_coinbase(t, &w, h0, script, 2)
	world_flush(t, &w)
	world_obfuscate(t, &w)

	// Append a raw-zero preallocated tail to the (obfuscated) file.
	path := fmt.tprintf("%s/blk00000.dat", w.datadir)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	padded := make([dynamic]byte, context.temp_allocator)
	append(&padded, ..data)
	for _ in 0 ..< 4096 {append(&padded, 0)}
	testing.expect_value(t, os.write_entire_file(path, padded[:]), nil)

	files, eerr := hugin.blkfile_enumerate(w.datadir)
	testing.expect_value(t, eerr, nil)
	defer hugin.blkfiles_destroy(files)
	testing.expect_value(t, hugin.blkfile_map(&files[0]), nil)

	it: hugin.Blk_Record_Iter
	hugin.blk_record_iter_init(&it, &files[0], [4]u8{0xF9, 0xBE, 0xB4, 0xD9})
	count := 0
	for {
		_, ok := hugin.blk_record_iter_next(&it)
		if !ok {break}
		count += 1
	}
	testing.expect_value(t, it.err, nil) // raw-zero tail is end-of-data
	testing.expect_value(t, count, 2)
}

@(test)
test_xor_zero_key_is_plain :: proc(t: ^testing.T) {
	// An all-zero xor.dat (written when obfuscation is disabled) must not
	// activate decoding.
	dir, derr := os.make_directory_temp("", "hugin_xor_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	zeros: [8]u8
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/xor.dat", dir), zeros[:]), nil)
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/blk00000.dat", dir), []byte{0xF9, 0xBE, 0xB4, 0xD9, 0, 0, 0, 0}), nil)

	files, eerr := hugin.blkfile_enumerate(dir)
	testing.expect_value(t, eerr, nil)
	defer hugin.blkfiles_destroy(files)
	testing.expect_value(t, len(files), 1)
	testing.expect_value(t, files[0].xored, false)
}


// The vector de-obfuscation reads from an mmapped file at arbitrary
// offsets, so its loads and stores MUST be unaligned. Dereferencing a
// ^#simd pointer instead emits an aligned move that faults on x86-64
// (vmovdqa) while passing on ARM — a crash that only appears in
// production on the wrong architecture. Drive every alignment, and check
// the bytes against the obvious scalar loop.
@(test)
test_blk_xor_unaligned :: proc(t: ^testing.T) {
	key: [8]u8 = {0x11, 0x22, 0x33, 0x44, 0xAA, 0xBB, 0xCC, 0xDD}

	// Over-allocate so slices can start at any byte alignment.
	backing := make([]byte, 4096 + 64)
	defer delete(backing)
	out_backing := make([]byte, 4096 + 64)
	defer delete(out_backing)
	for i in 0 ..< len(backing) {backing[i] = u8((i * 31) & 0xFF)}

	for src_align in 0 ..< 33 {
		for dst_align in 0 ..< 5 {
			for length in ([]int{0, 1, 7, 8, 31, 32, 33, 64, 65, 127, 1000, 4000}) {
				src := backing[src_align:src_align + length]
				dst := out_backing[dst_align:dst_align + length]
				for offset in ([]u32{0, 1, 5, 7, 8, 4096}) {
					hugin.blk_xor(dst, src, key, offset)
					ok := true
					for i in 0 ..< length {
						want := src[i] ~ key[(int(offset) + i) & 7]
						if dst[i] != want {
							ok = false
							break
						}
					}
					testing.expectf(
						t,
						ok,
						"blk_xor mismatch: src_align=%d dst_align=%d len=%d offset=%d",
						src_align,
						dst_align,
						length,
						offset,
					)
				}
			}
		}
	}
}
