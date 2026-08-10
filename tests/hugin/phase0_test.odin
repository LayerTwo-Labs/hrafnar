package hugin_tests

// Phase 0 tests: blk file framing, header DAG, chain selection, stores.
// Synthetic chains only — no Bitcoin data directory required.

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:testing"

import hugin "../../hugin"

MAGIC :: [4]u8{0xF9, 0xBE, 0xB4, 0xD9}

// A non-obfuscated stand-in file for tests that build records by hand.
@(private = "file")
plain_file: hugin.Blk_File

// A synthetic block: valid 80-byte header + tx-count varint + padding.
Synth_Block :: struct {
	bytes: []byte, // full block payload
	hash:  [32]u8,
}

// make_block builds a block whose header links to prev. bits controls the
// per-block work for fork tests.
@(private = "file")
make_block :: proc(prev: [32]u8, bits: u32, nonce: u32, tx_count: int) -> Synth_Block {
	prev := prev
	size := 80 + 3 + 40 * tx_count // varint(<=0xFC needs 1; use 3 for safety pad)
	b := make([]byte, size)
	// version
	b[0] = 4
	copy(b[4:36], prev[:])
	// merkle root: random-ish from nonce
	for i in 36 ..< 68 {b[i] = byte(u32(i) * 7 ~ nonce)}
	// time
	b[68] = 0x60
	// bits
	b[72] = byte(bits)
	b[73] = byte(bits >> 8)
	b[74] = byte(bits >> 16)
	b[75] = byte(bits >> 24)
	// nonce
	b[76] = byte(nonce)
	b[77] = byte(nonce >> 8)
	b[78] = byte(nonce >> 16)
	b[79] = byte(nonce >> 24)
	// tx count varint (single byte for our sizes)
	b[80] = byte(tx_count)
	// fake tx bytes: arbitrary padding
	for i in 81 ..< size {b[i] = byte(i * 13)}
	return Synth_Block{bytes = b, hash = hugin.sha256d(b[:80])}
}

// write_blk_file frames blocks into a blk file with an optional zero tail.
@(private = "file")
write_blk_file :: proc(t: ^testing.T, path: string, blocks: []Synth_Block, zero_tail: int) {
	buf := make([dynamic]byte)
	defer delete(buf)
	for blk in blocks {
		append(&buf, MAGIC[0], MAGIC[1], MAGIC[2], MAGIC[3])
		n := u32(len(blk.bytes))
		append(&buf, byte(n), byte(n >> 8), byte(n >> 16), byte(n >> 24))
		append(&buf, ..blk.bytes)
	}
	for _ in 0 ..< zero_tail {append(&buf, 0)}
	testing.expect_value(t, os.write_entire_file(path, buf[:]), nil)
}

@(test)
test_work_from_bits_known :: proc(t: ^testing.T) {
	// Mainnet genesis difficulty: chainwork of one block is 0x100010001.
	testing.expect_value(t, hugin.work_from_bits(0x1d00ffff), u128(0x100010001))
	// Regtest maximum target: work per block is exactly 2.
	testing.expect_value(t, hugin.work_from_bits(0x207fffff), u128(2))
	// A step harder than genesis: 0x1c7fff80 halves the target vs
	// 0x1d00ffff (roughly), so work roughly doubles.
	w1 := hugin.work_from_bits(0x1d00ffff)
	w2 := hugin.work_from_bits(0x1c7fffff)
	testing.expect(t, w2 > w1, "smaller target must mean more work")
	// Malformed: zero mantissa, negative flag.
	testing.expect_value(t, hugin.work_from_bits(0x1d000000), u128(0))
	testing.expect_value(t, hugin.work_from_bits(0x1d800000 | 0x00800000), u128(0))
}

@(test)
test_blkfile_framing :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	genesis := make_block({}, 0x207fffff, 1, 1)
	b1 := make_block(genesis.hash, 0x207fffff, 2, 2)
	b2 := make_block(b1.hash, 0x207fffff, 3, 3)
	defer {delete(genesis.bytes); delete(b1.bytes); delete(b2.bytes)}

	// File 0 with a zero tail; file 2 (gap!) with a truncated final record.
	p0 := fmt.aprintf("%s/blk00000.dat", dir)
	p2 := fmt.aprintf("%s/blk00002.dat", dir)
	defer {delete(p0); delete(p2)}
	write_blk_file(t, p0, {genesis, b1}, 1024)
	write_blk_file(t, p2, {b2}, 0)
	// Append a torn record to file 2: magic + size but half the payload.
	{
		data, _ := os.read_entire_file(p2, context.allocator)
		defer delete(data)
		torn := make([dynamic]byte)
		defer delete(torn)
		append(&torn, ..data)
		append(&torn, MAGIC[0], MAGIC[1], MAGIC[2], MAGIC[3])
		append(&torn, 0x90, 0, 0, 0) // claims 144 bytes
		for i in 0 ..< 50 {append(&torn, byte(i))}
		testing.expect_value(t, os.write_entire_file(p2, torn[:]), nil)
	}
	// A decoy that must be ignored by enumeration.
	decoy := fmt.aprintf("%s/rev00000.dat", dir)
	defer delete(decoy)
	testing.expect_value(t, os.write_entire_file(decoy, []byte{1}), nil)

	files, eerr := hugin.blkfile_enumerate(dir)
	testing.expect_value(t, eerr, nil)
	defer hugin.blkfiles_destroy(files)
	testing.expect_value(t, len(files), 2)
	testing.expect_value(t, files[0].file_no, u32(0))
	testing.expect_value(t, files[1].file_no, u32(2))

	total := 0
	for &f in files {
		testing.expect_value(t, hugin.blkfile_map(&f), nil)
		it: hugin.Blk_Record_Iter
		hugin.blk_record_iter_init(&it, &f, MAGIC)
		for {
			rec, ok := hugin.blk_record_iter_next(&it)
			if !ok {break}
			testing.expect(t, len(rec.block) >= 81, "record too short")
			total += 1
			_ = rec
		}
		testing.expect_value(t, it.err, nil) // torn tail is not an error
	}
	testing.expect_value(t, total, 3)
}

@(test)
test_blkfile_bad_magic :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	p := fmt.aprintf("%s/blk00000.dat", dir)
	defer delete(p)
	bad := make([]byte, 100)
	defer delete(bad)
	bad[0] = 0xDE
	bad[1] = 0xAD
	bad[2] = 0xBE
	bad[3] = 0xEF
	testing.expect_value(t, os.write_entire_file(p, bad), nil)

	files, eerr := hugin.blkfile_enumerate(dir)
	testing.expect_value(t, eerr, nil)
	defer hugin.blkfiles_destroy(files)
	testing.expect_value(t, hugin.blkfile_map(&files[0]), nil)

	it: hugin.Blk_Record_Iter
	hugin.blk_record_iter_init(&it, &files[0], MAGIC)
	_, ok := hugin.blk_record_iter_next(&it)
	testing.expect(t, !ok)
	testing.expect_value(t, it.err, hugin.Error(hugin.Corruption.Bad_Magic))
}

// Chain selection: main chain, a lighter fork, orphans, out-of-order
// records. The most-work tip must win regardless of length.
@(test)
test_header_chain_selection :: proc(t: ^testing.T) {
	// Light chain: genesis + 6 blocks at minimal work.
	LIGHT :: u32(0x207fffff)
	// Heavy fork off block 2: 3 blocks at much higher work (smaller target).
	HEAVY :: u32(0x1f00ffff)

	genesis := make_block({}, LIGHT, 100, 1)
	light: [6]Synth_Block
	prev := genesis.hash
	for i in 0 ..< 6 {
		light[i] = make_block(prev, LIGHT, u32(200 + i), 1)
		prev = light[i].hash
	}
	heavy: [3]Synth_Block
	prev = light[1].hash // fork point after light[1]
	for i in 0 ..< 3 {
		heavy[i] = make_block(prev, HEAVY, u32(300 + i), 1)
		prev = heavy[i].hash
	}
	// A detached orphan whose parent is unknown.
	fake_parent: [32]u8
	fake_parent[0] = 0xAA
	orphan := make_block(fake_parent, LIGHT, 999, 1)

	defer {
		delete(genesis.bytes)
		for &b in light {delete(b.bytes)}
		for &b in heavy {delete(b.bytes)}
		delete(orphan.bytes)
	}

	dag: hugin.Header_Dag
	hugin.header_dag_init(&dag)
	defer hugin.header_dag_destroy(&dag)

	// Insert in a scrambled order, as blk files deliver them.
	all := make([dynamic]Synth_Block)
	defer delete(all)
	append(&all, genesis)
	for b in light {append(&all, b)}
	for b in heavy {append(&all, b)}
	append(&all, orphan)
	rand.shuffle(all[:])

	for blk, i in all {
		rec := hugin.Blk_Record {
			file_no = 0,
			offset  = u32(i * 1000),
			block   = blk.bytes,
		}
		e, herr := hugin.header_entry_from_record(&plain_file, rec)
		testing.expect_value(t, herr, nil)
		hugin.header_dag_add(&dag, e)
	}
	// Duplicate insert must be a no-op.
	count_before := len(dag.entries)
	rec := hugin.Blk_Record{file_no = 0, offset = 0, block = genesis.bytes}
	e, _ := hugin.header_entry_from_record(&plain_file, rec)
	hugin.header_dag_add(&dag, e)
	testing.expect_value(t, len(dag.entries), count_before)

	chain, serr := hugin.header_dag_select_chain(&dag)
	testing.expect_value(t, serr, nil)
	defer delete(chain)

	// Expected: genesis, light[0], light[1], heavy[0..2] — 6 entries.
	// The heavy fork (3 blocks at ~256x work) outweighs light[2..5].
	testing.expect_value(t, len(chain), 6)
	if len(chain) != 6 {return}
	testing.expect_value(t, dag.entries[chain[0]].hash, genesis.hash)
	testing.expect_value(t, dag.entries[chain[1]].hash, light[0].hash)
	testing.expect_value(t, dag.entries[chain[2]].hash, light[1].hash)
	testing.expect_value(t, dag.entries[chain[3]].hash, heavy[0].hash)
	testing.expect_value(t, dag.entries[chain[5]].hash, heavy[2].hash)
}

@(test)
test_headers_store_round_trip :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	N :: 500
	chain := make([]hugin.Stored_Header, N)
	defer delete(chain)
	for i in 0 ..< N {
		h := &chain[i]
		for j in 0 ..< 32 {h.hash[j] = byte(i * 31 + j)}
		for j in 0 ..< 80 {h.raw[j] = byte(i * 7 + j)}
		h.file_no = u32(i / 100)
		h.offset = u32(i * 1234)
		h.length = u32(1000 + i)
		h.tx_count = u32(1 + i % 50)
	}

	testing.expect_value(t, hugin.headers_store_write(dir, chain), nil)
	back, rerr := hugin.headers_store_read(dir)
	testing.expect_value(t, rerr, nil)
	defer delete(back)
	testing.expect_value(t, len(back), N)
	for i in 0 ..< N {
		testing.expect_value(t, back[i], chain[i])
	}

	// Truncated store must be rejected.
	data, _ := os.read_entire_file(fmt.tprintf("%s/headers.dat", dir), context.allocator)
	defer delete(data)
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/headers.dat", dir), data[:len(data) - 5]), nil)
	_, terr := hugin.headers_store_read(dir)
	testing.expect_value(t, terr, hugin.Error(hugin.Corruption.Truncated))
}

@(test)
test_checkpoint_round_trip :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	hash: [32]u8
	for i in 0 ..< 32 {hash[i] = byte(i * 3)}

	testing.expect_value(t, hugin.checkpoint_write(dir, 812345, hash), nil)
	h, hh, rerr := hugin.checkpoint_read(dir)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, h, u32(812345))
	testing.expect_value(t, hh, hash)

	// Flip a byte: checksum failure.
	path := fmt.tprintf("%s/CHECKPOINT", dir)
	data, _ := os.read_entire_file(path, context.allocator)
	defer delete(data)
	data[5] ~= 0x40
	testing.expect_value(t, os.write_entire_file(path, data), nil)
	_, _, cerr := hugin.checkpoint_read(dir)
	testing.expect_value(t, cerr, hugin.Error(hugin.Corruption.Bad_Checksum))
}
