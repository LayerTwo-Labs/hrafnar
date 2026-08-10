package hugin

// Shared query request/response layer, used by the daemon's socket server
// and by the CLI's direct-index fallback, so query logic and output
// formatting exist exactly once.
//
// Protocol (one request line per connection, newline-terminated):
//   balance  <scripthash-hex64>
//   history  <scripthash-hex64> <from> <limit>
//   tx       <txid-hex64> <raw:0|1>
//   outpoint <txid-hex64> <vout>
//   tip
//
// Response: "OK\n" followed by the payload, or "ERR <message>\n".
// Addresses are resolved to scripthashes client-side; the wire carries hex
// only.

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

// serve_request executes one request line against an open index and
// returns the full response (status line included), allocated from the
// given allocator. mp carries the daemon's mempool tier; nil (the direct
// CLI path) simply omits unconfirmed data.
serve_request :: proc(
	idx: ^Index,
	mp: ^Mempool,
	line: string,
	allocator := context.allocator,
) -> (
	response: string,
) {
	fields := strings.fields(strings.trim_space(line), context.temp_allocator)
	if len(fields) == 0 {
		return err_response("empty request", allocator)
	}
	// "json <command> ..." switches the payload to a single JSON object.
	json_mode := false
	if fields[0] == "json" {
		json_mode = true
		fields = fields[1:]
		if len(fields) == 0 {
			return err_response("empty request", allocator)
		}
	}

	switch fields[0] {
	case "balance":
		if len(fields) != 2 {
			return err_response("usage: balance <scripthash>", allocator)
		}
		sh, ok := hex_decode_32(fields[1])
		if !ok {
			return err_response("bad scripthash", allocator)
		}
		balance, berr := query_balance(idx, sh)
		if berr != nil {
			return errf_response(allocator, "balance failed: %v", berr)
		}
		if json_mode {
			delta: i64
			pending := 0
			if mp != nil {
				delta, pending = mempool_delta(mp, sh)
			}
			return ok_response(
				allocator,
				"{{\"confirmed\":%d,\"pending\":%d,\"pending_txs\":%d,\"total\":%d,\"mempool\":%v}}\n",
				balance,
				delta,
				pending,
				balance + delta,
				mp != nil,
			)
		}
		if mp != nil {
			if delta, pending := mempool_delta(mp, sh); pending > 0 {
				unit := unit_label(idx.cfg.network)
				return ok_response(
					allocator,
					"%d sat (%s %s) confirmed\n%s%d sat pending (%d unconfirmed tx)\n%d sat (%s %s) total\n",
					balance,
					format_btc_amount(balance),
					unit,
					"+" if delta >= 0 else "",
					delta,
					pending,
					balance + delta,
					format_btc_amount(balance + delta),
					unit,
				)
			}
		}
		return ok_response(
			allocator,
			"%d sat (%s %s)\n",
			balance,
			format_btc_amount(balance),
			unit_label(idx.cfg.network),
		)

	case "history":
		if len(fields) != 4 {
			return err_response("usage: history <scripthash> <from> <limit>", allocator)
		}
		sh, ok := hex_decode_32(fields[1])
		if !ok {
			return err_response("bad scripthash", allocator)
		}
		from, fok := strconv.parse_uint(fields[2], 10)
		if !fok {
			return err_response("bad from height", allocator)
		}
		limit, lok := strconv.parse_int(fields[3], 10)
		if !lok {
			return err_response("bad limit", allocator)
		}
		entries, herr := query_history_resolved(idx, sh, u32(from), limit, context.temp_allocator)
		if herr != nil {
			return errf_response(allocator, "history failed: %v", herr)
		}
		if json_mode {
			jb := strings.builder_make(context.temp_allocator)
			jhex: [64]byte
			strings.write_string(&jb, "OK\n{\"entries\":[")
			for r, k in entries {
				e := r.entry
				fmt.sbprintf(
					&jb,
					"%s{{\"height\":%d,\"txid\":\"%s\",\"dir\":\"%s\",\"amount\":%d,\"io\":%d}}",
					"," if k > 0 else "",
					e.height,
					txid_to_hex(r.txid, jhex[:]),
					"recv" if e.direction == DIRECTION_FUNDING else "send",
					e.amount,
					e.io_index,
				)
			}
			strings.write_string(&jb, "],\"mempool\":[")
			if mp != nil {
				for e, k in mempool_entries(mp, sh) {
					fmt.sbprintf(
						&jb,
						"%s{{\"txid\":\"%s\",\"dir\":\"%s\",\"amount\":%d,\"io\":%d}}",
						"," if k > 0 else "",
						txid_to_hex(e.txid, jhex[:]),
						"recv" if e.direction == DIRECTION_FUNDING else "send",
						e.amount,
						e.io_index,
					)
				}
			}
			strings.write_string(&jb, "]}\n")
			return clone_response(strings.to_string(jb), allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "OK\n")
		hexbuf: [64]byte
		for r in entries {
			e := r.entry
			dir := "recv" if e.direction == DIRECTION_FUNDING else "sent"
			sign := "+" if e.direction == DIRECTION_FUNDING else "-"
			fmt.sbprintfln(
				&b,
				"height %d\t%s\t%s\t%s%d sat\t(io %d)",
				e.height,
				txid_to_hex(r.txid, hexbuf[:]),
				dir,
				sign,
				e.amount,
				e.io_index,
			)
		}
		pending := 0
		if mp != nil {
			for e in mempool_entries(mp, sh) {
				dir := "recv" if e.direction == DIRECTION_FUNDING else "sent"
				sign := "+" if e.direction == DIRECTION_FUNDING else "-"
				fmt.sbprintfln(
					&b,
					"mempool\t%s\t%s\t%s%d sat\t(io %d)",
					txid_to_hex(e.txid, hexbuf[:]),
					dir,
					sign,
					e.amount,
					e.io_index,
				)
				pending += 1
			}
		}
		if pending > 0 {
			fmt.sbprintfln(&b, "%d entries, %d pending", len(entries), pending)
		} else {
			fmt.sbprintfln(&b, "%d entries", len(entries))
		}
		return clone_response(strings.to_string(b), allocator)

	case "utxos":
		if len(fields) != 2 {
			return err_response("usage: utxos <scripthash>", allocator)
		}
		sh, ok := hex_decode_32(fields[1])
		if !ok {
			return err_response("bad scripthash", allocator)
		}
		utxos, uerr := query_utxos(idx, sh, context.temp_allocator)
		if uerr != nil {
			return errf_response(allocator, "utxos failed: %v", uerr)
		}
		if json_mode {
			jb := strings.builder_make(context.temp_allocator)
			jhex: [64]byte
			total_j: u64
			strings.write_string(&jb, "OK\n{\"utxos\":[")
			for u, k in utxos {
				total_j += u.amount
				spending := false
				if mp != nil {
					_, spending = mempool_spender(mp, u.txid, u.vout)
				}
				fmt.sbprintf(
					&jb,
					"%s{{\"txid\":\"%s\",\"vout\":%d,\"amount\":%d,\"height\":%d,\"spend_pending\":%v}}",
					"," if k > 0 else "",
					txid_to_hex(u.txid, jhex[:]),
					u.vout,
					u.amount,
					u.height,
					spending,
				)
			}
			strings.write_string(&jb, "],\"mempool\":[")
			if mp != nil {
				first := true
				for e in mempool_entries(mp, sh) {
					if e.direction != DIRECTION_FUNDING {continue}
					fmt.sbprintf(
						&jb,
						"%s{{\"txid\":\"%s\",\"vout\":%d,\"amount\":%d}}",
						"" if first else ",",
						txid_to_hex(e.txid, jhex[:]),
						e.io_index,
						e.amount,
					)
					first = false
				}
			}
			fmt.sbprintf(&jb, "],\"total\":%d}}\n", total_j)
			return clone_response(strings.to_string(jb), allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "OK\n")
		hexbuf: [64]byte
		total: u64
		for u in utxos {
			total += u.amount
			note := ""
			if mp != nil {
				if _, spending := mempool_spender(mp, u.txid, u.vout); spending {
					note = "\t(spend pending)"
				}
			}
			fmt.sbprintfln(
				&b,
				"%s:%d\t%d sat\theight %d%s",
				txid_to_hex(u.txid, hexbuf[:]),
				u.vout,
				u.amount,
				u.height,
				note,
			)
		}
		if mp != nil {
			for e in mempool_entries(mp, sh) {
				if e.direction != DIRECTION_FUNDING {continue}
				fmt.sbprintfln(
					&b,
					"%s:%d\t%d sat\tmempool",
					txid_to_hex(e.txid, hexbuf[:]),
					e.io_index,
					e.amount,
				)
			}
		}
		fmt.sbprintfln(
			&b,
			"%d utxos, %d sat (%s %s) total",
			len(utxos),
			total,
			format_btc_amount(i64(total)),
			unit_label(idx.cfg.network),
		)
		return clone_response(strings.to_string(b), allocator)

	case "header":
		if len(fields) != 2 {
			return err_response("usage: header <height>", allocator)
		}
		height, hok := strconv.parse_uint(fields[1], 10)
		if !hok {
			return err_response("bad height", allocator)
		}
		hdr, found := query_header(idx, u32(height))
		if !found {
			return err_response("height beyond tip", allocator)
		}
		if json_mode {
			jb := strings.builder_make(context.temp_allocator)
			jhex: [64]byte
			jprev, jmerkle: [32]u8
			copy(jprev[:], hdr.raw[4:36])
			copy(jmerkle[:], hdr.raw[36:68])
			fmt.sbprintf(&jb, "OK\n{{\"height\":%d,\"hash\":\"%s\"", height, txid_to_hex(hdr.hash, jhex[:]))
			fmt.sbprintf(&jb, ",\"prev\":\"%s\"", txid_to_hex(jprev, jhex[:]))
			fmt.sbprintf(&jb, ",\"merkle\":\"%s\"", txid_to_hex(jmerkle, jhex[:]))
			fmt.sbprintf(
				&jb,
				",\"version\":%d,\"time\":%d,\"bits\":%d,\"nonce\":%d,\"txs\":%d,\"raw\":\"",
				get_u32le(hdr.raw[0:4]),
				get_u32le(hdr.raw[68:72]),
				get_u32le(hdr.raw[72:76]),
				get_u32le(hdr.raw[76:80]),
				hdr.tx_count,
			)
			JHEXD := "0123456789abcdef"
			for by in hdr.raw {
				strings.write_byte(&jb, JHEXD[by >> 4])
				strings.write_byte(&jb, JHEXD[by & 0xF])
			}
			strings.write_string(&jb, "\"}\n")
			return clone_response(strings.to_string(jb), allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "OK\n")
		hexbuf: [64]byte
		fmt.sbprintfln(&b, "height  %d", height)
		fmt.sbprintfln(&b, "hash    %s", txid_to_hex(hdr.hash, hexbuf[:]))
		prev: [32]u8
		copy(prev[:], hdr.raw[4:36])
		fmt.sbprintfln(&b, "prev    %s", txid_to_hex(prev, hexbuf[:]))
		merkle: [32]u8
		copy(merkle[:], hdr.raw[36:68])
		fmt.sbprintfln(&b, "merkle  %s", txid_to_hex(merkle, hexbuf[:]))
		fmt.sbprintfln(&b, "version 0x%08x", get_u32le(hdr.raw[0:4]))
		fmt.sbprintfln(&b, "time    %d", get_u32le(hdr.raw[68:72]))
		fmt.sbprintfln(&b, "bits    0x%08x", get_u32le(hdr.raw[72:76]))
		fmt.sbprintfln(&b, "nonce   %d", get_u32le(hdr.raw[76:80]))
		fmt.sbprintfln(&b, "txs     %d", hdr.tx_count)
		strings.write_string(&b, "raw     ")
		HEXD := "0123456789abcdef"
		for by in hdr.raw {
			strings.write_byte(&b, HEXD[by >> 4])
			strings.write_byte(&b, HEXD[by & 0xF])
		}
		strings.write_byte(&b, '\n')
		return clone_response(strings.to_string(b), allocator)

	case "tx":
		if len(fields) != 3 {
			return err_response("usage: tx <txid> <raw:0|1>", allocator)
		}
		txid, ok := hex_decode_32(fields[1]) // wire carries internal order
		if !ok {
			return err_response("bad txid", allocator)
		}
		raw_mode := fields[2] == "1"
		raw, height, found, terr := query_tx(idx, txid)
		if terr != nil {
			return errf_response(allocator, "tx lookup failed: %v", terr)
		}
		if !found {
			return err_response("transaction not found", allocator)
		}
		if json_mode {
			jb := strings.builder_make(context.temp_allocator)
			jhex: [64]byte
			if raw_mode {
				strings.write_string(&jb, "OK\n{\"hex\":\"")
				JHEXD := "0123456789abcdef"
				for by in raw {
					strings.write_byte(&jb, JHEXD[by >> 4])
					strings.write_byte(&jb, JHEXD[by & 0xF])
				}
				strings.write_string(&jb, "\"}\n")
			} else {
				fmt.sbprintf(
					&jb,
					"OK\n{{\"txid\":\"%s\",\"height\":%d,\"size\":%d}}\n",
					txid_to_hex(txid, jhex[:]),
					height,
					len(raw),
				)
			}
			return clone_response(strings.to_string(jb), allocator)
		}
		if raw_mode {
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "OK\n")
			HEXD := "0123456789abcdef"
			for by in raw {
				strings.write_byte(&b, HEXD[by >> 4])
				strings.write_byte(&b, HEXD[by & 0xF])
			}
			strings.write_byte(&b, '\n')
			return clone_response(strings.to_string(b), allocator)
		}
		hexbuf: [64]byte
		return ok_response(
			allocator,
			"txid   %s\nheight %d\nsize   %d bytes\n",
			txid_to_hex(txid, hexbuf[:]),
			height,
			len(raw),
		)

	case "merkle":
		if len(fields) != 2 {
			return err_response("usage: merkle <txid>", allocator)
		}
		txid, ok := hex_decode_32(fields[1]) // wire carries internal order
		if !ok {
			return err_response("bad txid", allocator)
		}
		height, pos, branch, found, merr := query_merkle(idx, txid, context.temp_allocator)
		if merr != nil {
			return errf_response(allocator, "merkle lookup failed: %v", merr)
		}
		if !found {
			return err_response("transaction not found", allocator)
		}
		if json_mode {
			jb := strings.builder_make(context.temp_allocator)
			jhex: [64]byte
			fmt.sbprintf(&jb, "OK\n{{\"height\":%d,\"pos\":%d,\"branch\":[", height, pos)
			for node, k in branch {
				fmt.sbprintf(&jb, "%s\"%s\"", "," if k > 0 else "", txid_to_hex(node, jhex[:]))
			}
			strings.write_string(&jb, "]}\n")
			return clone_response(strings.to_string(jb), allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		hexbuf: [64]byte
		fmt.sbprintf(&b, "OK\nheight %d\npos    %d\n", height, pos)
		for node in branch {
			fmt.sbprintf(&b, "node   %s\n", txid_to_hex(node, hexbuf[:]))
		}
		return clone_response(strings.to_string(b), allocator)

	case "feehist":
		if mp == nil {
			return err_response("fee histogram requires a running daemon", allocator)
		}
		bins := mempool_fee_histogram(mp, context.temp_allocator)
		if json_mode {
			jb := strings.builder_make(context.temp_allocator)
			strings.write_string(&jb, "OK\n[")
			for bin, k in bins {
				fmt.sbprintf(&jb, "%s[%.2f,%d]", "," if k > 0 else "", bin.rate, bin.vsize)
			}
			strings.write_string(&jb, "]\n")
			return clone_response(strings.to_string(jb), allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "OK\n")
		if len(bins) == 0 {
			strings.write_string(&b, "empty mempool\n")
		}
		for bin in bins {
			fmt.sbprintf(&b, "%.1f sat/vB  %d vB\n", bin.rate, bin.vsize)
		}
		return clone_response(strings.to_string(b), allocator)

	case "outpoint":
		if len(fields) != 3 {
			return err_response("usage: outpoint <txid> <vout>", allocator)
		}
		txid, ok := hex_decode_32(fields[1])
		if !ok {
			return err_response("bad txid", allocator)
		}
		vout, vok := strconv.parse_uint(fields[2], 10)
		if !vok {
			return err_response("bad vout", allocator)
		}
		spend, found, serr := query_outpoint(idx, txid, u32(vout))
		if serr != nil {
			return errf_response(allocator, "outpoint lookup failed: %v", serr)
		}
		if json_mode {
			if !found {
				return ok_response(allocator, "{{\"spent\":false}}\n")
			}
			jhex: [64]byte
			return ok_response(
				allocator,
				"{{\"spent\":true,\"spender\":\"%s\",\"vin\":%d,\"height\":%d}}\n",
				txid_to_hex(spend.spender_txid, jhex[:]),
				spend.vin,
				spend.height,
			)
		}
		if !found {
			return ok_response(allocator, "unspent (or unknown outpoint)\n")
		}
		hexbuf: [64]byte
		return ok_response(
			allocator,
			"spent by %s\nvin      %d\nheight   %d\n",
			txid_to_hex(spend.spender_txid, hexbuf[:]),
			spend.vin,
			spend.height,
		)

	case "tip":
		tip := index_tip_height(idx)
		if tip < 0 {
			return err_response("empty chain", allocator)
		}
		if json_mode {
			jhex: [64]byte
			if mp != nil {
				return ok_response(
					allocator,
					"{{\"height\":%d,\"hash\":\"%s\",\"mempool\":%d}}\n",
					tip,
					txid_to_hex(idx.chain[tip].hash, jhex[:]),
					mempool_size(mp),
				)
			}
			return ok_response(
				allocator,
				"{{\"height\":%d,\"hash\":\"%s\",\"mempool\":null}}\n",
				tip,
				txid_to_hex(idx.chain[tip].hash, jhex[:]),
			)
		}
		hexbuf: [64]byte
		if mp != nil {
			return ok_response(
				allocator,
				"height  %d\nhash    %s\nmempool %d txs tracked\n",
				tip,
				txid_to_hex(idx.chain[tip].hash, hexbuf[:]),
				mempool_size(mp),
			)
		}
		return ok_response(
			allocator,
			"height %d\nhash   %s\n",
			tip,
			txid_to_hex(idx.chain[tip].hash, hexbuf[:]),
		)
	}
	return err_response("unknown command", allocator)
}

// format_btc_amount renders satoshis as a BTC decimal string
// (temp-allocated).
format_btc_amount :: proc(sat: i64) -> string {
	neg := sat < 0
	v := u64(sat if !neg else -sat)
	return fmt.tprintf("%s%d.%08d", "-" if neg else "", v / 100_000_000, v % 100_000_000)
}

@(private = "file")
ok_response :: proc(allocator: runtime.Allocator, format: string, args: ..any) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "OK\n")
	fmt.sbprintf(&b, format, ..args)
	return clone_response(strings.to_string(b), allocator)
}

@(private = "file")
err_response :: proc(msg: string, allocator: runtime.Allocator) -> string {
	return clone_response(fmt.tprintf("ERR %s\n", msg), allocator)
}

@(private = "file")
errf_response :: proc(allocator: runtime.Allocator, format: string, args: ..any) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "ERR ")
	fmt.sbprintf(&b, format, ..args)
	strings.write_byte(&b, '\n')
	return clone_response(strings.to_string(b), allocator)
}

@(private = "file")
clone_response :: proc(s: string, allocator: runtime.Allocator) -> string {
	out, _ := clone_string(s, allocator)
	return out
}
