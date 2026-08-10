#+build arm64
package munin

// Hardware CRC32C. Both x86-64 (SSE4.2) and arm64 carry an instruction
// for exactly this polynomial — roughly 10x the software table — and it
// is selected at RUNTIME so one binary still serves every CPU.


import "base:intrinsics"
import "core:sys/info"
import arm "core:simd/arm"

// Detected once, the same way core:crypto/sha2 picks its path.
@(private = "file")
have: bool

@(init)
crc32c_hw_detect :: proc "contextless" () {
	req :: info.CPU_Features{.crc32}
	have = info.cpu_features() >= req
}

crc32c_hw_available :: proc "contextless" () -> bool {
	return have
}

@(enable_target_feature = "crc")
crc32c_update_hw :: proc "contextless" (crc: u32, data: []byte) -> u32 {
	c := ~crc
	data := data
	for len(data) >= 8 {
		v := intrinsics.unaligned_load((^u64le)(raw_data(data)))
		c = arm.__crc32cd(c, u64(v))
		data = data[8:]
	}
	for b in data {
		c = arm.__crc32cb(c, b)
	}
	return ~c
}
