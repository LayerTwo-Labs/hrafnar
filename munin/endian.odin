package munin

// Little-endian fixed-width helpers. All on-disk integers are LE unless a
// field is explicitly big-endian.
//
// These are UNALIGNED loads/stores of Odin's endian-specific types: one
// machine instruction (plus a byte swap on a big-endian host) rather than
// a shift-and-or chain. They sit on the block-decode path, so they run
// for every restart offset and every footer field the engine reads.

import "base:intrinsics"

@(private)
get_u32le :: proc "contextless" (buf: []byte) -> u32 {
	#no_bounds_check return u32(intrinsics.unaligned_load((^u32le)(&buf[0])))
}

@(private)
put_u32le :: proc "contextless" (buf: []byte, x: u32) {
	#no_bounds_check {
		intrinsics.unaligned_store((^u32le)(&buf[0]), u32le(x))
	}
}

@(private)
get_u64le :: proc "contextless" (buf: []byte) -> u64 {
	#no_bounds_check return u64(intrinsics.unaligned_load((^u64le)(&buf[0])))
}

@(private)
put_u64le :: proc "contextless" (buf: []byte, x: u64) {
	#no_bounds_check {
		intrinsics.unaligned_store((^u64le)(&buf[0]), u64le(x))
	}
}

@(private)
u16le_append :: proc(buf: ^[dynamic]byte, x: u16) {
	append(buf, byte(x), byte(x >> 8))
}

@(private)
get_u16le :: proc "contextless" (buf: []byte) -> u16 {
	#no_bounds_check return u16(intrinsics.unaligned_load((^u16le)(&buf[0])))
}
