package hugin

// hrafnar.config: INI-style configuration file.
//
//   ; hrafnar.config
//   [hugin]
//   datadir     = /home/user/.bitcoin/blocks
//   index       = /home/user/.hrafnar/mainnet
//   network     = mainnet
//   workers     = 8
//   bucket_bits = 12
//   horizon     = 100
//   promote_batch = 150
//
// Keys may live in the global (sectionless) scope or under [hugin]; other
// sections are ignored. Comments start with ';' or '#'. Values may be
// quoted. Command-line flags always override the file.
//
// Search order: an explicit --config path, then ./hrafnar.config, then
// $HOME/.hrafnar/hrafnar.config.

import "base:runtime"
import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

CONFIG_FILE_NAME :: "hrafnar.config"

// File_Config holds raw values from hrafnar.config. Strings are owned;
// empty means unset. Numeric fields are -1 when unset.
File_Config :: struct {
	datadir:     string,
	index_dir:   string,
	work_dir:    string,
	network:     string,
	rpc_url:     string,
	rpc_cookie:  string,
	rpc_user:    string,
	rpc_pass:    string,
	mempool:     int, // -1 unset, 0 off, 1 on
	electrum:    int, // -1 unset, 0 off, 1 on
	electrum_bind:   string,
	electrum_banner: string,
	electrum_max_history: int,
	compact:     int, // -1 unset, 0 off, 1 on
	esplora:     int, // -1 unset, 0 off, 1 on
	esplora_bind: string,
	query_workers: int,
	workers:     int,
	bucket_bits: int,
	horizon:     int,
	promote_batch: int,
	allocator:   runtime.Allocator,
}

config_file_destroy :: proc(fc: ^File_Config) {
	delete(fc.datadir, fc.allocator)
	delete(fc.index_dir, fc.allocator)
	delete(fc.work_dir, fc.allocator)
	delete(fc.network, fc.allocator)
	delete(fc.rpc_url, fc.allocator)
	delete(fc.rpc_cookie, fc.allocator)
	delete(fc.rpc_user, fc.allocator)
	delete(fc.rpc_pass, fc.allocator)
	delete(fc.electrum_bind, fc.allocator)
	delete(fc.electrum_banner, fc.allocator)
	delete(fc.esplora_bind, fc.allocator)
}

// config_file_find returns the first existing config file from the search
// order (excluding any explicit --config, which the caller handles).
// The returned path is temp-allocated.
config_file_find :: proc() -> (path: string, found: bool) {
	if _, err := os.stat(CONFIG_FILE_NAME, context.temp_allocator); err == nil {
		return CONFIG_FILE_NAME, true
	}
	home, hfound := os.lookup_env("HOME", context.temp_allocator)
	if hfound && home != "" {
		p := fmt.tprintf("%s/.hrafnar/%s", home, CONFIG_FILE_NAME)
		if _, err := os.stat(p, context.temp_allocator); err == nil {
			return p, true
		}
	}
	return "", false
}

// config_file_load parses one hrafnar.config. Unknown keys are rejected
// loudly — a typo like `datdir` silently ignored would cost someone an
// evening.
config_file_load :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	fc: File_Config,
	err: Error,
) {
	fc.workers = -1
	fc.bucket_bits = -1
	fc.horizon = -1
	fc.promote_batch = -1
	fc.mempool = -1
	fc.electrum = -1
	fc.electrum_max_history = -1
	fc.compact = -1
	fc.esplora = -1
	fc.query_workers = -1
	fc.allocator = allocator

	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return fc, rerr
	}

	// core:encoding/ini supports a single comment prefix (';'); strip
	// '#'-comment lines first so both styles work.
	cleaned := strings.builder_make(context.temp_allocator)
	src := string(data)
	for line in strings.split_lines_iterator(&src) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "#") {
			continue
		}
		// Strip inline comments. core:encoding/ini keeps everything after
		// the '=', so `horizon = 100   ; reorg horizon` parsed as the value
		// "100   ; reorg horizon" and the whole file was rejected as
		// malformed — while hrafnar.config.example is written in exactly
		// that style throughout. Uncommenting any documented line made the
		// daemon refuse to start.
		//
		// Only a ';' or '#' PRECEDED BY WHITESPACE starts a comment, so a
		// value containing one (a banner, a password) survives. A line that
		// begins with ';' is a commented-out setting and is left alone.
		out := line
		if !strings.has_prefix(trimmed, ";") {
			for i in 1 ..< len(out) {
				if (out[i] == ';' || out[i] == '#') && (out[i - 1] == ' ' || out[i - 1] == '\t') {
					out = out[:i]
					break
				}
			}
		}
		strings.write_string(&cleaned, out)
		strings.write_byte(&cleaned, '\n')
	}

	it := ini.iterator_from_string(strings.to_string(cleaned))
	for key, raw_value in ini.iterate(&it) {
		section := strings.trim_space(it.section)
		if !(section == "" || strings.equal_fold(section, "hugin") || strings.equal_fold(section, "hrafnar")) {
			continue
		}
		value := strings.trim_space(raw_value)
		if len(value) >= 2 && (value[0] == '"' || value[0] == '\'') {
			if unquoted, _, uok := strconv.unquote_string(value, context.temp_allocator); uok {
				value = unquoted
			}
		}

		switch strings.trim_space(key) {
		case "datadir":
			set_config_string(&fc.datadir, value, allocator) or_return
		case "index":
			set_config_string(&fc.index_dir, value, allocator) or_return
		case "work":
			set_config_string(&fc.work_dir, value, allocator) or_return
		case "rpc":
			set_config_string(&fc.rpc_url, value, allocator) or_return
		case "rpc_cookie":
			set_config_string(&fc.rpc_cookie, value, allocator) or_return
		case "rpc_user":
			set_config_string(&fc.rpc_user, value, allocator) or_return
		case "rpc_pass":
			set_config_string(&fc.rpc_pass, value, allocator) or_return
		case "mempool":
			switch value {
			case "true", "on", "1", "yes":
				fc.mempool = 1
			case "false", "off", "0", "no":
				fc.mempool = 0
			case:
				return fc, Usage_Error.Bad_Config
			}
		case "electrum":
			switch value {
			case "true", "on", "1", "yes":
				fc.electrum = 1
			case "false", "off", "0", "no":
				fc.electrum = 0
			case:
				return fc, Usage_Error.Bad_Config
			}
		case "electrum_bind", "electrum-bind":
			set_config_string(&fc.electrum_bind, value, allocator) or_return
		case "electrum_banner", "electrum-banner":
			set_config_string(&fc.electrum_banner, value, allocator) or_return
		case "electrum_max_history", "electrum-max-history":
			fc.electrum_max_history = parse_config_uint(value) or_return
		case "esplora":
			switch value {
			case "true", "on", "1", "yes":
				fc.esplora = 1
			case "false", "off", "0", "no":
				fc.esplora = 0
			case:
				return fc, Usage_Error.Bad_Config
			}
		case "esplora_bind", "esplora-bind":
			set_config_string(&fc.esplora_bind, value, allocator) or_return
		case "query_workers", "query-workers":
			fc.query_workers = parse_config_uint(value) or_return
		case "compact":
			switch value {
			case "true", "on", "1", "yes":
				fc.compact = 1
			case "false", "off", "0", "no":
				fc.compact = 0
			case:
				return fc, Usage_Error.Bad_Config
			}
		case "network":
			set_config_string(&fc.network, value, allocator) or_return
		case "workers":
			fc.workers = parse_config_uint(value) or_return
		case "bucket_bits", "bucket-bits":
			fc.bucket_bits = parse_config_uint(value) or_return
		case "horizon":
			fc.horizon = parse_config_uint(value) or_return
		case "promote_batch":
			fc.promote_batch = parse_config_uint(value) or_return
		case:
			return fc, Usage_Error.Bad_Config
		}
	}
	return fc, nil
}

@(private = "file")
set_config_string :: proc(dst: ^string, value: string, allocator: runtime.Allocator) -> (err: Error) {
	delete(dst^, allocator)
	s, perr := clone_string(value, allocator)
	if perr != nil {
		return os.Error(perr)
	}
	dst^ = s
	return nil
}

@(private = "file")
parse_config_uint :: proc(value: string) -> (out: int, err: Error) {
	v, ok := strconv.parse_uint(value, 10)
	if !ok {
		return -1, Usage_Error.Bad_Config
	}
	return int(v), nil
}
