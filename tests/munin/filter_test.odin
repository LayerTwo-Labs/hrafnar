package munin_tests

import "core:math/rand"
import "core:testing"

import munin "../../munin"

// Build over N random 8-byte prefixes, then measure the false positive rate
// on prefixes known to be absent. At 10 bits/key and 7 probes the predicted
// rate is ~1%; if measurement diverges hard, the hashing is wrong.
@(test)
test_filter_false_positive_rate :: proc(t: ^testing.T) {
	N :: 100_000
	QUERIES :: 1_000_000
	BITS_PER_KEY :: 10

	fb: munin.Filter_Builder
	munin.filter_builder_init(&fb, 8, BITS_PER_KEY)
	defer munin.filter_builder_destroy(&fb)

	// Members: even 64-bit values, big-endian. Non-members: odd values.
	// Sorted order isn't required for correctness of add, only dedup.
	key: [8]byte
	for i in 0 ..< N {
		x := u64(i) * 2
		for j in 0 ..< 8 {key[j] = byte(x >> uint(56 - 8 * j))}
		munin.filter_builder_add(&fb, key[:])
	}
	payload := munin.filter_builder_finish(&fb)

	f: munin.Filter
	err := munin.filter_init(&f, payload)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, f.prefix_len, 8)

	// Zero false negatives, by definition of a bloom filter.
	for i in 0 ..< N {
		x := u64(i) * 2
		for j in 0 ..< 8 {key[j] = byte(x >> uint(56 - 8 * j))}
		testing.expect(t, munin.filter_may_contain_prefix(&f, key[:]), "false negative")
	}

	// Measure FPR on absent (odd) values.
	fp := 0
	for _ in 0 ..< QUERIES {
		x := rand.uint64() | 1
		for j in 0 ..< 8 {key[j] = byte(x >> uint(56 - 8 * j))}
		if munin.filter_may_contain_prefix(&f, key[:]) {
			fp += 1
		}
	}
	rate := f64(fp) / f64(QUERIES)
	// Predicted ~0.82% for k=7, m/n=10. Accept up to 2%.
	testing.expectf(t, rate < 0.02, "false positive rate %.4f too high", rate)
	testing.expectf(t, rate > 0.001, "false positive rate %.4f suspiciously low", rate)
}

@(test)
test_filter_dedup_adjacent :: proc(t: ^testing.T) {
	fb: munin.Filter_Builder
	munin.filter_builder_init(&fb, 4, 10)
	defer munin.filter_builder_destroy(&fb)

	// 1000 keys sharing one 4-byte prefix must count as one filter key.
	key: [8]byte
	key[0] = 0xAA
	for i in 0 ..< 1000 {
		key[6] = byte(i >> 8)
		key[7] = byte(i)
		munin.filter_builder_add(&fb, key[:])
	}
	testing.expect_value(t, len(fb.hashes), 1)

	payload := munin.filter_builder_finish(&fb)
	f: munin.Filter
	testing.expect_value(t, munin.filter_init(&f, payload), nil)
	testing.expect(t, munin.filter_check(&f, key[:]), "prefix must be present")
}

@(test)
test_filter_short_key :: proc(t: ^testing.T) {
	fb: munin.Filter_Builder
	munin.filter_builder_init(&fb, 32, 10)
	defer munin.filter_builder_destroy(&fb)

	short := [3]byte{1, 2, 3}
	munin.filter_builder_add(&fb, short[:])
	payload := munin.filter_builder_finish(&fb)

	f: munin.Filter
	testing.expect_value(t, munin.filter_init(&f, payload), nil)
	testing.expect(t, munin.filter_check(&f, short[:]), "short key must be found")
}

@(test)
test_filter_corrupt_header :: proc(t: ^testing.T) {
	f: munin.Filter
	tiny := [4]byte{}
	testing.expect_value(t, munin.filter_init(&f, tiny[:]), munin.Error(munin.Corruption.Bad_Block))

	// num_bits larger than the actual bit array.
	bad := [16]byte{}
	bad[0] = 8 // prefix_len
	bad[4] = 7 // probes
	bad[8] = 0xFF // num_bits = 255, but only 4 bytes of array
	bad[9] = 0x00
	testing.expect_value(t, munin.filter_init(&f, bad[:]), munin.Error(munin.Corruption.Bad_Block))
}
