package hugin_tests

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import hugin "../../hugin"

@(test)
test_config_file_load :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hrafnar_cfg_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	path := fmt.aprintf("%s/hrafnar.config", dir)
	defer delete(path)

	content := `; hrafnar.config — comments in both styles
# hash comments too
[hugin]
datadir     = /data/bitcoin/blocks
index       = "/data/hrafnar index"
network     = signet
workers     = 8
bucket_bits = 13
horizon     = 50

[ignored_section]
datadir = /wrong/place
`
	testing.expect_value(t, os.write_entire_file(path, content), nil)

	fc, err := hugin.config_file_load(path)
	testing.expect_value(t, err, nil)
	defer hugin.config_file_destroy(&fc)

	testing.expect_value(t, fc.datadir, "/data/bitcoin/blocks")
	testing.expect_value(t, fc.index_dir, "/data/hrafnar index") // quoted value
	testing.expect_value(t, fc.network, "signet")
	testing.expect_value(t, fc.workers, 8)
	testing.expect_value(t, fc.bucket_bits, 13)
	testing.expect_value(t, fc.horizon, 50)
}

@(test)
test_config_file_sectionless :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hrafnar_cfg_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	path := fmt.aprintf("%s/hrafnar.config", dir)
	defer delete(path)

	testing.expect_value(t, os.write_entire_file(path, "datadir = /a\nindex = /b\n"), nil)
	fc, err := hugin.config_file_load(path)
	testing.expect_value(t, err, nil)
	defer hugin.config_file_destroy(&fc)
	testing.expect_value(t, fc.datadir, "/a")
	testing.expect_value(t, fc.index_dir, "/b")
	testing.expect_value(t, fc.workers, -1) // unset stays -1
}

@(test)
test_config_file_rejects_bad_input :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hrafnar_cfg_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	path := fmt.aprintf("%s/hrafnar.config", dir)
	defer delete(path)

	// A typo'd key must fail loudly, not be silently ignored.
	testing.expect_value(t, os.write_entire_file(path, "datdir = /a\n"), nil)
	fc, err := hugin.config_file_load(path)
	hugin.config_file_destroy(&fc)
	testing.expect_value(t, err, hugin.Error(hugin.Usage_Error.Bad_Config))

	// A non-numeric numeric value must fail.
	testing.expect_value(t, os.write_entire_file(path, "workers = many\n"), nil)
	fc2, err2 := hugin.config_file_load(path)
	hugin.config_file_destroy(&fc2)
	testing.expect_value(t, err2, hugin.Error(hugin.Usage_Error.Bad_Config))

	// Missing file surfaces as an os error.
	_, err3 := hugin.config_file_load(fmt.tprintf("%s/nope.config", dir))
	testing.expect(t, err3 != nil, "missing file must error")
}

// The ecash fork (ecash-com/bitcoin) shifts every port +200 from Bitcoin's,
// so its RPC listens on 8532, not 8332. hrafnar advertised ecash network
// support while hardcoding Bitcoin's port, which surfaced as
// Rpc_Unavailable on every mempool cycle — indistinguishable from bad
// credentials, and the reason a real ecash node looked unreachable.
// Ports per the fork's src/chainparamsbase.cpp and README.
@(test)
test_rpc_default_port_per_network :: proc(t: ^testing.T) {
	cases := []struct {
		net:  hugin.Network,
		port: int,
	} {
		{.Mainnet, 8332},
		{.Testnet3, 18332},
		{.Signet, 38332},
		{.Regtest, 18443},
		{.Ecash, 8532},
		{.Ecash_Signet, 38532},
		{.Ecash_Regtest, 18643},
	}
	for c in cases {
		got := hugin.rpc_default_port(c.net)
		testing.expectf(t, got == c.port, "%v: default rpc port %d, want %d", c.net, got, c.port)
	}
}

// The shipped hrafnar.config.example must actually parse with every
// documented setting enabled.
//
// It did not. `core:encoding/ini` keeps everything after the '=', so
// `horizon = 100   ; reorg horizon` parsed as the value "100   ; reorg
// horizon" and the WHOLE FILE was rejected as malformed — while the example
// is written in that style throughout. Uncommenting any documented line made
// the daemon refuse to start with "unknown key or malformed value", naming
// no key.
//
// This reads the real example file rather than a copy, so the two cannot
// drift apart.
@(test)
test_shipped_config_example_parses_uncommented :: proc(t: ^testing.T) {
	// `odin test tests/hugin` runs from the repository root; the relative
	// path is tried too so the test also works if invoked from its own
	// directory.
	src, ok := os.read_entire_file("hrafnar.config.example", context.temp_allocator)
	if ok != nil {
		src, ok = os.read_entire_file("../../hrafnar.config.example", context.temp_allocator)
	}
	testing.expect(t, ok == nil, "cannot read hrafnar.config.example from repo root or ../../")
	if ok != nil {return}

	// Uncomment every line that is a commented-out `;key = value`, leaving
	// prose and section banners alone.
	b := strings.builder_make(context.temp_allocator)
	text := string(src)
	enabled := 0
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		out := line
		if strings.has_prefix(trimmed, ";") {
			rest := strings.trim_space(trimmed[1:])
			eq := strings.index_byte(rest, '=')
			if eq > 0 {
				key := strings.trim_space(rest[:eq])
				looks_like_key := len(key) > 0
				for c in key {
					if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || c == '-' || c >= '0' && c <= '9') {
						looks_like_key = false
						break
					}
				}
				if looks_like_key {
					out = rest
					enabled += 1
				}
			}
		}
		strings.write_string(&b, out)
		strings.write_byte(&b, '\n')
	}
	testing.expectf(t, enabled >= 10, "expected the example to document many settings, uncommented %d", enabled)

	dir, derr := os.make_directory_temp("", "hugin_cfgex_*", context.allocator)
	testing.expect_value(t, derr, nil)
	if derr != nil {return}
	defer {os.remove_all(dir); delete(dir)}
	path := fmt.tprintf("%s/hrafnar.config", dir)
	testing.expect_value(t, os.write_entire_file(path, transmute([]byte)strings.to_string(b)), nil)

	fc, err := hugin.config_file_load(path)
	defer hugin.config_file_destroy(&fc)
	testing.expectf(
		t,
		err == nil,
		"hrafnar.config.example does not parse with its %d documented settings enabled: %v",
		enabled,
		err,
	)
}

// `network = ecash` must frame blk records with the magic the real ECX
// node writes, not a retired test network's. hrafnar shipped drynet4's
// (ec a5 d4 04) under that name until the mainnet parameters landed in
// ecash-com/bitcoin's src/kernel/chainparams.cpp; against a real node
// that is Bad_Magic on the first blk file — loud, at least, but useless.
// Values here are copied from chainparams.cpp on master. Signet's is the
// first 4 bytes of SHA256d over the compactsize-serialized "ecash" plus
// the default challenge, which is how the fork salts it.
@(test)
test_ecash_network_magic :: proc(t: ^testing.T) {
	cases := []struct {
		net:  hugin.Network,
		want: [4]u8,
	} {
		{.Ecash, {0xEC, 0xA5, 0xDC, 0xB7}},
		{.Ecash_Signet, {0xB3, 0x9E, 0x00, 0x26}},
		{.Ecash_Regtest, {0xEC, 0xA5, 0xB1, 0x34}},
		// Bitcoin's, so an ecash index can never be mistaken for one.
		{.Mainnet, {0xF9, 0xBE, 0xB4, 0xD9}},
		{.Regtest, {0xFA, 0xBF, 0xB5, 0xDA}},
	}
	for c in cases {
		got := hugin.network_magic(c.net)
		testing.expectf(t, got == c.want, "%v: magic %v, want %v", c.net, got, c.want)
	}
}

// The fork's test networks (testnet3 ec a5 b1 14, testnet4 ec a5 b1 24)
// and any pre-launch respin differ from mainnet only in magic, so `magic`
// overrides it while `network` still supplies units, address handling and
// the RPC port — no hrafnar release per network.
@(test)
test_magic_override :: proc(t: ^testing.T) {
	// Parsing, including the forms a user will actually type.
	cases := []struct {
		text: string, // "in" is a keyword in Odin
		want: [4]u8,
		ok:   bool,
	} {
		{"eca5b114", {0xEC, 0xA5, 0xB1, 0x14}, true}, // ecash testnet3
		{"ECA5B124", {0xEC, 0xA5, 0xB1, 0x24}, true}, // ecash testnet4, uppercase
		{"0xeca5d404", {0xEC, 0xA5, 0xD4, 0x04}, true}, // retired drynet4, 0x prefix
		{"eca5a1", {}, false}, // too short
		{"eca5a1040", {}, false}, // too long
		{"eca5a1zz", {}, false}, // not hex
		{"", {}, false},
	}
	for c in cases {
		got, ok := hugin.magic_parse(c.text)
		testing.expectf(t, ok == c.ok, "magic_parse(%q) ok=%v, want %v", c.text, ok, c.ok)
		if c.ok {
			testing.expectf(t, got == c.want, "magic_parse(%q) = %v, want %v", c.text, got, c.want)
		}
	}

	// An override wins over the network's own magic; without one the
	// network's is used.
	alpha, _ := hugin.magic_parse("eca5b114")
	with_override := hugin.Config {
		network = .Ecash,
		magic   = alpha,
	}
	testing.expect_value(t, hugin.config_magic(with_override), alpha)

	plain := hugin.Config {
		network = .Ecash,
	}
	testing.expect_value(t, hugin.config_magic(plain), hugin.network_magic(.Ecash))
	testing.expectf(
		t,
		hugin.config_magic(plain) != alpha,
		"mainnet and testnet3 magic must differ, or this override is pointless",
	)
}

// An index must refuse to be opened against a different chain.
//
// The ecash networks share Bitcoin's address formats (and its history up
// to the fork height) and differ only in network magic, so pointing an
// ecash config at a Bitcoin index directory does not look obviously wrong
// — it would merge two chains' rows and serve balances that are quietly
// incorrect. The index records the magic it was built with and this check
// refuses a mismatch.
@(test)
test_index_refuses_a_different_chain :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_chain_*", context.allocator)
	testing.expect_value(t, derr, nil)
	if derr != nil {return}
	defer {os.remove_all(dir); delete(dir)}

	btc := hugin.Config {
		index_dir = dir,
		network   = .Mainnet,
	}
	ecash := hugin.Config {
		index_dir = dir,
		network   = .Ecash,
	}

	// No marker yet: an older index is adopted, not rejected.
	testing.expect_value(t, hugin.chain_id_check(ecash), nil)

	// Built as Bitcoin mainnet...
	testing.expect_value(t, hugin.chain_id_write(dir, hugin.config_magic(btc)), nil)
	testing.expect_value(t, hugin.chain_id_check(btc), nil)

	// ...must refuse an ecash config pointed at it.
	{
		ctx := context
		ctx.logger = log.nil_logger() // the check logs at error level
		context = ctx
		err := hugin.chain_id_check(ecash)
		testing.expectf(
			t,
			err == hugin.Usage_Error.Bad_Config,
			"opening a Bitcoin index with an ecash config returned %v, want Bad_Config",
			err,
		)
	}

	// And a retired drynet4 index (built under `network = ecash` when that
	// name carried drynet4's magic) vs today's mainnet `ecash` — same
	// network enum, different chain — must also be caught, which is the
	// case a `network` check alone would miss. This is the exact upgrade
	// path an operator hits after the mainnet magic landed.
	dry_magic, _ := hugin.magic_parse("eca5d404")
	dry := hugin.Config {
		index_dir = dir,
		network   = .Ecash,
		magic     = dry_magic,
	}
	testing.expect_value(t, hugin.chain_id_write(dir, hugin.config_magic(dry)), nil)
	{
		ctx := context
		ctx.logger = log.nil_logger()
		context = ctx
		testing.expectf(
			t,
			hugin.chain_id_check(ecash) == hugin.Usage_Error.Bad_Config,
			"a drynet4 index must not be opened with a mainnet ecash config",
		)
		// Pinning the old magic keeps the old index usable.
		testing.expect_value(t, hugin.chain_id_check(dry), nil)
	}
}
