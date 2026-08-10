package munin

// CRC32C (Castagnoli, reflected polynomial 0x82F63B78). Every block on
// disk carries one, computed on write and verified on read in release
// builds too — so this runs over every byte the engine stores and every
// byte it reads back.
//
// Both x86-64 (SSE4.2) and arm64 have a CRC32C instruction for exactly
// this polynomial, roughly 10x the software table. Selection is at
// RUNTIME, like core:crypto/sha2's: one binary still serves every CPU,
// falling back to slice-by-8 where the instruction is absent.

@(private = "file")
crc32c_tables: [8][256]u32

@(private = "file")
crc32c_tables_built: bool

@(init)
crc32c_init :: proc "contextless" () {
	POLY :: u32(0x82F63B78)
	for i in 0 ..< 256 {
		crc := u32(i)
		for _ in 0 ..< 8 {
			if crc & 1 != 0 {
				crc = crc >> 1 ~ POLY
			} else {
				crc >>= 1
			}
		}
		crc32c_tables[0][i] = crc
	}
	for i in 0 ..< 256 {
		crc := crc32c_tables[0][i]
		for t in 1 ..< 8 {
			crc = crc32c_tables[0][crc & 0xff] ~ crc >> 8
			crc32c_tables[t][i] = crc
		}
	}
	crc32c_tables_built = true
}

// crc32c computes the CRC32C of data with the standard init/final XOR.
crc32c :: proc "contextless" (data: []byte) -> u32 {
	return crc32c_update(0, data)
}

// crc32c_update continues a CRC computation. crc is the finalized value of
// the preceding bytes (0 for none); returns the finalized value including
// data.
crc32c_update :: proc "contextless" (crc: u32, data: []byte) -> u32 {
	if crc32c_hw_available() {
		return crc32c_update_hw(crc, data)
	}
	return crc32c_update_sw(crc, data)
}

// crc32c_accel_name reports which path is active, for the startup log.
crc32c_accel_name :: proc "contextless" () -> string {
	return "hardware (CRC32C instruction)" if crc32c_hw_available() else "software (table)"
}

// crc32c_reference is the portable table implementation, exposed so tests
// can hold the hardware path to it.
crc32c_reference :: proc "contextless" (data: []byte) -> u32 {
	return crc32c_update_sw(0, data)
}

@(private = "file")
crc32c_update_sw :: proc "contextless" (crc: u32, data: []byte) -> u32 {
	c := ~crc
	data := data

	// Process 8 bytes at a time.
	for len(data) >= 8 {
		lo := u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
		hi := u32(data[4]) | u32(data[5]) << 8 | u32(data[6]) << 16 | u32(data[7]) << 24
		c ~= lo
		c =
			crc32c_tables[7][c & 0xff] ~
			crc32c_tables[6][c >> 8 & 0xff] ~
			crc32c_tables[5][c >> 16 & 0xff] ~
			crc32c_tables[4][c >> 24] ~
			crc32c_tables[3][hi & 0xff] ~
			crc32c_tables[2][hi >> 8 & 0xff] ~
			crc32c_tables[1][hi >> 16 & 0xff] ~
			crc32c_tables[0][hi >> 24]
		data = data[8:]
	}
	for b in data {
		c = crc32c_tables[0][(c ~ u32(b)) & 0xff] ~ c >> 8
	}
	return ~c
}
