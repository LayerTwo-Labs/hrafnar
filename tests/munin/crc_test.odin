package munin_tests

import "core:math/rand"
import "core:testing"

import munin "../../munin"

// Known-answer vectors, including the RFC 3720 (iSCSI) set. If these fail,
// nothing else in the format can be trusted.
@(test)
test_crc32c_vectors :: proc(t: ^testing.T) {
	testing.expect_value(t, munin.crc32c(nil), u32(0x00000000))
	testing.expect_value(t, munin.crc32c(transmute([]byte)string("a")), u32(0xC1D04330))
	testing.expect_value(t, munin.crc32c(transmute([]byte)string("123456789")), u32(0xE3069283))
	testing.expect_value(
		t,
		munin.crc32c(transmute([]byte)string("The quick brown fox jumps over the lazy dog")),
		u32(0x22620404),
	)

	zeros: [32]byte
	testing.expect_value(t, munin.crc32c(zeros[:]), u32(0x8A9136AA))

	ones: [32]byte
	for &b in ones {b = 0xFF}
	testing.expect_value(t, munin.crc32c(ones[:]), u32(0x62A8AB43))

	incr: [32]byte
	for &b, i in incr {b = byte(i)}
	testing.expect_value(t, munin.crc32c(incr[:]), u32(0x46DD794E))

	decr: [32]byte
	for &b, i in decr {b = byte(31 - i)}
	testing.expect_value(t, munin.crc32c(decr[:]), u32(0x113FDB5C))
}

@(test)
test_crc32c_update_split :: proc(t: ^testing.T) {
	data := make([]byte, 4096)
	defer delete(data)
	for &b in data {b = byte(rand.int_max(256))}

	whole := munin.crc32c(data)
	for _ in 0 ..< 100 {
		split := rand.int_max(len(data) + 1)
		part := munin.crc32c(data[:split])
		testing.expect_value(t, munin.crc32c_update(part, data[split:]), whole)
	}
}

// Unaligned starts must agree with a byte-at-a-time reference, exercising
// the slice-by-8 boundary handling.
@(test)
test_crc32c_unaligned :: proc(t: ^testing.T) {
	data := make([]byte, 257)
	defer delete(data)
	for &b, i in data {b = byte(i * 7 + 13)}

	for start in 0 ..< 16 {
		for length in 0 ..< 32 {
			if start + length > len(data) {continue}
			sub := data[start:start + length]
			fast := munin.crc32c(sub)
			ref := crc32c_reference(sub)
			testing.expectf(t, fast == ref, "start=%d len=%d: %08x != %08x", start, length, fast, ref)
		}
	}
}

@(private = "file")
crc32c_reference :: proc(data: []byte) -> u32 {
	POLY :: u32(0x82F63B78)
	crc := ~u32(0)
	for b in data {
		crc ~= u32(b)
		for _ in 0 ..< 8 {
			if crc & 1 != 0 {
				crc = crc >> 1 ~ POLY
			} else {
				crc >>= 1
			}
		}
	}
	return ~crc
}

// The hardware CRC32C path must agree with the table implementation at
// every length and alignment. A mismatch would look exactly like
// corruption — the one failure mode this engine refuses to have.
@(test)
test_crc32c_hw_matches_software :: proc(t: ^testing.T) {
	sizes := []int{0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 4096, 4097}
	for n in sizes {
		buf := make([]byte, n)
		defer delete(buf)
		for i in 0 ..< n {buf[i] = u8(rand.int31_max(256))}
		testing.expectf(
			t,
			munin.crc32c(buf) == munin.crc32c_reference(buf),
			"crc32c mismatch at length %d (path: %s)",
			n,
			munin.crc32c_accel_name(),
		)
	}
	for _ in 0 ..< 200 {
		n := int(rand.int31_max(9000))
		buf := make([]byte, n)
		defer delete(buf)
		for i in 0 ..< n {buf[i] = u8(rand.int31_max(256))}
		testing.expectf(t, munin.crc32c(buf) == munin.crc32c_reference(buf), "crc32c mismatch at length %d", n)
	}

	// Incremental updates must equal the one-shot value on both paths.
	data := make([]byte, 3000)
	defer delete(data)
	for i in 0 ..< len(data) {data[i] = u8(rand.int31_max(256))}
	part := munin.crc32c_update(0, data[:7])
	part = munin.crc32c_update(part, data[7:1001])
	part = munin.crc32c_update(part, data[1001:])
	testing.expect_value(t, part, munin.crc32c(data))
}
