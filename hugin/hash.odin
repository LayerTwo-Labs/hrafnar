package hugin

// Hashing helpers. Odin's core:crypto/sha2 dispatches to hardware SHA
// extensions where the target supports them; sha_accel_name reports which
// path is active so the operator can see it in the startup log.

import "core:crypto/sha2"

// sha256d is Bitcoin's double SHA-256.
sha256d :: proc (data: []byte) -> (out: [32]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, out[:])
	sha2.init_256(&ctx)
	sha2.update(&ctx, out[:])
	sha2.final(&ctx, out[:])
	return
}

// sha256d_2 hashes the concatenation of two byte slices, avoiding a copy
// for the txid path where the tx spans non-witness segments.
sha256d_parts :: proc (parts: [][]byte) -> (out: [32]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	for p in parts {
		sha2.update(&ctx, p)
	}
	sha2.final(&ctx, out[:])
	sha2.init_256(&ctx)
	sha2.update(&ctx, out[:])
	sha2.final(&ctx, out[:])
	return
}

// sha256 is the single hash, used for scripthash derivation.
sha256 :: proc (data: []byte) -> (out: [32]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, out[:])
	return
}

// sha_accel_name reports the SHA-256 implementation in use. Without
// hardware SHA, txid hashing is 3-5x slower and becomes a visible fraction
// of sync time; the startup log must say which path is active.
sha_accel_name :: proc "contextless" () -> string {
	if sha2.is_hardware_accelerated_256() {
		return "hardware (SHA extensions)"
	}
	return "software (no SHA extensions detected)"
}
