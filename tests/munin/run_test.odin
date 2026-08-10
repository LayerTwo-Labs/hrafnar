package munin_tests

import "core:bytes"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:testing"

import munin "../../munin"

// Fixed-width binary keys shaped like the real workload: a 8-byte hash-like
// prefix plus a 4-byte big-endian ordinal.
@(private = "file")
gen_run_keys :: proc(n: int, allocator := context.allocator) -> [][]byte {
	out := make([][]byte, n, allocator)
	// Sorted by construction: increasing 12-byte big-endian counters spread
	// across a few prefixes, with random gaps.
	counter: u64
	for i in 0 ..< n {
		counter += u64(rand.int_max(1000)) + 1
		k := make([]byte, 12, allocator)
		for j in 0 ..< 8 {
			k[j] = byte(counter >> uint(56 - 8 * j))
		}
		k[8] = byte(i >> 24)
		k[9] = byte(i >> 16)
		k[10] = byte(i >> 8)
		k[11] = byte(i)
		out[i] = k
	}
	return out
}

@(private = "file")
run_value_for :: proc(key: []byte, buf: []byte) -> []byte {
	n := (int(key[len(key) - 1]) * 7) % (len(buf) + 1)
	for i in 0 ..< n {
		buf[i] = key[i % len(key)] ~ byte(i * 31)
	}
	return buf[:n]
}

@(private = "file")
write_test_run :: proc(
	t: ^testing.T,
	path: string,
	keys: [][]byte,
	cfg: munin.Run_Writer_Config,
) {
	w: munin.Run_Writer
	err := munin.run_writer_begin(&w, path, cfg)
	testing.expect_value(t, err, nil)
	defer munin.run_writer_destroy(&w)

	vbuf: [64]byte
	for k in keys {
		v := run_value_for(k, vbuf[:]) if !cfg.key_only else nil
		aerr := munin.run_writer_add(&w, k, v)
		testing.expect_value(t, aerr, nil)
	}
	res, ferr := munin.run_writer_finish(&w)
	testing.expect_value(t, ferr, nil)
	testing.expect_value(t, res.entry_count, u64(len(keys)))

	info, serr := os.stat(path, context.allocator)
	testing.expect_value(t, serr, nil)
	defer os.file_info_delete(info, context.allocator)
	testing.expect_value(t, u64(info.size), res.file_size)
}

@(private = "file")
verify_run :: proc(t: ^testing.T, r: ^munin.Run, keys: [][]byte, key_only: bool) {
	it: munin.Run_Iter
	munin.run_iter_init(&it, r)
	defer munin.run_iter_destroy(&it)

	vbuf: [64]byte

	// Full scan in order.
	munin.run_iter_seek_first(&it)
	for k, i in keys {
		testing.expectf(t, munin.run_iter_valid(&it), "scan died at %d (err=%v)", i, it.err)
		if !munin.run_iter_valid(&it) {return}
		testing.expectf(
			t,
			bytes.compare(munin.run_iter_key(&it), k) == 0,
			"scan[%d]: got % x want % x",
			i,
			munin.run_iter_key(&it),
			k,
		)
		if !key_only {
			want := run_value_for(k, vbuf[:])
			testing.expectf(t, bytes.compare(munin.run_iter_value(&it), want) == 0, "scan[%d]: bad value", i)
		}
		munin.run_iter_next(&it)
	}
	testing.expect(t, !munin.run_iter_valid(&it), "iterator should be exhausted")
	testing.expect_value(t, it.err, nil)

	// Seek to every key.
	for k, i in keys {
		munin.run_iter_seek(&it, k)
		testing.expectf(t, munin.run_iter_valid(&it), "seek[%d] invalid (err=%v)", i, it.err)
		if !munin.run_iter_valid(&it) {return}
		testing.expectf(t, bytes.compare(munin.run_iter_key(&it), k) == 0, "seek[%d] wrong key", i)
	}

	// Seek just past each key lands on the successor.
	ext: [13]byte
	for k, i in keys {
		copy(ext[:], k)
		ext[12] = 0
		munin.run_iter_seek(&it, ext[:])
		if i + 1 < len(keys) {
			testing.expectf(t, munin.run_iter_valid(&it), "seek-past[%d] invalid", i)
			if !munin.run_iter_valid(&it) {return}
			testing.expectf(
				t,
				bytes.compare(munin.run_iter_key(&it), keys[i + 1]) == 0,
				"seek-past[%d] wrong successor",
				i,
			)
		} else {
			testing.expect(t, !munin.run_iter_valid(&it), "seek past last should invalidate")
		}
	}

	// Before-first and after-last.
	munin.run_iter_seek(&it, []byte{})
	testing.expect(t, munin.run_iter_valid(&it), "seek empty should land on first")
	testing.expect(t, bytes.compare(munin.run_iter_key(&it), keys[0]) == 0, "seek empty wrong key")
	high := [13]byte{0 = 0xff, 1 = 0xff, 2 = 0xff, 3 = 0xff, 4 = 0xff, 5 = 0xff, 6 = 0xff, 7 = 0xff, 8 = 0xff, 9 = 0xff, 10 = 0xff, 11 = 0xff, 12 = 0xff}
	munin.run_iter_seek(&it, high[:])
	testing.expect(t, !munin.run_iter_valid(&it), "seek after last should invalidate")
}

@(private = "file")
free_run_keys :: proc(keys: [][]byte) {
	for k in keys {delete(k)}
	delete(keys)
}

@(test)
test_run_round_trip :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	keys := gen_run_keys(5000)
	defer free_run_keys(keys)

	path := fmt.aprintf("%s/00000001.run", dir)
	defer delete(path)
	write_test_run(t, path, keys, {block_size = 512, restart_interval = 8})

	r, err := munin.run_open(path, 1)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	defer munin.run_close(r)
	testing.expect_value(t, r.entry_count, u64(len(keys)))
	testing.expect_value(t, r.key_only, false)
	testing.expect_value(t, r.has_filter, false)

	verify_run(t, r, keys, false)
}

@(test)
test_run_key_only :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	keys := gen_run_keys(3000)
	defer free_run_keys(keys)

	path := fmt.aprintf("%s/00000002.run", dir)
	defer delete(path)
	write_test_run(t, path, keys, {block_size = 256, restart_interval = 4, key_only = true})

	r, err := munin.run_open(path, 2)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	defer munin.run_close(r)
	testing.expect_value(t, r.key_only, true)

	verify_run(t, r, keys, true)
}

@(test)
test_run_with_filter :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	keys := gen_run_keys(2000)
	defer free_run_keys(keys)

	path := fmt.aprintf("%s/00000003.run", dir)
	defer delete(path)
	write_test_run(
		t,
		path,
		keys,
		{block_size = 512, restart_interval = 8, filter_prefix_len = 8, filter_bits_per_key = 10},
	)

	r, err := munin.run_open(path, 3)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	defer munin.run_close(r)
	testing.expect_value(t, r.has_filter, true)

	verify_run(t, r, keys, false)

	// Every present key's prefix must pass the filter.
	for k in keys {
		testing.expect(t, munin.run_filter_check(r, k), "false negative in filter")
	}
}

@(test)
test_run_oversized_entry :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	// A value far larger than the block size must get its own block.
	big := make([]byte, 64 * 1024)
	defer delete(big)
	for &b, i in big {b = byte(i * 13)}

	path := fmt.aprintf("%s/00000004.run", dir)
	defer delete(path)

	w: munin.Run_Writer
	err := munin.run_writer_begin(&w, path, {block_size = 512})
	testing.expect_value(t, err, nil)
	defer munin.run_writer_destroy(&w)

	testing.expect_value(t, munin.run_writer_add(&w, []byte{1, 1}, []byte{0xAA}), nil)
	testing.expect_value(t, munin.run_writer_add(&w, []byte{2, 2}, big), nil)
	testing.expect_value(t, munin.run_writer_add(&w, []byte{3, 3}, []byte{0xBB}), nil)
	_, ferr := munin.run_writer_finish(&w)
	testing.expect_value(t, ferr, nil)

	r, oerr := munin.run_open(path, 4)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer munin.run_close(r)

	it: munin.Run_Iter
	munin.run_iter_init(&it, r)
	defer munin.run_iter_destroy(&it)

	munin.run_iter_seek(&it, []byte{2, 2})
	testing.expect(t, munin.run_iter_valid(&it), "seek to oversized entry")
	testing.expect(t, bytes.compare(munin.run_iter_value(&it), big) == 0, "oversized value intact")
}

@(test)
test_run_out_of_order_across_blocks :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	path := fmt.aprintf("%s/00000005.run", dir)
	defer delete(path)

	w: munin.Run_Writer
	err := munin.run_writer_begin(&w, path, {block_size = 64})
	testing.expect_value(t, err, nil)

	// Fill past one block, then violate order.
	for i in 0 ..< 50 {
		k := [4]byte{0, 0, byte(i >> 8), byte(i)}
		testing.expect_value(t, munin.run_writer_add(&w, k[:], nil), nil)
	}
	bad := [4]byte{0, 0, 0, 5}
	testing.expect_value(
		t,
		munin.run_writer_add(&w, bad[:], nil),
		munin.Error(munin.Usage_Error.Keys_Out_Of_Order),
	)
	munin.run_writer_abort(&w)
}

@(test)
test_run_corruption_detected :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	keys := gen_run_keys(500)
	defer free_run_keys(keys)

	path := fmt.aprintf("%s/00000006.run", dir)
	defer delete(path)
	write_test_run(t, path, keys, {block_size = 512})

	data, rerr := os.read_entire_file(path, context.allocator)
	testing.expect_value(t, rerr, nil)
	defer delete(data)

	// Flip one byte in the middle of the first data block.
	corrupt := fmt.aprintf("%s/corrupt.run", dir)
	defer delete(corrupt)
	data[10] ~= 0xFF
	testing.expect_value(t, os.write_entire_file(corrupt, data), nil)
	data[10] ~= 0xFF

	r, oerr := munin.run_open(corrupt, 6)
	testing.expect_value(t, oerr, nil) // footer+index still fine
	if oerr == nil {
		it: munin.Run_Iter
		munin.run_iter_init(&it, r)
		munin.run_iter_seek_first(&it)
		// The bad block must surface as a checksum error, not bad data.
		testing.expect(t, !munin.run_iter_valid(&it), "corrupt block must not iterate")
		testing.expect_value(t, it.err, munin.Error(munin.Corruption.Bad_Checksum))
		munin.run_iter_destroy(&it)
		munin.run_close(r)
	}

	// Corrupt footer magic.
	data[len(data) - 64] ~= 0x01
	testing.expect_value(t, os.write_entire_file(corrupt, data), nil)
	data[len(data) - 64] ~= 0x01
	_, oerr = munin.run_open(corrupt, 6)
	testing.expect_value(t, oerr, munin.Error(munin.Corruption.Bad_Magic))

	// Corrupt footer checksum field.
	data[len(data) - 8] ~= 0x01
	testing.expect_value(t, os.write_entire_file(corrupt, data), nil)
	data[len(data) - 8] ~= 0x01
	_, oerr = munin.run_open(corrupt, 6)
	testing.expect_value(t, oerr, munin.Error(munin.Corruption.Bad_Checksum))

	// Future format version (recompute the footer CRC so only the version
	// check can fire).
	fut := make([]byte, len(data))
	defer delete(fut)
	copy(fut, data)
	foot := fut[len(fut) - 64:]
	foot[8] = 0xEF
	foot[9] = 0xBE
	crc := munin.crc32c(foot[:56])
	foot[56] = byte(crc)
	foot[57] = byte(crc >> 8)
	foot[58] = byte(crc >> 16)
	foot[59] = byte(crc >> 24)
	testing.expect_value(t, os.write_entire_file(corrupt, fut), nil)
	_, oerr = munin.run_open(corrupt, 6)
	testing.expect_value(t, oerr, munin.Error(munin.Corruption.Bad_Format_Version))

	// Truncated file.
	testing.expect_value(t, os.write_entire_file(corrupt, data[:30]), nil)
	_, oerr = munin.run_open(corrupt, 6)
	testing.expect_value(t, oerr, munin.Error(munin.Corruption.Truncated))
}
