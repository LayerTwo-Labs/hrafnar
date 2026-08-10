package hugin

// The recent tier: the last HORIZON blocks, held as sorted in-memory rows
// and backed by recent.log, an append-only file framed per block. A reorg
// truncates at the fork point and re-indexes forward — no tombstones, no
// MVCC. Reads merge this tier into Munin through Iter_Source.
//
// recent.log record:
//   magic "HUGR" u32 | height u32le | block_hash 32 | row_count u32
//   | payload_len u32 | payload | crc32c u32 (whole record)
//
// payload: n_history u32 | n_txloc u32 | n_spends u32
//          | history rows | txloc rows | spends rows

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:log"
import "core:os"

import munin "../munin"

RECENT_MAGIC :: u32(0x48554752) // "HUGR"
RECENT_LOG_NAME :: "recent.log"

Recent_Block :: struct {
	height:    u32,
	hash:      [32]u8,
	n_history: int,
	n_txloc:   int,
	n_spends:  int,
}

Recent_Tier :: struct {
	dir:       string, // owned; index dir holding recent.log
	blocks:    [dynamic]Recent_Block, // ascending heights, contiguous
	history:   [dynamic]byte, // sorted history rows
	txloc:     [dynamic]byte, // sorted txloc rows
	spends:    [dynamic]byte, // sorted spends rows
	log_f:     ^os.File, // open for append
	// Sort scratch, owned and REUSED. Allocating this per resort from the
	// temp allocator meant one ever-larger buffer per appended block, none
	// of them freed until the catch-up ended — tens of GB across a long
	// catch-up, and the reason the daemon was OOM-killed.
	sort_buf:  [dynamic]byte,
	allocator: runtime.Allocator,
}

recent_open :: proc(dir: string, allocator := context.allocator) -> (rt: ^Recent_Tier, err: Error) {
	rt = new(Recent_Tier, allocator)
	rt.allocator = allocator
	perr: runtime.Allocator_Error
	rt.dir, perr = clone_string(dir, allocator)
	if perr != nil {
		free(rt, allocator)
		return nil, os.Error(perr)
	}
	rt.blocks = make([dynamic]Recent_Block, allocator)
	rt.history = make([dynamic]byte, allocator)
	rt.txloc = make([dynamic]byte, allocator)
	rt.spends = make([dynamic]byte, allocator)
	rt.sort_buf = make([dynamic]byte, allocator)
	defer if err != nil {
		recent_close(rt)
		rt = nil
	}

	path := fmt.tprintf("%s/%s", dir, RECENT_LOG_NAME)
	if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
		kept := make([dynamic]byte, context.temp_allocator)
		dups := recent_replay(rt, data, path, &kept) or_return
		if dups > 0 {
			log.warnf(
				"hugin: recent.log: dropped %d duplicate records (crash-replay leftovers); rewriting the log",
				dups,
			)
			recent_write_log(dir, kept[:]) or_return
		}
	}

	rt.log_f = os.open(
		path,
		{.Write, .Create, .Append},
		os.Permissions_Read_All + {.Write_User},
	) or_return
	return rt, nil
}

recent_close :: proc(rt: ^Recent_Tier) {
	if rt == nil {return}
	if rt.log_f != nil {
		os.close(rt.log_f)
	}
	delete(rt.blocks)
	delete(rt.history)
	delete(rt.txloc)
	delete(rt.spends)
	delete(rt.sort_buf)
	delete(rt.dir, rt.allocator)
	free(rt, rt.allocator)
}

// recent_replay loads records until the first torn or corrupt one, then
// truncates the file there — a crash mid-append leaves a torn tail, which
// is expected, not fatal.
@(private = "file")
recent_replay :: proc(
	rt: ^Recent_Tier,
	data: []byte,
	path: string,
	kept: ^[dynamic]byte = nil,
) -> (
	dups: int,
	err: Error,
) {
	pos := 0
	good := 0
	seen := make(map[u32][32]u8, context.temp_allocator)
	for {
		if pos + 48 > len(data) {
			break
		}
		rec := data[pos:]
		if get_u32le(rec) != RECENT_MAGIC {
			break
		}
		payload_len := int(get_u32le(rec[44:]))
		total := 48 + payload_len + 4
		if pos + total > len(data) {
			break
		}
		if munin.crc32c(rec[:48 + payload_len]) != get_u32le(rec[48 + payload_len:]) {
			break
		}

		height := get_u32le(rec[4:])
		hash: [32]u8
		copy(hash[:], rec[8:40])
		if prev, dup := seen[height]; dup {
			if prev == hash {
				// A crash between a tier append and the checkpoint write
				// makes the next run re-index and re-append the same
				// block. Content is deterministic; keep the first copy.
				dups += 1
				pos += total
				good += 1
				continue
			}
			// Same height, different hash: a stale tail from before an
			// unwind. Everything from here on is not on the kept chain.
			break
		}
		seen[height] = hash
		if kept != nil {
			append(kept, ..rec[:total])
		}
		payload := rec[48:48 + payload_len]
		// resort=false: sorting after EVERY record makes replay O(n^2)
		// over the tier — one sort after the loop suffices.
		recent_apply_payload(rt, height, hash, payload, false) or_return

		pos += total
		good += 1
	}
	if good > 0 {
		recent_resort(rt)
	}
	if pos < len(data) {
		log.warnf(
			"hugin: recent.log torn at byte %d (%d good records), truncating",
			pos,
			good,
		)
		f := os.open(path, {.Write}) or_return
		terr := os.truncate(f, i64(pos))
		os.close(f)
		if terr != nil {
			return dups, terr
		}
	}
	return dups, nil
}

@(private = "file")
recent_apply_payload :: proc(
	rt: ^Recent_Tier,
	height: u32,
	hash: [32]u8,
	payload: []byte,
	resort := true,
) -> (
	err: Error,
) {
	if len(payload) < 12 {
		return Corruption.Bad_Record
	}
	nh := int(get_u32le(payload[0:]))
	nt := int(get_u32le(payload[4:]))
	ns := int(get_u32le(payload[8:]))
	need := 12 + nh * HISTORY_ROW_SIZE + nt * TXLOC_ROW_SIZE + ns * SPENDS_ROW_SIZE
	if len(payload) != need {
		return Corruption.Bad_Record
	}
	off := 12
	h_rows := payload[off:off + nh * HISTORY_ROW_SIZE]
	off += nh * HISTORY_ROW_SIZE
	t_rows := payload[off:off + nt * TXLOC_ROW_SIZE]
	off += nt * TXLOC_ROW_SIZE
	s_rows := payload[off:off + ns * SPENDS_ROW_SIZE]

	append(&rt.blocks, Recent_Block{height = height, hash = hash, n_history = nh, n_txloc = nt, n_spends = ns})
	append(&rt.history, ..h_rows)
	append(&rt.txloc, ..t_rows)
	append(&rt.spends, ..s_rows)
	if resort {
		recent_resort(rt)
	}
	return nil
}

@(private)
recent_resort :: proc(rt: ^Recent_Tier) {
	need := max(len(rt.history), max(len(rt.txloc), len(rt.spends)))
	if len(rt.sort_buf) < need {
		resize(&rt.sort_buf, need)
	}
	radix_sort_rows(rt.history[:], HISTORY_ROW_SIZE, HISTORY_KEY_LEN, rt.sort_buf[:len(rt.history)])
	radix_sort_rows(rt.txloc[:], TXLOC_ROW_SIZE, TXLOC_KEY_LEN, rt.sort_buf[:len(rt.txloc)])
	radix_sort_rows(rt.spends[:], SPENDS_ROW_SIZE, SPENDS_KEY_LEN, rt.sort_buf[:len(rt.spends)])
}

// recent_resort_txloc sorts ONLY the txloc keyspace. During a multi-block
// catch-up that is the only one queried (spend resolution looks up
// transactions), so history and spends can be sorted once at the end
// instead of once per block.
@(private = "file")
recent_resort_txloc :: proc(rt: ^Recent_Tier) {
	if len(rt.sort_buf) < len(rt.txloc) {
		resize(&rt.sort_buf, len(rt.txloc))
	}
	radix_sort_rows(rt.txloc[:], TXLOC_ROW_SIZE, TXLOC_KEY_LEN, rt.sort_buf[:len(rt.txloc)])
}

// recent_tip returns the tier's highest block, ok=false when empty.
recent_tip :: proc(rt: ^Recent_Tier) -> (height: u32, hash: [32]u8, ok: bool) {
	if len(rt.blocks) == 0 {
		return 0, {}, false
	}
	last := rt.blocks[len(rt.blocks) - 1]
	return last.height, last.hash, true
}

// recent_append_block persists one block's rows (fsynced) and merges them
// into the in-memory tier.
recent_append_block :: proc(
	rt: ^Recent_Tier,
	height: u32,
	hash: [32]u8,
	h_rows: []byte, // history rows, any order
	t_rows: []byte, // txloc rows
	s_rows: []byte, // spends rows,
	full_resort := true, // false during a bulk catch-up: only txloc is queried
) -> (
	err: Error,
) {
	hash := hash
	if len(h_rows) % HISTORY_ROW_SIZE != 0 ||
	   len(t_rows) % TXLOC_ROW_SIZE != 0 ||
	   len(s_rows) % SPENDS_ROW_SIZE != 0 {
		return Corruption.Bad_Record
	}
	nh := len(h_rows) / HISTORY_ROW_SIZE
	nt := len(t_rows) / TXLOC_ROW_SIZE
	ns := len(s_rows) / SPENDS_ROW_SIZE

	// Owned and freed here, NOT temp: a caller in a catch-up loop resets
	// its temp allocator far less often than once per block, so a record
	// per block (a megabyte on a busy one) would accumulate for the whole
	// run.
	rec := make([dynamic]byte, 0, 64 + len(h_rows) + len(t_rows) + len(s_rows), rt.allocator)
	defer delete(rec)
	head: [48]byte
	put_u32le(head[0:], RECENT_MAGIC)
	put_u32le(head[4:], height)
	copy(head[8:40], hash[:])
	put_u32le(head[40:], u32(nh + nt + ns))
	put_u32le(head[44:], u32(12 + len(h_rows) + len(t_rows) + len(s_rows)))
	append(&rec, ..head[:])
	counts: [12]byte
	put_u32le(counts[0:], u32(nh))
	put_u32le(counts[4:], u32(nt))
	put_u32le(counts[8:], u32(ns))
	append(&rec, ..counts[:])
	append(&rec, ..h_rows)
	append(&rec, ..t_rows)
	append(&rec, ..s_rows)
	crc: [4]byte
	put_u32le(crc[:], munin.crc32c(rec[:]))
	append(&rec, ..crc[:])

	write_full(rt.log_f, rec[:]) or_return
	os.sync(rt.log_f) or_return

	append(&rt.blocks, Recent_Block{height = height, hash = hash, n_history = nh, n_txloc = nt, n_spends = ns})
	append(&rt.history, ..h_rows)
	append(&rt.txloc, ..t_rows)
	append(&rt.spends, ..s_rows)
	if full_resort {
		recent_resort(rt)
	} else {
		// Bulk catch-up: only txloc is read back (spend resolution looks up
		// transactions from earlier in the same batch). Sorting history and
		// spends too, once per block over a tier that grows all the way
		// through the catch-up, is quadratic work for no reader. The caller
		// must call recent_resort once when the batch is done.
		recent_resort_txloc(rt)
	}
	return nil
}

// recent_truncate_above discards every block above fork_height, rewriting
// recent.log with the survivors under the full durability protocol, and
// rebuilds the in-memory rows.
recent_truncate_above :: proc(rt: ^Recent_Tier, fork_height: u32) -> (err: Error) {
	keep := 0
	for b in rt.blocks {
		if b.height <= fork_height {
			keep += 1
		} else {
			break
		}
	}
	if keep == len(rt.blocks) {
		return nil
	}
	log.infof(
		"hugin: reorg unwind: dropping %d recent blocks above height %d",
		len(rt.blocks) - keep,
		fork_height,
	)

	// The in-memory rows are sorted and no longer per-block; the log
	// itself holds the per-block framing, so rebuild from the log by
	// replaying the survivors into a fresh tier state.
	path := fmt.tprintf("%s/%s", rt.dir, RECENT_LOG_NAME)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return rerr
	}

	// Collect surviving records byte-exactly.
	out := make([dynamic]byte, context.temp_allocator)
	pos := 0
	kept := 0
	for pos + 48 <= len(data) && kept < keep {
		rec := data[pos:]
		if get_u32le(rec) != RECENT_MAGIC {
			break
		}
		payload_len := int(get_u32le(rec[44:]))
		total := 48 + payload_len + 4
		if pos + total > len(data) {
			break
		}
		height := get_u32le(rec[4:])
		if height <= fork_height {
			append(&out, ..rec[:total])
			kept += 1
		}
		pos += total
	}

	// Rewrite atomically.
	if rt.log_f != nil {
		os.close(rt.log_f)
		rt.log_f = nil
	}
	recent_write_log(rt.dir, out[:]) or_return

	// Reset and replay the surviving records.
	clear(&rt.blocks)
	clear(&rt.history)
	clear(&rt.txloc)
	clear(&rt.spends)
	_ = recent_replay(rt, out[:], path) or_return

	rt.log_f = os.open(
		path,
		{.Write, .Create, .Append},
		os.Permissions_Read_All + {.Write_User},
	) or_return
	return nil
}

// recent_drop_below removes blocks at or below the given height from the
// tier (after promotion into the main body), rewriting the log.
recent_drop_below :: proc(rt: ^Recent_Tier, height: u32) -> (err: Error) {
	// Same rewrite mechanism, keeping blocks ABOVE height.
	path := fmt.tprintf("%s/%s", rt.dir, RECENT_LOG_NAME)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return rerr
	}
	out := make([dynamic]byte, context.temp_allocator)
	pos := 0
	for pos + 48 <= len(data) {
		rec := data[pos:]
		if get_u32le(rec) != RECENT_MAGIC {
			break
		}
		payload_len := int(get_u32le(rec[44:]))
		total := 48 + payload_len + 4
		if pos + total > len(data) {
			break
		}
		if get_u32le(rec[4:]) > height {
			append(&out, ..rec[:total])
		}
		pos += total
	}

	if rt.log_f != nil {
		os.close(rt.log_f)
		rt.log_f = nil
	}
	recent_write_log(rt.dir, out[:]) or_return

	clear(&rt.blocks)
	clear(&rt.history)
	clear(&rt.txloc)
	clear(&rt.spends)
	_ = recent_replay(rt, out[:], path) or_return

	rt.log_f = os.open(
		path,
		{.Write, .Create, .Append},
		os.Permissions_Read_All + {.Write_User},
	) or_return
	return nil
}

// Recent_Probe carries one representative key per keyspace for a tier
// block, for the promotion-crash reconcile: if these keys already exist in
// the main body, the block was promoted and its tier copy must go.
Recent_Probe :: struct {
	height:    u32,
	h_key:     [HISTORY_KEY_LEN]u8,
	t_key:     [TXLOC_KEY_LEN]u8,
	s_key:     [SPENDS_KEY_LEN]u8,
	h_row:     [HISTORY_ROW_SIZE]u8, // full rows: compact probe keys derive from these
	t_row:     [TXLOC_ROW_SIZE]u8,
	s_row:     [SPENDS_ROW_SIZE]u8,
	n_history: int,
	n_txloc:   int,
	n_spends:  int,
}

// recent_probe_blocks reads one probe per tier block from the log, in
// height order (temp-allocated).
recent_probe_blocks :: proc(rt: ^Recent_Tier) -> (probes: []Recent_Probe, err: Error) {
	path := fmt.tprintf("%s/%s", rt.dir, RECENT_LOG_NAME)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return nil, rerr
	}
	out := make([dynamic]Recent_Probe, context.temp_allocator)
	pos := 0
	for pos + 48 <= len(data) {
		rec := data[pos:]
		if get_u32le(rec) != RECENT_MAGIC {
			break
		}
		payload_len := int(get_u32le(rec[44:]))
		total := 48 + payload_len + 4
		if pos + total > len(data) {
			break
		}
		payload := rec[48:48 + payload_len]
		if len(payload) >= 12 {
			p: Recent_Probe
			p.height = get_u32le(rec[4:])
			p.n_history = int(get_u32le(payload[0:]))
			p.n_txloc = int(get_u32le(payload[4:]))
			p.n_spends = int(get_u32le(payload[8:]))
			off := 12
			if p.n_history > 0 {
				copy(p.h_key[:], payload[off:off + HISTORY_KEY_LEN])
				copy(p.h_row[:], payload[off:off + HISTORY_ROW_SIZE])
			}
			off += p.n_history * HISTORY_ROW_SIZE
			if p.n_txloc > 0 {
				copy(p.t_key[:], payload[off:off + TXLOC_KEY_LEN])
				copy(p.t_row[:], payload[off:off + TXLOC_ROW_SIZE])
			}
			off += p.n_txloc * TXLOC_ROW_SIZE
			if p.n_spends > 0 {
				copy(p.s_key[:], payload[off:off + SPENDS_KEY_LEN])
				copy(p.s_row[:], payload[off:off + SPENDS_ROW_SIZE])
			}
			append(&out, p)
		}
		pos += total
	}
	return out[:], nil
}

// recent_collect_below gathers the per-keyspace rows of every block at or
// below the cutoff height, straight from the log's per-block framing (the
// in-memory arrays are merged and can no longer attribute rows to blocks).
// Used by promotion.
recent_collect_below :: proc(
	rt: ^Recent_Tier,
	cutoff: u32,
	h_out: ^[dynamic]byte,
	t_out: ^[dynamic]byte,
	s_out: ^[dynamic]byte,
) -> (
	err: Error,
) {
	path := fmt.tprintf("%s/%s", rt.dir, RECENT_LOG_NAME)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return rerr
	}
	pos := 0
	for pos + 48 <= len(data) {
		rec := data[pos:]
		if get_u32le(rec) != RECENT_MAGIC {
			break
		}
		payload_len := int(get_u32le(rec[44:]))
		total := 48 + payload_len + 4
		if pos + total > len(data) {
			break
		}
		height := get_u32le(rec[4:])
		if height <= cutoff {
			payload := rec[48:48 + payload_len]
			nh := int(get_u32le(payload[0:]))
			nt := int(get_u32le(payload[4:]))
			off := 12
			append(h_out, ..payload[off:off + nh * HISTORY_ROW_SIZE])
			off += nh * HISTORY_ROW_SIZE
			append(t_out, ..payload[off:off + nt * TXLOC_ROW_SIZE])
			off += nt * TXLOC_ROW_SIZE
			// The remainder of the payload is the spends section.
			append(s_out, ..payload[off:])
		}
		pos += total
	}
	return nil
}

// ---------------------------------------------------------------------------
// Queries against the tier's sorted rows.

@(private = "file")
sorted_rows_find :: proc(rows: []byte, row_size, key_len: int, key: []byte) -> (value: []byte, found: bool) {
	n := len(rows) / row_size
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		mk := rows[mid * row_size:mid * row_size + key_len]
		if bytes.compare(mk, key) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < n {
		row := rows[lo * row_size:(lo + 1) * row_size]
		if bytes.compare(row[:key_len], key) == 0 {
			return row[key_len:], true
		}
	}
	return nil, false
}

// recent_lookup_txloc finds a txid in the tier.
recent_lookup_txloc :: proc(rt: ^Recent_Tier, txid: [32]u8) -> (loc: Txloc_Value, found: bool) {
	txid := txid
	v, ok := sorted_rows_find(rt.txloc[:], TXLOC_ROW_SIZE, TXLOC_KEY_LEN, txid[:])
	if !ok {
		return {}, false
	}
	return txloc_value_decode(v), true
}

// recent_lookup_spend finds an outpoint spend in the tier.
recent_lookup_spend :: proc(rt: ^Recent_Tier, key: [SPENDS_KEY_LEN]byte) -> (spend: Spend_Value, found: bool) {
	key := key
	v, ok := sorted_rows_find(rt.spends[:], SPENDS_ROW_SIZE, SPENDS_KEY_LEN, key[:])
	if !ok {
		return {}, false
	}
	return spends_value_decode(v), true
}

// ---------------------------------------------------------------------------
// Iter_Source over the sorted history rows: how the tier joins the merge.

Recent_Cursor :: struct {
	rt:  ^Recent_Tier,
	pos: int, // row index
}

recent_history_source :: proc(cur: ^Recent_Cursor) -> munin.Iter_Source {
	return munin.Iter_Source {
		user  = cur,
		seek  = recent_src_seek,
		next  = recent_src_next,
		valid = recent_src_valid,
		key   = recent_src_key,
		value = recent_src_value,
	}
}

@(private = "file")
recent_src_seek :: proc(user: rawptr, key: []byte) {
	cur := cast(^Recent_Cursor)user
	rows := cur.rt.history[:]
	n := len(rows) / HISTORY_ROW_SIZE
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		mk := rows[mid * HISTORY_ROW_SIZE:mid * HISTORY_ROW_SIZE + HISTORY_KEY_LEN]
		if bytes.compare(mk, key) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	cur.pos = lo
}

@(private = "file")
recent_src_next :: proc(user: rawptr) {
	cur := cast(^Recent_Cursor)user
	cur.pos += 1
}

@(private = "file")
recent_src_valid :: proc(user: rawptr) -> bool {
	cur := cast(^Recent_Cursor)user
	return cur.pos < len(cur.rt.history) / HISTORY_ROW_SIZE
}

@(private = "file")
recent_src_key :: proc(user: rawptr) -> []byte {
	cur := cast(^Recent_Cursor)user
	return cur.rt.history[cur.pos * HISTORY_ROW_SIZE:cur.pos * HISTORY_ROW_SIZE + HISTORY_KEY_LEN]
}

@(private = "file")
recent_src_value :: proc(user: rawptr) -> []byte {
	cur := cast(^Recent_Cursor)user
	return cur.rt.history[cur.pos * HISTORY_ROW_SIZE + HISTORY_KEY_LEN:(cur.pos + 1) * HISTORY_ROW_SIZE]
}

// recent_write_log atomically replaces recent.log with the given frames:
// write-tmp, fsync, rename, fsync directory. Callers with an open append
// handle must close it first.
@(private = "file")
recent_write_log :: proc(dir: string, frames: []byte) -> (err: Error) {
	path := fmt.tprintf("%s/%s", dir, RECENT_LOG_NAME)
	tmp := fmt.tprintf("%s/%s.tmp", dir, RECENT_LOG_NAME)
	f := os.open(tmp, {.Write, .Create, .Trunc}, os.Permissions_Read_All + {.Write_User}) or_return
	werr := write_full(f, frames)
	if werr == nil {
		if serr := os.sync(f); serr != nil {werr = serr}
	}
	cerr := os.close(f)
	if werr != nil {
		return werr
	}
	if cerr != nil {
		return cerr
	}
	os.rename(tmp, path) or_return
	dir_sync(dir) or_return
	return nil
}
