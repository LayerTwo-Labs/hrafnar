package munin

// LEB128 unsigned varints. A u64 needs at most 10 bytes.

UVARINT_MAX_LEN :: 10

// uvarint_put encodes x into buf and returns the number of bytes written.
// buf must have room for UVARINT_MAX_LEN bytes in the worst case; too-small
// buffers are a caller bug and trip the bounds check.
uvarint_put :: proc(buf: []byte, x: u64) -> (n: int) {
	x := x
	for x >= 0x80 {
		buf[n] = byte(x) | 0x80
		x >>= 7
		n += 1
	}
	buf[n] = byte(x)
	return n + 1
}

// uvarint_append appends the encoding of x to a dynamic byte buffer.
uvarint_append :: proc(buf: ^[dynamic]byte, x: u64) {
	x := x
	for x >= 0x80 {
		append(buf, byte(x) | 0x80)
		x >>= 7
	}
	append(buf, byte(x))
}

// uvarint_get decodes a uvarint from buf. n == 0 means the buffer was
// truncated mid-varint or the value overflowed 64 bits; both are data
// corruption from the caller's point of view.
uvarint_get :: proc(buf: []byte) -> (x: u64, n: int) {
	shift: uint
	for b, i in buf {
		if i >= UVARINT_MAX_LEN {
			return 0, 0 // overlong encoding
		}
		if b < 0x80 {
			if i == UVARINT_MAX_LEN - 1 && b > 1 {
				return 0, 0 // overflows u64
			}
			return x | u64(b) << shift, i + 1
		}
		x |= u64(b & 0x7f) << shift
		shift += 7
	}
	return 0, 0 // truncated
}

// uvarint_len returns the encoded size of x without encoding it.
uvarint_len :: proc(x: u64) -> (n: int) {
	x := x
	for {
		n += 1
		x >>= 7
		if x == 0 {break}
	}
	return
}
