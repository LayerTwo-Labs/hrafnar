#+build !amd64
#+build !arm64
package munin

// Hardware CRC32C. Both x86-64 (SSE4.2) and arm64 carry an instruction
// for exactly this polynomial — roughly 10x the software table — and it
// is selected at RUNTIME so one binary still serves every CPU.


// No CRC32C instruction on this target: the table implementation stands.
crc32c_hw_available :: proc "contextless" () -> bool {
	return false
}

crc32c_update_hw :: proc "contextless" (crc: u32, data: []byte) -> u32 {
	return crc32c_update_sw(crc, data)
}
