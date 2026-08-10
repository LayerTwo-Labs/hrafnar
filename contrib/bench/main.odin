package bench
// Micro-benchmarks for the hot paths, comparing each optimization against
// the implementation it replaced.
import "core:fmt"
import "core:math/rand"
import "core:simd"
import "core:time"
import munin "../../munin"
import hugin "../../hugin"

JOIN_KEY_LEN :: 36

// The original: byte-at-a-time, bounds-checked.
cmp_bytewise :: proc "contextless" (a, b: []byte) -> int {
	for i in 0 ..< JOIN_KEY_LEN {
		if a[i] != b[i] {return -1 if a[i] < b[i] else 1}
	}
	return 0
}

main :: proc() {
	// --- outpoint_compare: the merge join's inner loop ------------------
	// Realistic shape: keys that are EQUAL or share long prefixes, which
	// is what the join actually compares.
	N :: 2_000_000
	keys := make([]byte, N * JOIN_KEY_LEN); defer delete(keys)
	for i in 0 ..< N {
		row := keys[i * JOIN_KEY_LEN:]
		for j in 0 ..< 28 {row[j] = u8((i / 4) >> uint(j % 8))} // long shared prefixes
		for j in 28 ..< JOIN_KEY_LEN {row[j] = u8(rand.int31_max(256))}
	}
	acc := 0
	t0 := time.now()
	for i in 1 ..< N {
		acc += cmp_bytewise(keys[(i - 1) * JOIN_KEY_LEN:][:JOIN_KEY_LEN], keys[i * JOIN_KEY_LEN:][:JOIN_KEY_LEN])
	}
	d1 := time.duration_seconds(time.since(t0))
	t1 := time.now()
	for i in 1 ..< N {
		acc += hugin.outpoint_compare(keys[(i - 1) * JOIN_KEY_LEN:][:JOIN_KEY_LEN], keys[i * JOIN_KEY_LEN:][:JOIN_KEY_LEN])
	}
	d2 := time.duration_seconds(time.since(t1))
	if acc == 1 << 62 {fmt.println()}
	// Also compare against a hand-rolled shift-and-or reader, the thing
	// Odin's endian types replace.
	t1b := time.now()
	for i in 1 ..< N {
		a := keys[(i - 1) * JOIN_KEY_LEN:]
		b := keys[i * JOIN_KEY_LEN:]
		x := u64(a[0]) << 56 | u64(a[1]) << 48 | u64(a[2]) << 40 | u64(a[3]) << 32 | u64(a[4]) << 24 | u64(a[5]) << 16 | u64(a[6]) << 8 | u64(a[7])
		y := u64(b[0]) << 56 | u64(b[1]) << 48 | u64(b[2]) << 40 | u64(b[3]) << 32 | u64(b[4]) << 24 | u64(b[5]) << 16 | u64(b[6]) << 8 | u64(b[7])
		acc += 1 if x > y else 0
	}
	d2b := time.duration_seconds(time.since(t1b))

	fmt.printfln("outpoint_compare, %d long-prefix keys:", N)
	fmt.printfln("  byte-at-a-time : %6.3fs  (%6.1f M/s)", d1, f64(N) / d1 / 1e6)
	fmt.printfln("  8-byte chunks  : %6.3fs  (%6.1f M/s)   %.1fx faster", d2, f64(N) / d2 / 1e6, d1 / d2)
	fmt.printfln("  (shift-and-or reader, first 8 bytes only: %6.3fs)", d2b)

	// --- de-obfuscation + CRC ------------------------------------------
	SZ :: 2 << 20
	REPS :: 200
	src := make([]byte, SZ); defer delete(src)
	dst := make([]byte, SZ); defer delete(dst)
	for i in 0 ..< SZ {src[i] = u8(i * 7)}
	key: [8]u8 = {1, 2, 3, 4, 5, 6, 7, 8}
	gb := f64(SZ) * f64(REPS) / (1024 * 1024 * 1024)

	t2 := time.now()
	for _ in 0 ..< REPS {
		#no_bounds_check for b, i in src {dst[i] = b ~ key[(3 + i) & 7]}
	}
	d3 := time.duration_seconds(time.since(t2))
	t3 := time.now()
	for _ in 0 ..< REPS {hugin.blk_xor(dst, src, key, 3)}
	d4 := time.duration_seconds(time.since(t3))
	fmt.printfln("XOR de-obfuscation over %.1f GB:", gb)
	fmt.printfln("  scalar         : %6.3fs  (%5.2f GB/s)", d3, gb / d3)
	fmt.printfln("  simd           : %6.3fs  (%5.2f GB/s)   %.1fx faster", d4, gb / d4, d3 / d4)

	c: u32
	t4 := time.now()
	for _ in 0 ..< REPS {c ~= munin.crc32c_reference(src)}
	d5 := time.duration_seconds(time.since(t4))
	t5 := time.now()
	for _ in 0 ..< REPS {c ~= munin.crc32c(src)}
	d6 := time.duration_seconds(time.since(t5))
	if c == 0xDEADBEEF {fmt.println()}
	fmt.printfln("CRC32C over %.1f GB  [%s]:", gb, munin.crc32c_accel_name())
	fmt.printfln("  table          : %6.3fs  (%5.2f GB/s)", d5, gb / d5)
	fmt.printfln("  hardware       : %6.3fs  (%5.2f GB/s)   %.1fx faster", d6, gb / d6, d5 / d6)
}
