package hrafnar_cli

// hrafnar CLI: index, catchup, daemon, balance, history, tx, outpoint.
//
// The subcommand is dispatched by hand (core:flags has no subcommand
// concept); everything after it is parsed by core:flags into Options,
// UNIX style: --flag value or --flag=value.
//
// Queries go to a running daemon's socket when one is serving the index;
// otherwise they open the index directly. Both paths share the same
// request/response implementation in the hugin package.

import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import hugin "../../hugin"

VERSION :: "0.22.0 (2026-08-21.1)"

COMMANDS_USAGE :: `hrafnar — Bitcoin address indexer

usage:
  hrafnar index    [--datadir D --index I | --config F] [options]
  hrafnar catchup  [--datadir D --index I | --config F]
  hrafnar daemon   [--datadir D --index I | --config F] [--poll SECONDS] [--foreground]
  hrafnar stop     [--index I | --config F]
  hrafnar balance  <address|scripthash>
  hrafnar history  <address|scripthash> [--from H] [--limit N]
  hrafnar utxos    <address|scripthash>
  hrafnar tx       <txid> [--raw]
  hrafnar outpoint <txid>:<vout>
  hrafnar header   <height>
  hrafnar merkle   <txid>
  hrafnar feehist
  hrafnar tip
  hrafnar logs               (tail -f the daemon log, colorized)
  hrafnar version

`

// datadir/index are validated after merging with hrafnar.config rather
// than tagged `required`: core:flags only counts values set on the command
// line, and the config file may supply them.
Options :: struct {
	target:      string `args:"pos=0" usage:"address, scripthash, txid, or txid:vout"`,
	config:      string `usage:"path to hrafnar.config (default: ./hrafnar.config, then ~/.hrafnar/hrafnar.config)"`,
	datadir:     string `usage:"Bitcoin Core blocks directory (blk*.dat)"`,
	index:       string `usage:"Hrafnar index directory"`,
	work:        string `usage:"bulk-build scratch directory (default: <index>/work; put it on a second disk to split space needs)"`,
	network:     string `usage:"mainnet | testnet3 | signet | regtest (default mainnet)"`,
	workers:     int `usage:"worker threads (default: core count)"`,
	bucket_bits: uint `args:"name=bucket-bits" usage:"keyspace partition bits (default 12)"`,
	horizon:     uint `usage:"reorg horizon in blocks (default 100)"`,
	promote_batch: uint `usage:"blocks below the horizon before promoting (default 150)"`,
	magic:       string `usage:"network magic override, 8 hex digits (e.g. eca5a104)"`,
	max_height:  int `args:"name=max-height" usage:"index only up to this height (index only)"`,
	poll:        uint `usage:"daemon: catch-up interval in seconds (default 30)"`,
	foreground:  bool `usage:"daemon: stay attached to the terminal (default: detach into the background)"`,
	from:        uint `usage:"history: start height"`,
	limit:       int `usage:"history: max entries (default: all)"`,
	raw:         bool `usage:"tx: print raw hex"`,
	json:        bool `usage:"queries: machine-readable JSON output"`,
	verbose:     bool `usage:"debug logging"`,
}

main :: proc() {
	if len(os.args) < 2 {
		usage_exit(2)
	}
	command := os.args[1]
	needs_target: bool
	switch command {
	case "index", "catchup", "daemon", "stop", "tip", "feehist", "logs":
		needs_target = false
	case "version", "-v", "--version":
		fmt.printfln("hrafnar %s", VERSION)
		fmt.printfln("Copyright (c) 2026 LayerTwo Labs. MIT licensed.")
		os.exit(0)
	case "balance", "history", "utxos", "tx", "outpoint", "header", "merkle":
		needs_target = true
	case "-h", "--help", "help":
		usage_exit(0)
	case:
		fmt.eprintfln("unknown command: %s\n", command)
		usage_exit(2)
	}

	opt := Options {
		max_height = -1,
		limit      = -1,
		poll       = 30,
	}

	// hrafnar.config fills defaults first; command-line flags then override
	// whatever they explicitly set.
	config_path, config_found := prescan_config_path(os.args[2:])
	if !config_found {
		config_path, config_found = hugin.config_file_find()
	} else if _, serr := os.stat(config_path, context.temp_allocator); serr != nil {
		fmt.eprintfln("config file not found: %s", config_path)
		os.exit(2)
	}
	file_rpc_url, file_rpc_cookie, file_rpc_user, file_rpc_pass: string
	file_electrum_bind, file_electrum_banner: string
	file_mempool := -1
	file_electrum := -1
	file_electrum_max_history := -1
	file_compact := -1
	file_esplora := -1
	file_esplora_bind: string
	file_query_workers := -1
	if config_found {
		fc, cerr := hugin.config_file_load(config_path)
		if cerr != nil {
			fmt.eprintfln("bad config file %s: %v (unknown key or malformed value)", config_path, cerr)
			os.exit(2)
		}
		defer hugin.config_file_destroy(&fc)
		if fc.datadir != "" {opt.datadir = strings.clone(fc.datadir)}
		if fc.index_dir != "" {opt.index = strings.clone(fc.index_dir)}
		if fc.work_dir != "" {opt.work = strings.clone(fc.work_dir)}
		if fc.network != "" {opt.network = strings.clone(fc.network)}
		if fc.workers >= 0 {opt.workers = fc.workers}
		if fc.bucket_bits >= 0 {opt.bucket_bits = uint(fc.bucket_bits)}
		if fc.horizon >= 0 {opt.horizon = uint(fc.horizon)}
		if fc.promote_batch >= 0 {opt.promote_batch = uint(fc.promote_batch)}
		if fc.magic != "" && opt.magic == "" {opt.magic = fc.magic}
		if fc.rpc_url != "" {file_rpc_url = strings.clone(fc.rpc_url)}
		if fc.rpc_cookie != "" {file_rpc_cookie = strings.clone(fc.rpc_cookie)}
		if fc.rpc_user != "" {file_rpc_user = strings.clone(fc.rpc_user)}
		if fc.rpc_pass != "" {file_rpc_pass = strings.clone(fc.rpc_pass)}
		if fc.electrum_bind != "" {file_electrum_bind = strings.clone(fc.electrum_bind)}
		if fc.electrum_banner != "" {file_electrum_banner = strings.clone(fc.electrum_banner)}
		file_mempool = fc.mempool
		file_electrum = fc.electrum
		file_electrum_max_history = fc.electrum_max_history
		file_compact = fc.compact
		file_esplora = fc.esplora
		if fc.esplora_bind != "" {file_esplora_bind = strings.clone(fc.esplora_bind)}
		file_query_workers = fc.query_workers
	}

	if ferr := flags.parse(&opt, os.args[2:], .Unix); ferr != nil {
		if _, is_help := ferr.(flags.Help_Request); is_help {
			usage_exit(0)
		}
		flags.print_errors(Options, ferr, "hrafnar", .Unix)
		os.exit(2)
	}
	if needs_target && opt.target == "" {
		fmt.eprintfln("%s requires an argument", command)
		usage_exit(2)
	}
	if command == "stop" {
		if opt.index == "" {
			fmt.eprintfln("--index is required (via flags or %s)", hugin.CONFIG_FILE_NAME)
			usage_exit(2)
		}
	} else if opt.datadir == "" || opt.index == "" {
		fmt.eprintfln(
			"--datadir and --index are required (via flags or %s)",
			hugin.CONFIG_FILE_NAME,
		)
		usage_exit(2)
	}

	// Parsed here so a bad --magic fails before anything opens an index.
	cfg_magic: [4]u8
	if opt.magic != "" {
		m, mok := hugin.magic_parse(opt.magic)
		if !mok {
			fmt.eprintfln("bad --magic %q: want 8 hex digits, e.g. eca5a104", opt.magic)
			os.exit(2)
		}
		cfg_magic = m
	}

	cfg := hugin.Config {
		datadir     = opt.datadir,
		index_dir   = opt.index,
		work_dir    = opt.work,
		bucket_bits = u32(opt.bucket_bits),
		horizon     = u32(opt.horizon),
		promote_batch = u32(opt.promote_batch),
		magic       = cfg_magic,
		workers     = opt.workers,
	}
	cfg.rpc_url = file_rpc_url
	cfg.rpc_cookie = file_rpc_cookie
	cfg.rpc_user = file_rpc_user
	cfg.rpc_pass = file_rpc_pass
	cfg.mempool_off = file_mempool == 0
	// Electrum serving is on by default (localhost:50001); the config can
	// switch it off with `electrum = off`.
	cfg.electrum = file_electrum != 0
	cfg.electrum_bind = file_electrum_bind
	cfg.electrum_banner = file_electrum_banner
	if file_electrum_max_history >= 0 {
		cfg.electrum_max_history = file_electrum_max_history
	}
	cfg.compact = file_compact == 1
	cfg.esplora = file_esplora == 1
	cfg.esplora_bind = file_esplora_bind
	if file_query_workers > 0 {
		cfg.query_workers = file_query_workers
	}
	switch opt.network {
	case "", "mainnet":
		cfg.network = .Mainnet
	case "testnet3", "testnet":
		cfg.network = .Testnet3
	case "signet":
		cfg.network = .Signet
	case "regtest":
		cfg.network = .Regtest
	case "ecash":
		cfg.network = .Ecash
	case "ecash-signet", "ecash_signet":
		cfg.network = .Ecash_Signet
	case "ecash-regtest", "ecash_regtest":
		cfg.network = .Ecash_Regtest
	case:
		fmt.eprintfln("unknown network: %s", opt.network)
		os.exit(2)
	}

	// The daemon detaches by default: the parent reports where the child
	// went and returns the prompt; the child runs indefinitely (it never
	// exits on reaching the tip — it keeps polling) with stdio pointed at
	// /dev/null, so the file logger is its only voice. --foreground keeps
	// it attached, for systemd or watching directly.
	detached := false
	if command == "daemon" && !opt.foreground {
		// The child redirects its output into the index dir; make sure it
		// exists before forking (first run on a fresh dir).
		_ = os.make_directory_all(cfg.index_dir)
		child, derr := hugin.daemonize(cfg.index_dir)
		detached = true
		if derr != nil {
			fmt.eprintfln("could not daemonize: %v", derr)
			os.exit(1)
		}
		if child > 0 {
			fmt.printfln("hrafnar daemon started (pid %d)", child)
			fmt.println("logs:  hrafnar logs")
			fmt.println("stop:  hrafnar stop")
			os.exit(0)
		}
	}

	// Console logger; plus a file logger in the index directory. The
	// context assignment must happen at THIS scope: `context.logger = x`
	// inside a block reverts at the block's closing brace.
	lowest := log.Level.Debug if opt.verbose else log.Level.Info
	// A detached daemon has stderr pointed at <index>/hrafnar.err, which
	// exists to capture crash traces — a panic's dying words. Installing
	// the console logger there too would duplicate the whole log into it;
	// the child logs to the file only, leaving .err empty unless it dies.
	console: log.Logger
	logger: log.Logger
	if !detached {
		console = flushing_file_logger(os.stderr, lowest, colored = true)
		logger = console
	}

	file_handle: ^os.File
	_ = os.make_directory_all(cfg.index_dir)
	log_path := fmt.tprintf("%s/hrafnar.log", cfg.index_dir)
	// Startup rotation: past the size cap the old log rolls to .1 (which
	// is replaced), so the pair is bounded at ~2x the cap. At the quiet
	// steady-state log rate this triggers every few years; logrotate with
	// copytruncate covers daemons that never restart (see README).
	LOG_ROTATE_BYTES :: 50 << 20
	if info, serr := os.stat(log_path, context.temp_allocator); serr == nil && info.size > LOG_ROTATE_BYTES {
		old_path := fmt.tprintf("%s/hrafnar.log.1", cfg.index_dir)
		os.remove(old_path)
		if rerr := os.rename(log_path, old_path); rerr == nil {
			fmt.printfln("rotated %s (%dMB) to hrafnar.log.1", log_path, info.size >> 20)
		}
	}
	if f, ferr := os.open(log_path, {.Write, .Create, .Append}, os.Permissions_Read_All + {.Write_User}); ferr == nil {
		file_handle = f
		file_logger := flushing_file_logger(f, lowest)
		logger = file_logger if detached else log.create_multi_logger(console, file_logger)
	} else {
		fmt.eprintfln("warning: cannot open %s for logging: %v", log_path, ferr)
	}
	defer if file_handle != nil {os.close(file_handle)}
	context.logger = logger

	if command == "daemon" {
		log.infof("hrafnar %s", VERSION)
	}
	err := run(command, &opt, cfg)
	if err != nil {
		log.errorf("hrafnar: %s failed: %v", command, err)
		os.exit(1)
	}
}

run :: proc(command: string, opt: ^Options, cfg: hugin.Config) -> hugin.Error {
	switch command {
	case "index":
		hugin.build_index(cfg, opt.max_height) or_return
		// Fill the recent tier with the top-of-chain blocks.
		return hugin.catchup_run(cfg)
	case "catchup":
		return hugin.catchup_run(cfg)
	case "daemon":
		return hugin.daemon_run(cfg, int(opt.poll), fmt.tprintf("hrafnar %s", VERSION))
	case "stop":
		return hugin.daemon_stop(cfg.index_dir)
	case "tip":
		return dispatch_query("json tip" if opt.json else "tip", cfg)
	case "feehist":
		return dispatch_query("json feehist" if opt.json else "feehist", cfg)
	case "logs":
		return follow_log(cfg.index_dir)
	case "balance", "history", "utxos", "tx", "outpoint", "header", "merkle":
		request := build_request(command, opt, cfg) or_return
		if opt.json {
			request = fmt.tprintf("json %s", request)
		}
		return dispatch_query(request, cfg)
	}
	return hugin.Usage_Error.Bad_Config
}

// build_request turns parsed CLI arguments into a protocol request line.
// Address and txid parsing happen client-side.
build_request :: proc(
	command: string,
	opt: ^Options,
	cfg: hugin.Config,
) -> (
	request: string,
	err: hugin.Error,
) {
	hexbuf: [64]byte
	switch command {
	case "balance":
		sh := hugin.address_to_scripthash(opt.target, cfg.network) or_return
		return fmt.tprintf("balance %s", hex_of(sh, hexbuf[:])), nil
	case "history":
		sh := hugin.address_to_scripthash(opt.target, cfg.network) or_return
		return fmt.tprintf("history %s %d %d", hex_of(sh, hexbuf[:]), opt.from, opt.limit), nil
	case "utxos":
		sh := hugin.address_to_scripthash(opt.target, cfg.network) or_return
		return fmt.tprintf("utxos %s", hex_of(sh, hexbuf[:])), nil
	case "header":
		if _, hok := strconv.parse_uint(opt.target, 10); !hok {
			fmt.eprintfln("header takes a block height, got: %s", opt.target)
			return "", hugin.Usage_Error.Bad_Config
		}
		return fmt.tprintf("header %s", opt.target), nil
	case "tx":
		txid, ok := hugin.txid_from_hex(opt.target)
		if !ok {
			return "", hugin.Usage_Error.Bad_Txid
		}
		return fmt.tprintf("tx %s %s", hex_of(txid, hexbuf[:]), "1" if opt.raw else "0"), nil
	case "merkle":
		txid, ok := hugin.txid_from_hex(opt.target)
		if !ok {
			return "", hugin.Usage_Error.Bad_Txid
		}
		return fmt.tprintf("merkle %s", hex_of(txid, hexbuf[:])), nil
	case "outpoint":
		colon := strings.last_index_byte(opt.target, ':')
		if colon < 0 {
			return "", hugin.Usage_Error.Bad_Txid
		}
		txid, ok := hugin.txid_from_hex(opt.target[:colon])
		if !ok {
			return "", hugin.Usage_Error.Bad_Txid
		}
		vout, vok := strconv.parse_uint(opt.target[colon + 1:], 10)
		if !vok {
			return "", hugin.Usage_Error.Bad_Txid
		}
		return fmt.tprintf("outpoint %s %d", hex_of(txid, hexbuf[:]), vout), nil
	}
	return "", hugin.Usage_Error.Bad_Config
}

// dispatch_query prefers a running daemon's socket; otherwise it opens the
// index directly. Same serve_request either way.
dispatch_query :: proc(request: string, cfg: hugin.Config) -> hugin.Error {
	response, from_daemon := hugin.daemon_query(cfg.index_dir, request, context.temp_allocator)
	if !from_daemon {
		idx := hugin.index_open(cfg) or_return
		defer hugin.index_close(idx)
		response = hugin.serve_request(idx, nil, request, context.temp_allocator)
	}
	return print_response(response)
}

print_response :: proc(response: string) -> hugin.Error {
	if strings.has_prefix(response, "OK\n") {
		fmt.print(response[3:])
		return nil
	}
	if strings.has_prefix(response, "ERR ") {
		fmt.eprint(strings.trim_prefix(response, "ERR "))
		return hugin.Usage_Error.Bad_Config
	}
	fmt.eprintfln("malformed response: %q", response)
	return hugin.Usage_Error.Bad_Config
}

// hex_of renders 32 bytes as plain hex. The wire carries internal byte
// order; txids were already reversed by txid_from_hex.
hex_of :: proc(h: [32]u8, buf: []byte) -> string {
	HEXD := "0123456789abcdef"
	for b, i in h {
		buf[i * 2] = HEXD[b >> 4]
		buf[i * 2 + 1] = HEXD[b & 0xF]
	}
	return string(buf[:64])
}

// prescan_config_path finds --config before the full parse, since the
// config file must load first for flags to override it.
prescan_config_path :: proc(args: []string) -> (path: string, found: bool) {
	for arg, i in args {
		if arg == "--config" || arg == "-config" {
			if i + 1 < len(args) {
				return args[i + 1], true
			}
			return "", false
		}
		if strings.has_prefix(arg, "--config=") {
			return strings.trim_prefix(arg, "--config="), true
		}
	}
	return "", false
}

// flushing_file_logger writes and FLUSHES every line: core:os files are
// buffered, and a detached daemon that buffers its log looks dead to the
// operator (and loses the tail on a crash). The file is plain text —
// `hrafnar logs` adds the colors at view time.
Flushing_Logger_Data :: struct {
	f:       ^os.File,
	colored: bool,
}

flushing_file_logger :: proc(f: ^os.File, lowest: log.Level, colored := false) -> log.Logger {
	data := new(Flushing_Logger_Data)
	data.f = f
	data.colored = colored
	return log.Logger{flushing_logger_proc, data, lowest, log.Options{.Level, .Time, .Short_File_Path, .Line}}
}

// DIM date/location frame the line; the level tag carries the color:
// DEBUG dim, INFO green, WARN yellow, ERROR red, FATAL bold-on-red.
@(rodata)
LOG_LEVEL_TAG := [?]string {
	"\x1b[2mDEBUG\x1b[0m",
	"\x1b[32mINFO \x1b[0m",
	"\x1b[33mWARN \x1b[0m",
	"\x1b[31mERROR\x1b[0m",
	"\x1b[1;41mFATAL\x1b[0m",
}

@(rodata)
LOG_LEVEL_TAG_PLAIN := [?]string{"DEBUG", "INFO ", "WARN ", "ERROR", "FATAL"}

flushing_logger_proc :: proc(data_ptr: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	data := cast(^Flushing_Logger_Data)data_ptr
	tags := LOG_LEVEL_TAG[:] if data.colored else LOG_LEVEL_TAG_PLAIN[:]
	lvl := tags[1]
	#partial switch level {
	case .Debug:
		lvl = tags[0]
	case .Info:
		lvl = tags[1]
	case .Warning:
		lvl = tags[2]
	case .Error:
		lvl = tags[3]
	case .Fatal:
		lvl = tags[4]
	}
	now := time.now()
	h, m, s := time.clock_from_time(now)
	_, month, day := time.date(now)
	// file:line only where someone will diagnose from it; INFO reads as a
	// clean operational narrative.
	DIM := "\x1b[2m" if data.colored else ""
	RST := "\x1b[0m" if data.colored else ""
	line: string
	if level >= .Warning {
		file := location.file_path
		if i := strings.last_index_byte(file, '/'); i >= 0 {
			file = file[i + 1:]
		}
		line = fmt.tprintfln(
			"%s%02d-%02d %02d:%02d:%02d%s %s %s%s:%d%s %s",
			DIM,
			int(month),
			day,
			h,
			m,
			s,
			RST,
			lvl,
			DIM,
			file,
			location.line,
			RST,
			text,
		)
	} else {
		line = fmt.tprintfln(
			"%s%02d-%02d %02d:%02d:%02d%s %s %s",
			DIM,
			int(month),
			day,
			h,
			m,
			s,
			RST,
			lvl,
			text,
		)
	}
	buf := transmute([]byte)line
	for len(buf) > 0 {
		n, werr := os.write(data.f, buf)
		if werr != nil || n <= 0 {
			return
		}
		buf = buf[n:]
	}
	os.flush(data.f)
}

// follow_log is `tail -f` with the level colors the on-disk log
// deliberately lacks (the file stays clean for vi/grep). Ctrl-C exits.
follow_log :: proc(index_dir: string) -> hugin.Error {
	path := fmt.tprintf("%s/hrafnar.log", index_dir)
	f, ferr := os.open(path)
	if ferr != nil {
		fmt.eprintfln("cannot open %s: %v", path, ferr)
		return hugin.Usage_Error.Bad_Config
	}
	defer os.close(f)

	// Start ~4KB from the end: recent context, then follow.
	if info, serr := os.fstat(f, context.temp_allocator); serr == nil && info.size > 4096 {
		os.seek(f, info.size - 4096, .Start)
		// Skip the likely-partial first line.
		skip: [1]byte
		for {
			n, rerr := os.read(f, skip[:])
			if rerr != nil || n == 0 || skip[0] == '\n' {break}
		}
	}

	buf: [16384]byte
	pending := make([dynamic]byte)
	defer delete(pending)
	for {
		n, rerr := os.read(f, buf[:])
		if n > 0 {
			append(&pending, ..buf[:n])
			for {
				nl := -1
				for b, i in pending {
					if b == '\n' {nl = i; break}
				}
				if nl < 0 {break}
				print_colorized(string(pending[:nl]))
				rest := len(pending) - (nl + 1)
				copy(pending[:rest], pending[nl + 1:])
				resize(&pending, rest)
			}
		}
		if rerr != nil || n == 0 {
			time.sleep(250 * time.Millisecond)
		}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
print_colorized :: proc(line: string) {
	Tag :: struct {
		plain, colored: string,
	}
	@(static, rodata)
	TAGS := [?]Tag {
		{" INFO ", " \x1b[32mINFO \x1b[0m "},
		{" WARN ", " \x1b[33mWARN \x1b[0m "},
		{" ERROR ", " \x1b[31mERROR\x1b[0m "},
		{" FATAL ", " \x1b[1;41mFATAL\x1b[0m "},
		{" DEBUG ", " \x1b[2mDEBUG\x1b[0m "},
	}
	for &t in TAGS {
		if i := strings.index(line, t.plain); i >= 0 {
			// Timestamp dimmed, tag colored, message untouched.
			fmt.printfln("\x1b[2m%s\x1b[0m%s%s", line[:i], t.colored, line[i + len(t.plain):])
			return
		}
	}
	fmt.println(line)
}

usage_exit :: proc(code: int) -> ! {
	out := os.to_writer(os.stderr if code != 0 else os.stdout)
	fmt.wprint(out, COMMANDS_USAGE)
	flags.write_usage(out, Options, "hrafnar <command>", .Unix)
	os.exit(code)
}
