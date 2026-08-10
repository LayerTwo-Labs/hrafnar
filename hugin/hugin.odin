// Hugin — Bitcoin block indexer built on Munin. Reads blk*.dat from a
// Bitcoin Core data directory and answers address balance and history
// queries.
package hugin

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

import munin "../munin"

// Corruption is damage in on-disk inputs or our own stores: bad framing in
// a blk file, a torn record in recent.log, a bad checkpoint.
Corruption :: enum {
	None,
	Bad_Magic,
	Bad_Checksum,
	Truncated,
	Bad_Header,
	Bad_Transaction,
	Bad_Record,
	Unknown_Outpoint, // spend referencing an output that does not exist
}

Usage_Error :: enum {
	None,
	Bad_Config,
	Bad_Address,
	Bad_Txid,
	Not_Synced,
	Reorg_Too_Deep, // fork below the horizon: refuse to serve, demand rebuild
	Rpc_Unavailable, // bitcoind's JSON-RPC did not answer (down, busy, or auth failed)
	Cancelled, // stop signal received mid-operation; every store is crash-safe
}

Error :: union {
	os.Error,
	munin.Error,
	Corruption,
	Usage_Error,
}

Network :: enum {
	Mainnet,
	Testnet3,
	Signet,
	Regtest,
	Ecash, // ecash-com/bitcoin: Bitcoin's rules and addresses, its own network magic
	Ecash_Signet, // default signet challenge only (magic is derived from the challenge)
	Ecash_Regtest,
}

// unit_label names the coin unit for human-readable output.
unit_label :: proc(n: Network) -> string {
	#partial switch n {
	case .Ecash, .Ecash_Signet, .Ecash_Regtest:
		return "ECX"
	}
	return "BTC"
}

// Magic bytes as they appear in the file, in file order.
network_magic :: proc(n: Network) -> [4]u8 {
	switch n {
	case .Mainnet:
		return {0xF9, 0xBE, 0xB4, 0xD9}
	case .Testnet3:
		return {0x0B, 0x11, 0x09, 0x07}
	case .Signet:
		return {0x0A, 0x03, 0xCF, 0x40}
	case .Regtest:
		return {0xFA, 0xBF, 0xB5, 0xDA}
	case .Ecash:
		return {0xEC, 0xA5, 0xD4, 0x04}
	case .Ecash_Signet:
		// SHA256d("ecash" + default challenge), first 4 bytes — matches
		// the fork's salted signet magic derivation. Custom challenges
		// would need a config key; unsupported until someone runs one.
		return {0xB3, 0x9E, 0x00, 0x26}
	case .Ecash_Regtest:
		return {0xEC, 0xA5, 0xD4, 0x34}
	}
	return {}
}

Config :: struct {
	datadir:     string, // Bitcoin Core blocks directory (contains blk*.dat)
	index_dir:   string, // where Hugin keeps headers.dat and the munin dbs
	work_dir:    string, // bulk-build scratch; empty = <index_dir>/work.
	// The build spills roughly 5x the history row volume here at peak;
	// pointing it at a separate disk halves the space one volume needs.
	network:     Network,
	bucket_bits: u32, // default 12
	horizon:     u32, // reorg horizon in blocks, default 100
	promote_batch: u32, // min blocks below the horizon before promoting, default 24
	workers:     int, // 0 = core count
	// Mempool tracking talks to bitcoind's JSON-RPC (the on-chain index
	// never does). Empty rpc_url means 127.0.0.1:8332; auth comes from
	// rpc_user/rpc_pass or, by default, the datadir's .cookie file.
	rpc_url:     string,
	rpc_cookie:  string,
	rpc_user:    string,
	rpc_pass:    string,
	mempool_off: bool, // disable the mempool tier entirely
	electrum:        bool, // serve the Electrum protocol
	electrum_bind:   string, // default 127.0.0.1:50001
	electrum_banner: string, // server.banner text, default "hrafnar <version>"
	electrum_max_history: int, // refuse scripthash queries above this many history rows; default 5000
	compact: bool, // compact index: 8-byte prefix keys, query-time verification (~3x smaller)
	esplora:      bool, // serve the esplora-compatible HTTP API
	esplora_bind: string, // default 127.0.0.1:3000
	query_workers: int, // threads executing queries; default half the cores (min 4)
}

config_fill_defaults :: proc(cfg: Config) -> (out: Config) {
	out = cfg
	if out.bucket_bits == 0 {out.bucket_bits = 12}
	if out.horizon == 0 {out.horizon = 100}
	if out.promote_batch == 0 {out.promote_batch = PROMOTE_BATCH_DEFAULT}
	if out.electrum_bind == "" {out.electrum_bind = "127.0.0.1:50001"}
	if out.electrum_max_history == 0 {out.electrum_max_history = 5000}
	if out.esplora_bind == "" {out.esplora_bind = "127.0.0.1:3000"}
	if out.query_workers == 0 {
		// Queries are short and I/O-bound; half the cores keeps plenty of
		// headroom for the indexing, mempool, and I/O threads.
		out.query_workers = max(4, os.get_processor_core_count() / 2)
	}
	return
}

// The FORMAT file records whether an index uses exact or compact rows.
// Absence means exact (pre-compact indexes). The file, not the config, is
// the source of truth once an index exists; a mismatch demands a rebuild.
FORMAT_FILE_NAME :: "FORMAT"

format_write :: proc(index_dir: string, compact: bool) -> (err: Error) {
	path := fmt.tprintf("%s/%s", index_dir, FORMAT_FILE_NAME)
	content := "compact\n" if compact else "exact\n"
	if werr := os.write_entire_file(path, transmute([]byte)content); werr != nil {
		return werr
	}
	return nil
}

format_read :: proc(index_dir: string) -> (compact: bool) {
	path := fmt.tprintf("%s/%s", index_dir, FORMAT_FILE_NAME)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return false // pre-FORMAT index: exact
	}
	return strings.trim_space(string(data)) == "compact"
}

// format_check errors loudly when the on-disk format disagrees with the
// configuration — serving would otherwise silently misread every row.
format_check :: proc(cfg: Config) -> (err: Error) {
	on_disk := format_read(cfg.index_dir)
	if on_disk != cfg.compact {
		log.errorf(
			"hugin: index at %s is %s but the config wants %s; rebuild the index or fix the config",
			cfg.index_dir,
			"compact" if on_disk else "exact",
			"compact" if cfg.compact else "exact",
		)
		return Usage_Error.Bad_Config
	}
	return nil
}
