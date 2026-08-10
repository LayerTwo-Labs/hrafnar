package munin_tests

import "core:math/rand"
import "core:testing"

import munin "../../munin"

@(test)
test_uvarint_round_trip_known :: proc(t: ^testing.T) {
	cases := []u64 {
		0,
		1,
		0x7f,
		0x80,
		0xff,
		300,
		16384,
		u64(max(u32)),
		u64(max(u32)) + 1,
		max(u64) - 1,
		max(u64),
	}
	buf: [munin.UVARINT_MAX_LEN]byte
	for x in cases {
		n := munin.uvarint_put(buf[:], x)
		testing.expect_value(t, n, munin.uvarint_len(x))
		got, m := munin.uvarint_get(buf[:n])
		testing.expectf(t, m == n, "decode len %d != encode len %d for %d", m, n, x)
		testing.expect_value(t, got, x)
	}
}

@(test)
test_uvarint_round_trip_random :: proc(t: ^testing.T) {
	buf: [munin.UVARINT_MAX_LEN]byte
	for _ in 0 ..< 100_000 {
		// Skew toward small values: mask by a random bit width.
		bits := rand.int_max(64) + 1
		x := rand.uint64() & (max(u64) >> uint(64 - bits))
		n := munin.uvarint_put(buf[:], x)
		got, m := munin.uvarint_get(buf[:n])
		testing.expect_value(t, m, n)
		testing.expect_value(t, got, x)
	}
}

@(test)
test_uvarint_append_matches_put :: proc(t: ^testing.T) {
	dyn := make([dynamic]byte)
	defer delete(dyn)
	buf: [munin.UVARINT_MAX_LEN]byte
	for _ in 0 ..< 1000 {
		x := rand.uint64()
		clear(&dyn)
		munin.uvarint_append(&dyn, x)
		n := munin.uvarint_put(buf[:], x)
		testing.expect_value(t, len(dyn), n)
		for b, i in dyn {
			testing.expect_value(t, b, buf[i])
		}
	}
}

@(test)
test_uvarint_truncated :: proc(t: ^testing.T) {
	buf: [munin.UVARINT_MAX_LEN]byte
	n := munin.uvarint_put(buf[:], max(u64))
	testing.expect_value(t, n, 10)
	for cut in 0 ..< n {
		_, m := munin.uvarint_get(buf[:cut])
		testing.expectf(t, m == 0, "truncated at %d should fail, got n=%d", cut, m)
	}
}

@(test)
test_uvarint_overflow_rejected :: proc(t: ^testing.T) {
	// 10 continuation-ish bytes: the 10th byte may only be 0 or 1.
	bad := [10]byte{0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02}
	_, n := munin.uvarint_get(bad[:])
	testing.expect_value(t, n, 0)

	// 11-byte overlong encoding of a small value.
	overlong := [11]byte{0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00}
	_, n = munin.uvarint_get(overlong[:])
	testing.expect_value(t, n, 0)
}

@(test)
test_bucket_of :: proc(t: ^testing.T) {
	key := [2]byte{0xAB, 0xCD}
	b, err := munin.bucket_of(key[:], 12)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, b, u32(0xABC))

	b, err = munin.bucket_of(key[:], 16)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, b, u32(0xABCD))

	b, err = munin.bucket_of(key[:], 8)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, b, u32(0xAB))

	b, err = munin.bucket_of(key[:1], 8)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, b, u32(0xAB))

	// Too short for 12 bits.
	_, err = munin.bucket_of(key[:1], 12)
	testing.expect_value(t, err, munin.Error(munin.Usage_Error.Key_Too_Short))
}
