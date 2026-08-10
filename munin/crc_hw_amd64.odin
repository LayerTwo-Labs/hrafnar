#+build amd64
package munin

// Hardware CRC32C. Both x86-64 (SSE4.2) and arm64 carry an instruction
// for exactly this polynomial — roughly 10x the software table — and it
// is selected at RUNTIME so one binary still serves every CPU.


import "base:intrinsics"
import "core:sys/info"
import x86 "core:simd/x86"

// Detected once, the same way core:crypto/sha2 picks its path.
@(private = "file")
have: bool

@(init)
crc32c_hw_detect :: proc "contextless" () {
	req :: info.CPU_Features{.sse42}
	have = info.cpu_features() >= req
}

crc32c_hw_available :: proc "contextless" () -> bool {
	return have
}

@(enable_target_feature = "sse4.2")
crc32c_update_hw :: proc "contextless" (crc: u32, data: []byte) -> u32 {
	c := u64(~crc)
	data := data
	for len(data) >= 8 {
		v := intrinsics.unaligned_load((^u64le)(raw_data(data)))
		c = x86._mm_crc32_u64(c, u64(v))
		data = data[8:]
	}
	c32 := u32(c)
	for b in data {
		c32 = x86._mm_crc32_u8(c32, b)
	}
	return ~c32
}
