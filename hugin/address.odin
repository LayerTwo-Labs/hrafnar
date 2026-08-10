package hugin

// Address parsing: base58check (P2PKH, P2SH) and bech32/bech32m (P2WPKH,
// P2WSH, P2TR), plus raw hex scripthash input. Produces the scriptPubKey,
// from which the scripthash is derived. Decode only — Hugin never needs to
// render an address to index it.

import "core:strings"

// address_to_scripthash accepts an address or a 64-hex-char scripthash and
// returns the scripthash to query.
address_to_scripthash :: proc(addr: string, network: Network) -> (sh: [32]u8, err: Error) {
	script_buf: [34]byte
	script := address_to_script(addr, network, script_buf[:]) or_return
	if script == nil {
		// Raw scripthash form.
		if len(addr) == 64 {
			ok: bool
			sh, ok = hex_decode_32(addr)
			if !ok {
				return {}, Usage_Error.Bad_Address
			}
			return sh, nil
		}
		return {}, Usage_Error.Bad_Address
	}
	return scripthash(script), nil
}

// address_to_script decodes an address into its scriptPubKey, written into
// buf (needs up to 34 bytes). Returns nil script with nil error when the
// input is not a recognizable address (caller may try raw-scripthash).
address_to_script :: proc(
	addr: string,
	network: Network,
	buf: []byte,
) -> (
	script: []byte,
	err: Error,
) {
	// bech32 first: unambiguous HRP prefix.
	hrp := bech32_hrp(network)
	if len(addr) > len(hrp) + 1 && strings.has_prefix(strings.to_lower(addr, context.temp_allocator), hrp) &&
	   (addr[len(hrp)] == '1') {
		ver, prog, ok := bech32_decode(addr, hrp)
		if !ok {
			return nil, Usage_Error.Bad_Address
		}
		switch {
		case ver == 0 && (len(prog) == 20 || len(prog) == 32):
			buf[0] = OP_0
			buf[1] = byte(len(prog))
			copy(buf[2:], prog)
			return buf[:2 + len(prog)], nil
		case ver >= 1 && ver <= 16 && len(prog) >= 2 && len(prog) <= 40:
			buf[0] = OP_1 + byte(ver) - 1
			buf[1] = byte(len(prog))
			copy(buf[2:], prog)
			return buf[:2 + len(prog)], nil
		}
		return nil, Usage_Error.Bad_Address
	}

	// base58check.
	payload: [21]byte
	if n, ok := base58check_decode(addr, payload[:]); ok && n == 21 {
		version := payload[0]
		p2pkh_ver, p2sh_ver := base58_versions(network)
		switch version {
		case p2pkh_ver:
			buf[0] = OP_DUP
			buf[1] = OP_HASH160
			buf[2] = 20
			copy(buf[3:23], payload[1:21])
			buf[23] = OP_EQUALVERIFY
			buf[24] = OP_CHECKSIG
			return buf[:25], nil
		case p2sh_ver:
			buf[0] = OP_HASH160
			buf[1] = 20
			copy(buf[2:22], payload[1:21])
			buf[22] = OP_EQUAL
			return buf[:23], nil
		}
		return nil, Usage_Error.Bad_Address
	}

	return nil, nil // not an address; caller may treat as raw scripthash
}

@(private = "file")
bech32_hrp :: proc(n: Network) -> string {
	switch n {
	case .Mainnet, .Ecash:
		return "bc"
	case .Testnet3, .Signet, .Ecash_Signet:
		return "tb"
	case .Regtest, .Ecash_Regtest:
		return "bcrt"
	}
	return "bc"
}

@(private = "file")
base58_versions :: proc(n: Network) -> (p2pkh, p2sh: byte) {
	switch n {
	case .Mainnet, .Ecash:
		return 0x00, 0x05
	case .Testnet3, .Signet, .Regtest, .Ecash_Signet, .Ecash_Regtest:
		return 0x6F, 0xC4
	}
	return 0x00, 0x05
}

// ---------------------------------------------------------------------------
// base58check

@(private = "file")
BASE58_ALPHABET :: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

// base58check_decode decodes into out, verifying the 4-byte double-SHA256
// checksum. Returns the payload length (excluding checksum).
base58check_decode :: proc(s: string, out: []byte) -> (n: int, ok: bool) {
	// Values table.
	val: [128]i8
	for &v in val {v = -1}
	for c, i in BASE58_ALPHABET {
		val[c] = i8(i)
	}

	// Big-integer decode, most significant first.
	full: [64]byte // enough for any address
	full_len := 0
	zeros := 0
	counting_zeros := true
	for c in s {
		if c >= 128 || val[c] < 0 {
			return 0, false
		}
		d := int(val[c])
		if counting_zeros {
			if d == 0 {
				zeros += 1
				continue
			}
			counting_zeros = false
		}
		// full = full * 58 + d
		carry := d
		for i := full_len - 1; i >= 0; i -= 1 {
			carry += int(full[i]) * 58
			full[i] = byte(carry & 0xFF)
			carry >>= 8
		}
		for carry > 0 {
			if full_len >= len(full) {
				return 0, false
			}
			copy(full[1:full_len + 1], full[:full_len])
			full[0] = byte(carry & 0xFF)
			full_len += 1
			carry >>= 8
		}
	}

	total := zeros + full_len
	if total < 4 || total > len(out) + 4 {
		return 0, false
	}
	decoded: [68]byte
	for i in 0 ..< zeros {decoded[i] = 0}
	copy(decoded[zeros:], full[:full_len])

	payload_len := total - 4
	check := sha256d(decoded[:payload_len])
	for i in 0 ..< 4 {
		if check[i] != decoded[payload_len + i] {
			return 0, false
		}
	}
	copy(out, decoded[:payload_len])
	return payload_len, true
}

// ---------------------------------------------------------------------------
// bech32 / bech32m

@(private = "file")
BECH32_CHARSET :: "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

@(private = "file")
BECH32M_CONST :: u32(0x2bc830a3)

@(private = "file")
bech32_polymod :: proc(values: []byte) -> u32 {
	GEN := [5]u32{0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3}
	chk := u32(1)
	for v in values {
		top := chk >> 25
		chk = (chk & 0x1ffffff) << 5 ~ u32(v)
		for i in 0 ..< 5 {
			if top >> uint(i) & 1 != 0 {
				chk ~= GEN[i]
			}
		}
	}
	return chk
}

// bech32_decode returns the witness version and program. Accepts bech32
// (v0) and bech32m (v1+), enforcing the right checksum for each.
bech32_decode :: proc(addr: string, expect_hrp: string) -> (ver: int, prog: []byte, ok: bool) {
	// Reject mixed case, lowercase for processing.
	has_lower, has_upper := false, false
	for c in addr {
		if c >= 'a' && c <= 'z' {has_lower = true}
		if c >= 'A' && c <= 'Z' {has_upper = true}
		if c < 33 || c > 126 {return 0, nil, false}
	}
	if has_lower && has_upper {
		return 0, nil, false
	}
	s := strings.to_lower(addr, context.temp_allocator)

	sep := strings.last_index_byte(s, '1')
	if sep < 1 || sep + 7 > len(s) || len(s) > 90 {
		return 0, nil, false
	}
	hrp := s[:sep]
	if hrp != expect_hrp {
		return 0, nil, false
	}
	data_str := s[sep + 1:]

	rev: [128]i8
	for &v in rev {v = -1}
	for c, i in BECH32_CHARSET {
		rev[c] = i8(i)
	}
	data := make([]byte, len(data_str), context.temp_allocator)
	for c, i in data_str {
		if c >= 128 || rev[c] < 0 {
			return 0, nil, false
		}
		data[i] = byte(rev[c])
	}

	// Checksum over expanded hrp + data.
	values := make([dynamic]byte, context.temp_allocator)
	for c in hrp {append(&values, byte(c) >> 5)}
	append(&values, 0)
	for c in hrp {append(&values, byte(c) & 31)}
	append(&values, ..data)
	pm := bech32_polymod(values[:])

	if len(data) < 7 {
		return 0, nil, false
	}
	ver = int(data[0])
	if ver > 16 {
		return 0, nil, false
	}
	want := u32(1) if ver == 0 else BECH32M_CONST
	if pm != want {
		return 0, nil, false
	}

	// Convert 5-bit groups (excluding version and 6-char checksum) to
	// 8-bit bytes; padding bits must be zero.
	payload := data[1:len(data) - 6]
	out := make([]byte, 40, context.temp_allocator)
	acc, bits, n := u32(0), u32(0), 0
	for v in payload {
		acc = acc << 5 | u32(v)
		bits += 5
		for bits >= 8 {
			bits -= 8
			if n >= len(out) {return 0, nil, false}
			out[n] = byte(acc >> bits)
			n += 1
		}
	}
	if bits >= 5 || acc & ((1 << bits) - 1) != 0 {
		return 0, nil, false
	}
	return ver, out[:n], true
}

// ---------------------------------------------------------------------------
// hex

hex_decode_32 :: proc(s: string) -> (out: [32]u8, ok: bool) {
	if len(s) != 64 {
		return {}, false
	}
	for i in 0 ..< 32 {
		hi := hex_val(s[i * 2])
		lo := hex_val(s[i * 2 + 1])
		if hi < 0 || lo < 0 {
			return {}, false
		}
		out[i] = byte(hi << 4 | lo)
	}
	return out, true
}

// txid_from_hex parses display hex (big-endian) into internal byte order
// (reversed).
txid_from_hex :: proc(s: string) -> (out: [32]u8, ok: bool) {
	h := hex_decode_32(s) or_return
	for i in 0 ..< 32 {
		out[i] = h[31 - i]
	}
	return out, true
}

// txid_to_hex renders internal byte order as display hex.
txid_to_hex :: proc(txid: [32]u8, buf: []byte) -> string {
	HEX := "0123456789abcdef"
	for i in 0 ..< 32 {
		b := txid[31 - i]
		buf[i * 2] = HEX[b >> 4]
		buf[i * 2 + 1] = HEX[b & 0xF]
	}
	return string(buf[:64])
}

@(private = "file")
hex_val :: proc "contextless" (c: byte) -> int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c - 'a' + 10)
	case c >= 'A' && c <= 'F':
		return int(c - 'A' + 10)
	}
	return -1
}

// ---------------------------------------------------------------------------
// Encoding (script -> address), for the esplora API's decoded outputs.

// script_to_address renders a standard scriptPubKey as an address, when
// one exists for its class.
script_to_address :: proc(script: []byte, network: Network, allocator := context.allocator) -> (addr: string, ok: bool) {
	class := script_classify(script)
	p2pkh_v, p2sh_v := base58_versions(network)
	#partial switch class {
	case .P2PKH:
		return base58check_encode(p2pkh_v, script[3:23], allocator), true
	case .P2SH:
		return base58check_encode(p2sh_v, script[2:22], allocator), true
	case .P2WPKH:
		return bech32_encode(bech32_hrp(network), 0, script[2:22], allocator), true
	case .P2WSH:
		return bech32_encode(bech32_hrp(network), 0, script[2:34], allocator), true
	case .P2TR:
		return bech32_encode(bech32_hrp(network), 1, script[2:34], allocator), true
	}
	return "", false
}

@(private = "file")
base58check_encode :: proc(version: byte, payload: []byte, allocator := context.allocator) -> string {
	data: [25]byte
	data[0] = version
	copy(data[1:], payload)
	check := sha256d(data[:21])
	copy(data[21:25], check[:4])

	// Big-number base conversion over 25 bytes.
	digits := make([dynamic]byte, 0, 40, context.temp_allocator)
	for b in data {
		carry := int(b)
		for &d in digits {
			carry += int(d) << 8
			d = byte(carry % 58)
			carry /= 58
		}
		for carry > 0 {
			append(&digits, byte(carry % 58))
			carry /= 58
		}
	}
	zeros := 0
	for b in data {
		if b != 0 {break}
		zeros += 1
	}
	ALPHA := BASE58_ALPHABET
	out := make([]byte, zeros + len(digits), allocator)
	for i in 0 ..< zeros {
		out[i] = '1'
	}
	for i in 0 ..< len(digits) {
		out[zeros + i] = ALPHA[digits[len(digits) - 1 - i]]
	}
	return string(out)
}

// bech32_encode encodes a segwit address: bech32 for v0, bech32m for v1+.
@(private = "file")
bech32_encode :: proc(hrp: string, witver: int, prog: []byte, allocator := context.allocator) -> string {
	// Convert program from 8-bit to 5-bit groups.
	data := make([dynamic]byte, 0, 1 + (len(prog) * 8 + 4) / 5, context.temp_allocator)
	append(&data, byte(witver))
	acc := 0
	bits := 0
	for b in prog {
		acc = acc << 8 | int(b)
		bits += 8
		for bits >= 5 {
			bits -= 5
			append(&data, byte(acc >> uint(bits) & 31))
		}
	}
	if bits > 0 {
		append(&data, byte(acc << uint(5 - bits) & 31))
	}

	// Checksum over expanded hrp + data.
	values := make([dynamic]byte, 0, len(hrp) * 2 + 1 + len(data) + 6, context.temp_allocator)
	for c in hrp {
		append(&values, byte(c) >> 5)
	}
	append(&values, 0)
	for c in hrp {
		append(&values, byte(c) & 31)
	}
	append(&values, ..data[:])
	for _ in 0 ..< 6 {
		append(&values, 0)
	}
	CONST_M :: 0x2bc830a3
	const_v: u32 = 1 if witver == 0 else CONST_M
	polymod := bech32_polymod(values[:]) ~ const_v

	CHARSET := BECH32_CHARSET
	out := make([dynamic]byte, 0, len(hrp) + 1 + len(data) + 6, allocator)
	append(&out, hrp)
	append(&out, '1')
	for d in data {
		append(&out, CHARSET[d])
	}
	for i in 0 ..< 6 {
		append(&out, CHARSET[polymod >> uint(5 * (5 - i)) & 31])
	}
	return string(out[:])
}
