package hugin

// Compact-index query paths: prefix scans over 8-byte-prefix keys, with
// every candidate verified against the actual chain data before it is
// believed. False prefix matches are dropped silently; a candidate whose
// location cannot be read is corruption, never a guess.
//
// The recent tier always stores exact rows, so tier hits skip
// verification; main-body hits pay reads. The merged main+tier iterator
// of the exact paths cannot be used here (mixed key widths), so main and
// tier are scanned separately and merged in memory.

import "core:bytes"
import "core:sync"

import munin "../munin"

// c_txloc_scan resolves a full txid against a compact txloc keyspace:
// candidates under the 8-byte prefix are verified by hashing the tx bytes
// at their recorded location. BIP-30 duplicate txids: later height wins.
// Index-free signature so catch-up can share it.
c_txloc_scan :: proc(
	db: ^munin.Db,
	files: []Blk_File,
	file_index: map[u32]int,
	files_mu: ^sync.Mutex,
	txid: [32]u8,
) -> (
	loc: Txloc_Value,
	found: bool,
	err: Error,
) {
	txid := txid
	bucket := munin.bucket_of(txid[:], db.cfg.bucket_bits) or_return
	it := munin.iter_make_bucket(db, bucket, context.temp_allocator)
	defer {
		munin.iter_close(it)
		free(it, context.temp_allocator)
	}
	munin.iter_seek(it, txid[:8]) or_return
	scan_scratch := make([dynamic]byte, context.temp_allocator)
	for munin.iter_valid(it) {
		key := munin.iter_key(it)
		if !bytes.has_prefix(key, txid[:8]) {
			break
		}
		cand := c_txloc_decode(key, munin.iter_value(it))
		ok := c_txid_at(files, file_index, files_mu, cand, txid, &scan_scratch) or_return
		if ok && (!found || cand.height > loc.height) {
			loc = cand
			found = true
		}
		munin.iter_next(it) or_return
	}
	return loc, found, nil
}

// c_txid_at reads the tx bytes at a candidate location and checks their
// txid against the wanted one.
// scratch is CALLER-OWNED: this runs once per prefix candidate inside a
// scan, and each call de-obfuscates a whole block on a Core v28+ datadir.
@(private = "file")
c_txid_at :: proc(
	files: []Blk_File,
	file_index: map[u32]int,
	files_mu: ^sync.Mutex,
	loc: Txloc_Value,
	want: [32]u8,
	scratch: ^[dynamic]byte,
) -> (
	ok: bool,
	err: Error,
) {
	fi, fok := file_index[u32(loc.file_no)]
	if !fok {
		return false, Corruption.Truncated
	}
	{
		sync.mutex_lock(files_mu)
		defer sync.mutex_unlock(files_mu)
		blkfile_map(&files[fi]) or_return
	}
	raw := blk_payload_bytes(&files[fi], loc.offset, loc.length, scratch) or_return
	tx, consumed := tx_parse(raw, false)
	if consumed == 0 {
		return false, Corruption.Bad_Transaction
	}
	return tx.txid == want, nil
}

// c_read_block maps and returns the block payload at a height.
@(private = "file")
c_read_block :: proc(idx: ^Index, height: u32, deobf: ^[dynamic]byte) -> (block: []byte, err: Error) {
	if int(height) >= len(idx.chain) {
		return nil, Corruption.Bad_Record
	}
	hdr := &idx.chain[height]
	fi, fok := idx.file_index[hdr.file_no]
	if !fok {
		return nil, Corruption.Truncated
	}
	f := &idx.files[fi]
	index_map_file(idx, f) or_return
	return blk_payload_bytes(f, hdr.offset, hdr.length, deobf)
}

@(private = "file")
C_History_Cand :: struct {
	height:    u32,
	txnum:     u32,
	direction: u8,
	io_index:  u32,
}

// c_history_resolved is the compact query_history_resolved: scan the
// main body's sh8 prefix, verify and enrich each candidate from the
// chain (amounts and txids recovered by reading), then append the recent
// tier's exact entries.
c_history_resolved :: proc(
	idx: ^Index,
	sh: [32]u8,
	from_height: u32,
	limit: int,
	allocator := context.allocator,
) -> (
	out: []Resolved_History_Entry,
	err: Error,
) {
	sh := sh
	res := make([dynamic]Resolved_History_Entry, allocator)
	defer if err != nil {delete(res)}

	// --- main body candidates -------------------------------------------
	cands := make([dynamic]C_History_Cand, context.temp_allocator)
	{
		bucket := munin.bucket_of(sh[:], idx.db_history.cfg.bucket_bits) or_return
		it := munin.iter_make_bucket(idx.db_history, bucket, context.temp_allocator)
		defer {
			munin.iter_close(it)
			free(it, context.temp_allocator)
		}
		seek: [12]byte
		copy(seek[0:8], sh[:8])
		put_u32be(seek[8:], from_height)
		munin.iter_seek(it, seek[:]) or_return
		for munin.iter_valid(it) {
			key := munin.iter_key(it)
			if !bytes.has_prefix(key, sh[:8]) {
				break
			}
			h, txnum, dir, io := c_history_key_decode(key)
			append(&cands, C_History_Cand{height = h, txnum = txnum, direction = dir, io_index = io})
			munin.iter_next(it) or_return
		}
	}

	// --- verify and enrich, one block walk per distinct height ----------
	// Two reused buffers for the whole scan: one for the block being
	// walked, one for prevout lookups. Per-call buffers would grow without
	// bound across a deep address.
	deobf := make([dynamic]byte, context.temp_allocator)
	prevout_scratch := make([dynamic]byte, context.temp_allocator)
	i := 0
	verify: for i < len(cands) {
		if limit >= 0 && len(res) >= limit {
			break
		}
		height := cands[i].height
		block := c_read_block(idx, height, &deobf) or_return
		it: Tx_Iter
		tx_iter_init(&it, block) or_return
		it.skip_txid = true
		cacheable := txid_cacheable(idx, height)
		cur_txnum := -1
		cur_raw: []byte
		for i < len(cands) && cands[i].height == height {
			c := cands[i]
			i += 1
			target := int(c.txnum)
			for cur_txnum < target {
				tx, ok := tx_iter_next(&it)
				if !ok {
					if it.err != nil {
						return res[:], it.err
					}
					return res[:], Corruption.Bad_Record
				}
				cur_txnum = it.index - 1
				cur_raw = tx.raw
			}
			ptx, consumed := tx_parse(cur_raw, cur_txnum == 0)
			if consumed == 0 {
				return res[:], Corruption.Bad_Transaction
			}
			if cacheable {
				txid_cache_put(idx, height, c.txnum, ptx.txid)
			}

			entry := Resolved_History_Entry {
				entry = History_Entry {
					height    = c.height,
					txnum     = c.txnum,
					direction = c.direction,
					io_index  = c.io_index,
				},
				txid = ptx.txid,
			}

			if c.direction == DIRECTION_FUNDING {
				oit: Tx_Output_Iter
				tx_output_iter_init(&oit, &ptx)
				matched := false
				for {
					o, vout, ook := tx_output_iter_next(&oit)
					if !ook {break}
					if u32(vout) != c.io_index {continue}
					if scripthash(o.script) == sh {
						entry.entry.amount = o.value
						matched = true
					}
					break
				}
				if !matched {
					continue // prefix collision: another script's row
				}
			} else {
				iit: Tx_Input_Iter
				tx_input_iter_init(&iit, &ptx)
				matched := false
				for {
					inp, vin, iok := tx_input_iter_next(&iit)
					if !iok {break}
					if u32(vin) != c.io_index {continue}
					ploc, pfound := c_txloc_scan(
						idx.db_txloc,
						idx.files,
						idx.file_index,
						&idx.files_mu,
						inp.prev_txid,
					) or_return
					if !pfound {
						// The spent output must be older than this spend,
						// so it lives in the main body of a healthy index.
						return res[:], Corruption.Unknown_Outpoint
					}
					psh, pamount, perr := c_output_at(idx, ploc, inp.vout, &prevout_scratch)
					if perr != nil {
						return res[:], perr
					}
					if psh == sh {
						entry.entry.amount = pamount
						matched = true
					}
					break
				}
				if !matched {
					continue // prefix collision
				}
			}
			append(&res, entry)
			if limit >= 0 && len(res) >= limit {
				break verify
			}
		}
	}

	// --- recent tier: exact rows, appended in order ----------------------
	if idx.recent != nil {
		tit: munin.Iter
		munin.iter_init(&tit, context.temp_allocator)
		defer munin.iter_close(&tit)
		cur := Recent_Cursor {
			rt = idx.recent,
		}
		munin.iter_add_source(&tit, recent_history_source(&cur))
		seek: [36]byte
		copy(seek[0:32], sh[:])
		put_u32be(seek[32:], from_height)
		munin.iter_seek(&tit, seek[:]) or_return
		for munin.iter_valid(&tit) {
			if limit >= 0 && len(res) >= limit {
				break
			}
			key := munin.iter_key(&tit)
			if !bytes.has_prefix(key, sh[:]) {
				break
			}
			row := history_key_decode(key)
			txid := resolve_txid_at(idx, row.height, row.txnum) or_return
			append(
				&res,
				Resolved_History_Entry {
					entry = History_Entry {
						height    = row.height,
						txnum     = row.txnum,
						direction = row.direction,
						io_index  = row.io_index,
						amount    = history_value_decode(munin.iter_value(&tit)),
					},
					txid = txid,
				},
			)
			munin.iter_next(&tit) or_return
		}
	}
	return res[:], nil
}

// c_output_at reads the tx at a verified location and returns one
// output's scripthash and amount.
@(private = "file")
c_output_at :: proc(
	idx: ^Index,
	loc: Txloc_Value,
	vout: u32,
	scratch: ^[dynamic]byte, // caller-owned; reused across a scan
) -> (
	sh: [32]u8,
	amount: u64,
	err: Error,
) {
	fi, fok := idx.file_index[u32(loc.file_no)]
	if !fok {
		return {}, 0, Corruption.Truncated
	}
	f := &idx.files[fi]
	index_map_file(idx, f) or_return
	raw := blk_payload_bytes(f, loc.offset, loc.length, scratch) or_return
	return output_of_raw_tx(raw, vout)
}

// c_spends_lookup is the compact spends_lookup main-body path: scan the
// txid8|vout prefix, verify each candidate spender actually spends the
// full outpoint.
c_spends_lookup :: proc(
	idx: ^Index,
	txid: [32]u8,
	vout: u32,
) -> (
	sv: Spend_Value,
	found: bool,
	err: Error,
) {
	txid := txid
	bucket := munin.bucket_of(txid[:], idx.db_spends.cfg.bucket_bits) or_return
	it := munin.iter_make_bucket(idx.db_spends, bucket, context.temp_allocator)
	defer {
		munin.iter_close(it)
		free(it, context.temp_allocator)
	}
	prefix: [12]byte
	copy(prefix[0:8], txid[:8])
	put_u32be(prefix[8:], vout)
	munin.iter_seek(it, prefix[:]) or_return
	deobf := make([dynamic]byte, context.temp_allocator)
	for munin.iter_valid(it) {
		key := munin.iter_key(it)
		if !bytes.has_prefix(key, prefix[:]) {
			break
		}
		_, height, txnum, vin := c_spends_key_decode(key)
		// Verify: walk to the spender and check its input's outpoint.
		block := c_read_block(idx, height, &deobf) or_return
		bit: Tx_Iter
		tx_iter_init(&bit, block) or_return
		bit.skip_txid = true
		matched := false
		for {
			tx, ok := tx_iter_next(&bit)
			if !ok {break}
			if u32(bit.index - 1) != txnum {continue}
			iit: Tx_Input_Iter
			tx_input_iter_init(&iit, &tx)
			for {
				inp, ivin, iok := tx_input_iter_next(&iit)
				if !iok {break}
				if u32(ivin) != vin {continue}
				matched = inp.prev_txid == txid && inp.vout == vout
				break
			}
			break
		}
		if bit.err != nil {
			return {}, false, bit.err
		}
		if matched {
			return Spend_Value{height = height, txnum = txnum, vin = vin}, true, nil
		}
		munin.iter_next(it) or_return
	}
	return {}, false, nil
}

// query_history_count bounds guard checks without resolving anything:
// exact indexes count rows; compact indexes count unverified prefix
// candidates (an upper bound, which is what a guard wants).
query_history_count :: proc(idx: ^Index, sh: [32]u8) -> (count: int, err: Error) {
	sh := sh
	if !idx.compact {
		entries := query_history(idx, sh, 0, -1, context.temp_allocator) or_return
		return len(entries), nil
	}
	bucket := munin.bucket_of(sh[:], idx.db_history.cfg.bucket_bits) or_return
	it := munin.iter_make_bucket(idx.db_history, bucket, context.temp_allocator)
	defer {
		munin.iter_close(it)
		free(it, context.temp_allocator)
	}
	munin.iter_seek(it, sh[:8]) or_return
	for munin.iter_valid(it) {
		if !bytes.has_prefix(munin.iter_key(it), sh[:8]) {
			break
		}
		count += 1
		munin.iter_next(it) or_return
	}
	if idx.recent != nil {
		tit: munin.Iter
		munin.iter_init(&tit, context.temp_allocator)
		defer munin.iter_close(&tit)
		cur := Recent_Cursor {
			rt = idx.recent,
		}
		munin.iter_add_source(&tit, recent_history_source(&cur))
		munin.iter_seek(&tit, sh[:]) or_return
		for munin.iter_valid(&tit) {
			if !bytes.has_prefix(munin.iter_key(&tit), sh[:]) {
				break
			}
			count += 1
			munin.iter_next(&tit) or_return
		}
	}
	return count, nil
}
