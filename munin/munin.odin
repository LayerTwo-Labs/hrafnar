// Munin — embedded, bulk-load-oriented sorted-key storage engine.
// Opaque byte keys, immutable runs, merge-free ingest.
package munin

import "core:os"

// Corruption covers expected on-disk damage: bad magic, checksum mismatch,
// truncation. Never a panic — a corrupt file is a condition, not a bug.
Corruption :: enum {
	None,
	Bad_Magic,
	Bad_Checksum,
	Bad_Format_Version,
	Truncated,
	Missing_File,
	Size_Mismatch,
	Bad_Block,
}

// Usage_Error is a caller contract violation.
Usage_Error :: enum {
	None,
	Bad_Config,
	Key_Too_Short,
	Keys_Out_Of_Order,
	Wrong_Bucket,
	Bucket_Busy,
	Duplicate_Key,
	Iterator_Misuse,
	Ingest_Misuse,
}

Error :: union {
	os.Error,
	Corruption,
	Usage_Error,
}

Config :: struct {
	bucket_bits:         u32, // default 12
	block_size:          int, // default 4096
	restart_interval:    int, // default 16
	key_only:            bool,
	filter_prefix_len:   int, // 0 disables the filter
	filter_bits_per_key: int, // default 10
	cache_bytes:         int, // default 256 << 20
}

DEFAULT_CONFIG :: Config {
	bucket_bits         = 12,
	block_size          = 4096,
	restart_interval    = 16,
	key_only            = false,
	filter_prefix_len   = 0,
	filter_bits_per_key = 10,
	cache_bytes         = 256 << 20,
}

config_fill_defaults :: proc(cfg: Config) -> (out: Config) {
	out = cfg
	if out.bucket_bits == 0 {out.bucket_bits = 12}
	if out.block_size == 0 {out.block_size = 4096}
	if out.restart_interval == 0 {out.restart_interval = 16}
	if out.filter_bits_per_key == 0 {out.filter_bits_per_key = 10}
	if out.cache_bytes == 0 {out.cache_bytes = 256 << 20}
	return
}

config_validate :: proc(cfg: Config) -> Error {
	if cfg.bucket_bits < 1 || cfg.bucket_bits > 24 {return Usage_Error.Bad_Config}
	if cfg.block_size < 64 {return Usage_Error.Bad_Config}
	if cfg.restart_interval < 1 {return Usage_Error.Bad_Config}
	if cfg.filter_prefix_len < 0 {return Usage_Error.Bad_Config}
	if cfg.filter_bits_per_key < 0 {return Usage_Error.Bad_Config}
	return nil
}

// bucket_of returns the bucket for a key: the top bucket_bits bits of the
// key, read big-endian from byte 0.
bucket_of :: proc(key: []byte, bucket_bits: u32) -> (bucket: u32, err: Error) {
	min_len := int((bucket_bits + 7) / 8)
	if len(key) < min_len {
		return 0, Usage_Error.Key_Too_Short
	}
	acc: u32
	for i in 0 ..< min_len {
		acc = acc << 8 | u32(key[i])
	}
	// acc holds min_len*8 big-endian bits; shift off the excess.
	return acc >> (u32(min_len * 8) - bucket_bits), nil
}
