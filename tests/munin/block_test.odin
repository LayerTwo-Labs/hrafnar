package munin_tests

import "core:bytes"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"

import munin "../../munin"

// Generate sorted unique keys with heavy shared prefixes, the shape the
// index actually sees.
@(private = "file")
gen_sorted_keys :: proc(n: int, allocator := context.allocator) -> [][]byte {
	keys := make(map[string]struct {}, allocator)
	defer delete(keys)

	prefixes := [?]string{"", "aa", "aaaa", "prefix/common/", "zzz"}
	for len(keys) < n {
		p := rand.choice(prefixes[:])
		k := fmt.aprintf("%s%08d/%04d", p, rand.int_max(1_000_000), rand.int_max(10_000), allocator = allocator)
		if k in keys {
			delete(k, allocator)
		} else {
			keys[k] = {}
		}
	}

	out := make([][]byte, n, allocator)
	i := 0
	for k in keys {
		out[i] = transmute([]byte)k
		i += 1
	}
	slice.sort_by(out[:], proc(a, b: []byte) -> bool {return bytes.compare(a, b) < 0})
	return out
}

@(private = "file")
free_keys :: proc(keys: [][]byte, allocator := context.allocator) {
	for k in keys {delete(k, allocator)}
	delete(keys, allocator)
}

@(private = "file")
value_for :: proc(key: []byte, buf: []byte) -> []byte {
	// Deterministic value derived from the key, variable length.
	n := len(key) % (len(buf) + 1)
	for i in 0 ..< n {
		buf[i] = key[i % len(key)] ~ byte(i)
	}
	return buf[:n]
}

@(private = "file")
round_trip_block :: proc(t: ^testing.T, keys: [][]byte, restart_interval: int, key_only: bool) {
	w: munin.Block_Writer
	munin.block_writer_init(&w, restart_interval, key_only)
	defer munin.block_writer_destroy(&w)

	vbuf: [64]byte
	for k in keys {
		v := value_for(k, vbuf[:]) if !key_only else nil
		err := munin.block_writer_add(&w, k, v)
		testing.expect_value(t, err, nil)
	}
	payload := munin.block_writer_finish(&w)

	b: munin.Block
	err := munin.block_init(&b, payload, key_only)
	testing.expect_value(t, err, nil)

	it: munin.Block_Iter
	munin.block_iter_init(&it, &b)
	defer munin.block_iter_destroy(&it)

	// Full scan matches input order.
	munin.block_iter_seek_first(&it)
	for k, i in keys {
		testing.expectf(t, it.valid, "iterator died at %d (err=%v)", i, it.err)
		testing.expectf(t, bytes.compare(it.key[:], k) == 0, "scan[%d]: got %q want %q", i, string(it.key[:]), string(k))
		if !key_only {
			want := value_for(k, vbuf[:])
			testing.expectf(t, bytes.compare(it.value, want) == 0, "scan[%d]: bad value", i)
		} else {
			testing.expect_value(t, len(it.value), 0)
		}
		munin.block_iter_next(&it)
	}
	testing.expect(t, !it.valid, "iterator should be exhausted")
	testing.expect_value(t, it.err, nil)

	// Seek to every key lands on it.
	for k, i in keys {
		munin.block_iter_seek(&it, k)
		testing.expectf(t, it.valid, "seek[%d] invalid", i)
		testing.expectf(t, bytes.compare(it.key[:], k) == 0, "seek[%d]: got %q want %q", i, string(it.key[:]), string(k))
	}

	// Seek to a key just past each key lands on the successor.
	ext := make([dynamic]byte)
	defer delete(ext)
	for k, i in keys {
		resize(&ext, len(k) + 1)
		copy(ext[:], k)
		ext[len(k)] = 0
		munin.block_iter_seek(&it, ext[:])
		if i + 1 < len(keys) {
			testing.expectf(t, it.valid, "seek-past[%d] invalid", i)
			testing.expectf(t, bytes.compare(it.key[:], keys[i + 1]) == 0, "seek-past[%d] wrong successor", i)
		} else {
			testing.expect(t, !it.valid, "seek past last key should invalidate")
		}
	}

	// Seek before first, seek after last.
	munin.block_iter_seek(&it, []byte{})
	testing.expect(t, it.valid, "seek to empty key should land on first")
	testing.expect(t, bytes.compare(it.key[:], keys[0]) == 0, "seek-empty should land on first key")
	munin.block_iter_seek(&it, []byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff})
	testing.expect(t, !it.valid, "seek after last should invalidate")
}

@(test)
test_block_round_trip :: proc(t: ^testing.T) {
	keys := gen_sorted_keys(500)
	defer free_keys(keys)
	round_trip_block(t, keys, 16, false)
}

@(test)
test_block_key_only :: proc(t: ^testing.T) {
	keys := gen_sorted_keys(500)
	defer free_keys(keys)
	round_trip_block(t, keys, 16, true)
}

@(test)
test_block_random_restart_intervals :: proc(t: ^testing.T) {
	keys := gen_sorted_keys(200)
	defer free_keys(keys)
	for _ in 0 ..< 20 {
		ri := rand.int_max(40) + 1
		round_trip_block(t, keys, ri, rand.int_max(2) == 0)
	}
}

@(test)
test_block_single_entry :: proc(t: ^testing.T) {
	keys := [][]byte{transmute([]byte)string("only-key")}
	round_trip_block(t, keys[:], 16, false)
	round_trip_block(t, keys[:], 1, true)
}

@(test)
test_block_out_of_order_rejected :: proc(t: ^testing.T) {
	w: munin.Block_Writer
	munin.block_writer_init(&w, 16, false)
	defer munin.block_writer_destroy(&w)

	err := munin.block_writer_add(&w, transmute([]byte)string("bbb"), nil)
	testing.expect_value(t, err, nil)
	err = munin.block_writer_add(&w, transmute([]byte)string("aaa"), nil)
	testing.expect_value(t, err, munin.Error(munin.Usage_Error.Keys_Out_Of_Order))
	// Duplicate is also out of order (strictly increasing required).
	err = munin.block_writer_add(&w, transmute([]byte)string("bbb"), nil)
	testing.expect_value(t, err, munin.Error(munin.Usage_Error.Keys_Out_Of_Order))
}

@(test)
test_block_corrupt_truncated :: proc(t: ^testing.T) {
	w: munin.Block_Writer
	munin.block_writer_init(&w, 4, false)
	defer munin.block_writer_destroy(&w)
	keys := gen_sorted_keys(50)
	defer free_keys(keys)
	for k in keys {
		_ = munin.block_writer_add(&w, k, k)
	}
	payload := munin.block_writer_finish(&w)

	// Too short to hold its own restart count.
	b: munin.Block
	err := munin.block_init(&b, payload[:3], false)
	testing.expect_value(t, err, munin.Error(munin.Corruption.Bad_Block))

	// Restart count pointing outside the payload.
	bogus := make([]byte, 8)
	defer delete(bogus)
	bogus[4] = 0xff
	bogus[5] = 0xff
	err = munin.block_init(&b, bogus, false)
	testing.expect_value(t, err, munin.Error(munin.Corruption.Bad_Block))

	// Zero restart count is invalid for a non-empty block.
	zero := make([]byte, 12)
	defer delete(zero)
	err = munin.block_init(&b, zero, false)
	testing.expect_value(t, err, munin.Error(munin.Corruption.Bad_Block))
}

@(test)
test_block_reset_reuse :: proc(t: ^testing.T) {
	w: munin.Block_Writer
	munin.block_writer_init(&w, 8, false)
	defer munin.block_writer_destroy(&w)

	keys := gen_sorted_keys(100)
	defer free_keys(keys)

	for round in 0 ..< 3 {
		munin.block_writer_reset(&w)
		for k in keys {
			err := munin.block_writer_add(&w, k, nil)
			testing.expect_value(t, err, nil)
		}
		payload := munin.block_writer_finish(&w)
		b: munin.Block
		testing.expect_value(t, munin.block_init(&b, payload, false), nil)
		it: munin.Block_Iter
		munin.block_iter_init(&it, &b)
		defer munin.block_iter_destroy(&it)
		munin.block_iter_seek_first(&it)
		count := 0
		for it.valid {
			count += 1
			munin.block_iter_next(&it)
		}
		testing.expectf(t, count == len(keys), "round %d: %d != %d", round, count, len(keys))
	}
}
