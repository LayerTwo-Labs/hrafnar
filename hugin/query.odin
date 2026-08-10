package hugin

// Query layer: balance, history, tx lookup, outpoint spend lookup.
//
// Reads merge the Munin main body with the recent tier (when attached), so
// blocks inside the reorg horizon are included.

import "base:runtime"
import "core:bytes"
import "core:fmt"

import "core:sync"

import munin "../munin"

Index :: struct {
	cfg:        Config,
	db_history: ^munin.Db,
	db_txloc:   ^munin.Db,
	db_spends:  ^munin.Db,
	chain:      []Stored_Header,
	files:      []Blk_File, // mapped lazily, for tx retrieval
	file_index: map[u32]int,
	recent:     ^Recent_Tier, // nil until catch-up attaches one
	allocator:  runtime.Allocator,

	compact: bool, // on-disk row format (from the FORMAT file via cfg)

	// Concurrent queries: an Index generation is immutable once opened;
	// these guard the only lazily-mutated pieces.
	refs:          int, // atomic; index_release closes at zero
	files_mu:      sync.Mutex, // lazy blkfile mmap
	txid_cache_mu: sync.Mutex,
	hash_index:    map[[32]u8]u32, // block hash -> height, built lazily (esplora)
	hash_index_mu: sync.Mutex,

	// (height, txnum) -> txid, two flip-flop generations: inserts go to
	// the current one; when it fills, it becomes the previous and lookups
	// still see it. Entries are only added below the reorg horizon, so a
	// cached txid can never go stale.
	txid_cache:      map[u64][32]u8,
	txid_cache_prev: map[u64][32]u8,
}

TXID_CACHE_GEN_CAP :: 1_000_000

txid_cache_get :: proc(idx: ^Index, height, txnum: u32) -> (txid: [32]u8, hit: bool) {
	sync.mutex_lock(&idx.txid_cache_mu)
	defer sync.mutex_unlock(&idx.txid_cache_mu)
	key := u64(height) << 32 | u64(txnum)
	if id, ok := idx.txid_cache[key]; ok {
		return id, true
	}
	if id, ok := idx.txid_cache_prev[key]; ok {
		txid_cache_put_locked(idx, height, txnum, id) // promote to the current generation
		return id, true
	}
	return {}, false
}

// txid_cache_put stores unconditionally; callers guard mutability.
txid_cache_put :: proc(idx: ^Index, height, txnum: u32, txid: [32]u8) {
	sync.mutex_lock(&idx.txid_cache_mu)
	defer sync.mutex_unlock(&idx.txid_cache_mu)
	txid_cache_put_locked(idx, height, txnum, txid)
}

@(private = "file")
txid_cache_put_locked :: proc(idx: ^Index, height, txnum: u32, txid: [32]u8) {
	if len(idx.txid_cache) >= TXID_CACHE_GEN_CAP {
		delete(idx.txid_cache_prev)
		idx.txid_cache_prev = idx.txid_cache
		idx.txid_cache = make(map[u64][32]u8, idx.allocator)
	}
	idx.txid_cache[u64(height) << 32 | u64(txnum)] = txid
}

// txid_cacheable: only blocks at or below the reorg horizon are immutable.
txid_cacheable :: proc(idx: ^Index, height: u32) -> bool {
	return int(height) + int(idx.cfg.horizon) < len(idx.chain)
}

// index_adopt_txid_cache moves a previous generation's txid cache into a
// freshly opened one.
//
// The daemon opens a new Index every time the tip moves, so without this the
// cache started empty roughly every ten minutes and nearly every address
// query paid full price — measured at 1.6s cold versus 0.25s warm on a
// 1,655-transaction address, because resolving a txid means reading (and, on
// a Core v28+ datadir, de-obfuscating ~2MB for) the block it lives in.
//
// Carrying the entries over is safe by an invariant the code already
// enforces: txid_cacheable only admits heights at least `horizon` blocks
// below the tip, and a reorg that deep is refused outright with
// Reorg_Too_Deep. Those (height, txnum) -> txid mappings can never change.
//
// Deliberately NOT carried: Index.hash_index. Block hashes above the horizon
// can be orphaned by an ordinary shallow reorg, so those entries can go
// stale — the horizon guard that makes the txid cache safe has no equivalent
// there.
index_adopt_txid_cache :: proc(new_idx: ^Index, old: ^Index) {
	if new_idx == nil || old == nil || new_idx == old {
		return
	}
	// Take them from the old generation rather than copying: it may still be
	// serving in-flight queries, which simply miss and recompute. Odin maps
	// carry their own allocator, so the new owner frees them correctly.
	sync.mutex_lock(&old.txid_cache_mu)
	cur := old.txid_cache
	prev := old.txid_cache_prev
	old.txid_cache = nil
	old.txid_cache_prev = nil
	sync.mutex_unlock(&old.txid_cache_mu)

	sync.mutex_lock(&new_idx.txid_cache_mu)
	delete(new_idx.txid_cache)
	delete(new_idx.txid_cache_prev)
	new_idx.txid_cache = cur
	new_idx.txid_cache_prev = prev
	sync.mutex_unlock(&new_idx.txid_cache_mu)
}

index_open :: proc(cfg: Config, allocator := context.allocator) -> (idx: ^Index, err: Error) {
	cfg := config_fill_defaults(cfg)
	format_check(cfg) or_return
	idx = new(Index, allocator)
	idx.cfg = cfg
	idx.allocator = allocator
	idx.file_index = make(map[u32]int, allocator)
	idx.txid_cache = make(map[u64][32]u8, allocator)
	idx.txid_cache_prev = make(map[u64][32]u8, allocator)
	idx.refs = 1
	idx.compact = cfg.compact
	defer if err != nil {
		index_close(idx)
		idx = nil
	}

	idx.db_history = munin.db_open(fmt.tprintf("%s/history", cfg.index_dir), allocator) or_return
	idx.db_txloc = munin.db_open(fmt.tprintf("%s/txloc", cfg.index_dir), allocator) or_return
	idx.db_spends = munin.db_open(fmt.tprintf("%s/spends", cfg.index_dir), allocator) or_return
	idx.chain = headers_store_read(cfg.index_dir, allocator) or_return

	idx.files = blkfile_enumerate(cfg.datadir, allocator) or_return
	for &f, i in idx.files {
		idx.file_index[f.file_no] = i
	}

	// Attach the recent tier so queries include blocks inside the horizon.
	idx.recent = recent_open(cfg.index_dir, allocator) or_return
	return idx, nil
}

index_close :: proc(idx: ^Index) {
	if idx == nil {return}
	if idx.recent != nil {recent_close(idx.recent)}
	if idx.db_history != nil {munin.db_close(idx.db_history)}
	if idx.db_txloc != nil {munin.db_close(idx.db_txloc)}
	if idx.db_spends != nil {munin.db_close(idx.db_spends)}
	delete(idx.chain, idx.allocator)
	if idx.files != nil {blkfiles_destroy(idx.files, idx.allocator)}
	delete(idx.file_index)
	delete(idx.txid_cache)
	delete(idx.txid_cache_prev)
	delete(idx.hash_index)
	free(idx, idx.allocator)
}

index_tip_height :: proc(idx: ^Index) -> int {
	return len(idx.chain) - 1
}

// index_acquire/index_release: worker threads hold a generation across
// daemon refreshes; the last release closes it.
index_acquire :: proc(idx: ^Index) {
	sync.atomic_add(&idx.refs, 1)
}

index_release :: proc(idx: ^Index) {
	if sync.atomic_sub(&idx.refs, 1) == 1 {
		index_close(idx)
	}
}

// Index_Slot publishes the current generation to worker threads.
Index_Slot :: struct {
	mu:  sync.Mutex,
	cur: ^Index,
}

index_slot_get :: proc(slot: ^Index_Slot) -> ^Index {
	sync.mutex_lock(&slot.mu)
	idx := slot.cur
	index_acquire(idx)
	sync.mutex_unlock(&slot.mu)
	return idx
}

index_slot_swap :: proc(slot: ^Index_Slot, new_idx: ^Index) {
	sync.mutex_lock(&slot.mu)
	old := slot.cur
	slot.cur = new_idx
	sync.mutex_unlock(&slot.mu)
	if old != nil {
		index_release(old)
	}
}

// index_map_file serializes lazy mmaps; the mapping is immutable after.
index_map_file :: proc(idx: ^Index, f: ^Blk_File) -> Error {
	sync.mutex_lock(&idx.files_mu)
	defer sync.mutex_unlock(&idx.files_mu)
	return blkfile_map(f)
}

// ---------------------------------------------------------------------------

// history_iter_make opens a merging iterator over the scripthash's bucket
// of the history keyspace (the prefix determines the bucket, so no other
// run can hold its rows), plus the recent tier when attached. The cursor
// must outlive the iterator (stack allocation at the call site is fine).
@(private = "file")
history_iter_make :: proc(idx: ^Index, sh: [32]u8, cur: ^Recent_Cursor) -> ^munin.Iter {
	sh := sh
	bucket, _ := munin.bucket_of(sh[:], idx.db_history.cfg.bucket_bits)
	it := munin.iter_make_bucket(idx.db_history, bucket, idx.allocator)
	if idx.recent != nil {
		cur.rt = idx.recent
		munin.iter_add_source(it, recent_history_source(cur))
	}
	return it
}

// query_balance computes sum(funding) - sum(spends) over the scripthash's
// prefix scan. O(history length).
query_balance :: proc(idx: ^Index, sh: [32]u8) -> (balance: i64, err: Error) {
	if idx.compact {
		resolved := c_history_resolved(idx, sh, 0, -1, context.temp_allocator) or_return
		for &r in resolved {
			if r.entry.direction == DIRECTION_FUNDING {
				balance += i64(r.entry.amount)
			} else {
				balance -= i64(r.entry.amount)
			}
		}
		return balance, nil
	}
	sh := sh
	cur: Recent_Cursor
	it := history_iter_make(idx, sh, &cur)
	defer {
		munin.iter_close(it)
		free(it, idx.allocator)
	}

	munin.iter_seek(it, sh[:]) or_return
	for munin.iter_valid(it) {
		key := munin.iter_key(it)
		if !bytes.has_prefix(key, sh[:]) {
			break
		}
		amount := i64(history_value_decode(munin.iter_value(it)))
		if history_key_decode(key).direction == DIRECTION_FUNDING {
			balance += amount
		} else {
			balance -= amount
		}
		munin.iter_next(it) or_return
	}
	return balance, nil
}

History_Entry :: struct {
	height:    u32,
	txnum:     u32,
	direction: u8,
	io_index:  u32,
	amount:    u64,
}

// query_history returns the address's rows in chronological order,
// starting at from_height, at most limit entries (negative = all).
query_history :: proc(
	idx: ^Index,
	sh: [32]u8,
	from_height: u32 = 0,
	limit: int = -1,
	allocator := context.allocator,
) -> (
	entries: []History_Entry,
	err: Error,
) {
	if idx.compact {
		// Exact-row iteration does not exist on a compact index; the
		// resolved variant recovers everything from the chain.
		return nil, Usage_Error.Bad_Config
	}
	sh := sh
	cur: Recent_Cursor
	it := history_iter_make(idx, sh, &cur)
	defer {
		munin.iter_close(it)
		free(it, idx.allocator)
	}

	out := make([dynamic]History_Entry, allocator)
	defer if err != nil {delete(out)}

	seek: [36]byte
	copy(seek[0:32], sh[:])
	put_u32be(seek[32:], from_height)
	munin.iter_seek(it, seek[:]) or_return

	for munin.iter_valid(it) {
		key := munin.iter_key(it)
		if !bytes.has_prefix(key, sh[:]) {
			break
		}
		if limit >= 0 && len(out) >= limit {
			break
		}
		row := history_key_decode(key)
		append(
			&out,
			History_Entry {
				height    = row.height,
				txnum     = row.txnum,
				direction = row.direction,
				io_index  = row.io_index,
				amount    = history_value_decode(munin.iter_value(it)),
			},
		)
		munin.iter_next(it) or_return
	}
	return out[:], nil
}

Resolved_History_Entry :: struct {
	entry: History_Entry,
	txid:  [32]u8,
}

// query_history_resolved is query_history plus txid resolution. Entries
// arrive sorted by (height, txnum), so each distinct height costs exactly
// one block read, walked forward once.
query_history_resolved :: proc(
	idx: ^Index,
	sh: [32]u8,
	from_height: u32 = 0,
	limit: int = -1,
	allocator := context.allocator,
) -> (
	out: []Resolved_History_Entry,
	err: Error,
) {
	if idx.compact {
		return c_history_resolved(idx, sh, from_height, limit, allocator)
	}
	entries := query_history(idx, sh, from_height, limit, context.temp_allocator) or_return
	out = make([]Resolved_History_Entry, len(entries), allocator)
	defer if err != nil {delete(out, allocator)}

	// One scratch buffer for the whole scan. On XOR-obfuscated datadirs
	// (Core v28+) every block read COPIES the block here — allocating per
	// height instead would burn ~2MB per distinct height and OOM-kill the
	// process on a deep address. (Plain datadirs read zero-copy, which is
	// why synthetic tests never saw this.)
	scratch := make([dynamic]byte, context.temp_allocator)
	i := 0
	for i < len(entries) {
		height := entries[i].height
		if int(height) >= len(idx.chain) {
			return out, Corruption.Bad_Record
		}

		// Cache pass: resolve what we can without touching the block.
		j := i
		all_cached := true
		for j < len(entries) && entries[j].height == height {
			if id, hit := txid_cache_get(idx, height, entries[j].txnum); hit {
				out[j] = Resolved_History_Entry{entry = entries[j], txid = id}
			} else {
				all_cached = false
			}
			j += 1
		}
		if all_cached {
			i = j
			continue
		}

		hdr := &idx.chain[height]
		fi, fok := idx.file_index[hdr.file_no]
		if !fok {
			return out, Corruption.Truncated
		}
		f := &idx.files[fi]
		index_map_file(idx, f) or_return
		block := blk_payload_bytes(f, hdr.offset, hdr.length, &scratch) or_return

		// Walk hash-free; only target transactions get their txid computed
		// (and cached, when below the reorg horizon).
		it: Tx_Iter
		tx_iter_init(&it, block) or_return
		it.skip_txid = true
		cacheable := txid_cacheable(idx, height)
		cur_txnum := -1
		cur_raw: []byte
		cur_txid: [32]u8
		cur_hashed := false
		for i < j {
			target := int(entries[i].txnum)
			for cur_txnum < target {
				tx, ok := tx_iter_next(&it)
				if !ok {
					if it.err != nil {
						return out, it.err
					}
					// The index names a txnum past the block's end.
					return out, Corruption.Bad_Record
				}
				cur_txnum = it.index - 1
				cur_raw = tx.raw
				cur_hashed = false
			}
			if !cur_hashed {
				if id, hit := txid_cache_get(idx, height, u32(cur_txnum)); hit {
					cur_txid = id
				} else {
					ptx, _ := tx_parse(cur_raw, cur_txnum == 0)
					cur_txid = ptx.txid
					if cacheable {
						txid_cache_put(idx, height, u32(cur_txnum), cur_txid)
					}
				}
				cur_hashed = true
			}
			out[i] = Resolved_History_Entry {
				entry = entries[i],
				txid  = cur_txid,
			}
			i += 1
		}
	}
	return out, nil
}

Utxo :: struct {
	txid:   [32]u8,
	vout:   u32,
	height: u32,
	amount: u64,
}

// query_utxos lists the address's unspent outputs: every funding entry
// whose outpoint has no row in the spends keyspace (main body or recent
// tier). sum(utxos) always equals query_balance.
query_utxos :: proc(
	idx: ^Index,
	sh: [32]u8,
	allocator := context.allocator,
) -> (
	utxos: []Utxo,
	err: Error,
) {
	resolved := query_history_resolved(idx, sh, 0, -1, context.temp_allocator) or_return

	out := make([dynamic]Utxo, allocator)
	defer if err != nil {delete(out)}

	key: [SPENDS_KEY_LEN]byte
	for &r in resolved {
		if r.entry.direction != DIRECTION_FUNDING {
			continue
		}
		copy(key[0:32], r.txid[:])
		put_u32be(key[32:], r.entry.io_index)
		_, spent := spends_lookup(idx, key) or_return
		if spent {
			continue
		}
		append(
			&out,
			Utxo {
				txid   = r.txid,
				vout   = r.entry.io_index,
				height = r.entry.height,
				amount = r.entry.amount,
			},
		)
	}
	return out[:], nil
}

// query_header returns the stored header record at a height.
query_header :: proc(idx: ^Index, height: u32) -> (hdr: ^Stored_Header, ok: bool) {
	if int(height) >= len(idx.chain) {
		return nil, false
	}
	return &idx.chain[height], true
}

// spends_lookup probes the spends keyspace (main body, then recent tier).
spends_lookup :: proc(
	idx: ^Index,
	key: [SPENDS_KEY_LEN]byte,
) -> (
	sv: Spend_Value,
	found: bool,
	err: Error,
) {
	key := key
	if idx.compact {
		txid: [32]u8
		copy(txid[:], key[0:32])
		sv_c, cfound := c_spends_lookup(idx, txid, get_u32be(key[32:])) or_return
		if cfound {
			return sv_c, true, nil
		}
	} else {
		value, vfound, gerr := munin.db_get(idx.db_spends, key[:], context.temp_allocator)
		if gerr != nil {
			return {}, false, gerr
		}
		if vfound {
			return spends_value_decode(value), true, nil
		}
	}
	if idx.recent != nil {
		rspend, rfound := recent_lookup_spend(idx.recent, key)
		return rspend, rfound, nil
	}
	return {}, false, nil
}

// query_tx returns the raw transaction bytes — straight out of the
// mmapped blk file on plain datadirs, de-obfuscated into an internal
// scratch buffer on XORed ones. Borrowed either way: valid until the next
// query_tx call or index_close.
query_tx :: proc(
	idx: ^Index,
	txid: [32]u8,
	scratch: ^[dynamic]byte = nil, // caller-owned buffer; loops MUST pass one
) -> (
	raw: []byte,
	height: u32,
	found: bool,
	err: Error,
) {
	txid := txid
	loc, lfound := txloc_lookup(idx, txid) or_return
	if !lfound {
		return nil, 0, false, nil
	}

	fi, fok := idx.file_index[u32(loc.file_no)]
	if !fok {
		return nil, 0, false, Corruption.Truncated
	}
	f := &idx.files[fi]
	index_map_file(idx, f) or_return
	buf := scratch
	if buf == nil {
		buf = new([dynamic]byte, context.temp_allocator)
		buf^ = make([dynamic]byte, context.temp_allocator)
	}
	raw = blk_payload_bytes(f, loc.offset, loc.length, buf) or_return
	return raw, loc.height, true, nil
}

Outpoint_Spend :: struct {
	spender_txid: [32]u8,
	height:       u32,
	txnum:        u32,
	vin:          u32,
}

// index_output resolves a confirmed output to its scripthash and amount
// (used by the mempool tier to value the outputs unconfirmed transactions
// spend).
index_output :: proc(
	idx: ^Index,
	txid: [32]u8,
	vout: u32,
) -> (
	sh: [32]u8,
	amount: u64,
	found: bool,
	err: Error,
) {
	raw, _, tfound := query_tx(idx, txid) or_return
	if !tfound {
		return {}, 0, false, nil
	}
	tx, consumed := tx_parse(raw, false)
	if consumed == 0 {
		return {}, 0, false, Corruption.Bad_Transaction
	}
	oit: Tx_Output_Iter
	tx_output_iter_init(&oit, &tx)
	for {
		out, v, ok := tx_output_iter_next(&oit)
		if !ok {break}
		if u32(v) == vout {
			return scripthash(out.script), out.value, true, nil
		}
	}
	return {}, 0, false, nil
}

// query_outpoint answers "is this output spent, and by what." The spends
// keyspace stores only (height, txnum, vin); the spender's txid is
// recovered here with one block read.
query_outpoint :: proc(
	idx: ^Index,
	txid: [32]u8,
	vout: u32,
) -> (
	spend: Outpoint_Spend,
	found: bool,
	err: Error,
) {
	txid := txid
	key: [SPENDS_KEY_LEN]byte
	copy(key[0:32], txid[:])
	put_u32be(key[32:], vout)

	sv, sfound := spends_lookup(idx, key) or_return
	if !sfound {
		return {}, false, nil
	}

	spender := resolve_txid_at(idx, sv.height, sv.txnum) or_return
	return Outpoint_Spend {
			spender_txid = spender,
			height       = sv.height,
			txnum        = sv.txnum,
			vin          = sv.vin,
		},
		true,
		nil
}

// txloc_lookup resolves a full txid to its location: recent tier first
// (exact rows), then the main body — direct get on exact indexes, a
// verified prefix scan on compact ones.
txloc_lookup :: proc(idx: ^Index, txid: [32]u8) -> (loc: Txloc_Value, found: bool, err: Error) {
	txid := txid
	if idx.recent != nil {
		if rloc, rfound := recent_lookup_txloc(idx.recent, txid); rfound {
			return rloc, true, nil
		}
	}
	if idx.compact {
		return c_txloc_scan(idx.db_txloc, idx.files, idx.file_index, &idx.files_mu, txid)
	}
	value, vfound, gerr := munin.db_get(idx.db_txloc, txid[:], context.temp_allocator)
	if gerr != nil {
		return {}, false, gerr
	}
	if !vfound {
		return {}, false, nil
	}
	return txloc_value_decode(value), true, nil
}

// resolve_txid_at reads the block at a height and walks to the txnum-th
// transaction. An index that names a (height, txnum) that does not exist
// is corrupt — that must surface, never be guessed around.
resolve_txid_at :: proc(idx: ^Index, height: u32, txnum: u32) -> (txid: [32]u8, err: Error) {
	if id, hit := txid_cache_get(idx, height, txnum); hit {
		return id, nil
	}
	if int(height) >= len(idx.chain) {
		return {}, Corruption.Bad_Record
	}
	hdr := &idx.chain[height]
	fi, fok := idx.file_index[hdr.file_no]
	if !fok {
		return {}, Corruption.Truncated
	}
	f := &idx.files[fi]
	index_map_file(idx, f) or_return
	scratch := make([dynamic]byte, context.temp_allocator)
	block := blk_payload_bytes(f, hdr.offset, hdr.length, &scratch) or_return

	it: Tx_Iter
	tx_iter_init(&it, block) or_return
	it.skip_txid = true
	for {
		tx, ok := tx_iter_next(&it)
		if !ok {break}
		if u32(it.index - 1) == txnum {
			ptx, _ := tx_parse(tx.raw, it.index - 1 == 0)
			if txid_cacheable(idx, height) {
				txid_cache_put(idx, height, txnum, ptx.txid)
			}
			return ptx.txid, nil
		}
	}
	if it.err != nil {
		return {}, it.err
	}
	return {}, Corruption.Bad_Record
}

// query_merkle builds the merkle branch proving a transaction's inclusion
// in its block (leaf-to-root, Bitcoin's duplicate-last rule for odd
// levels) and verifies the fold against the header's merkle root before
// returning — a proof this index cannot back is Corruption, not a guess.
query_merkle :: proc(
	idx: ^Index,
	txid: [32]u8,
	allocator := context.allocator,
) -> (
	height: u32,
	pos: u32,
	branch: [][32]u8,
	found: bool,
	err: Error,
) {
	txid := txid
	loc, lfound := txloc_lookup(idx, txid) or_return
	if !lfound {
		return 0, 0, nil, false, nil
	}
	height = loc.height
	if int(height) >= len(idx.chain) {
		return 0, 0, nil, false, Corruption.Bad_Record
	}
	hdr := &idx.chain[height]
	fi, fok := idx.file_index[hdr.file_no]
	if !fok {
		return 0, 0, nil, false, Corruption.Truncated
	}
	f := &idx.files[fi]
	if merr := index_map_file(idx, f); merr != nil {
		return 0, 0, nil, false, merr
	}
	scratch := make([dynamic]byte, context.temp_allocator)
	block, berr := blk_payload_bytes(f, hdr.offset, hdr.length, &scratch)
	if berr != nil {
		return 0, 0, nil, false, berr
	}

	ids := make([dynamic][32]u8, context.temp_allocator)
	tpos := -1
	it: Tx_Iter
	if ierr := tx_iter_init(&it, block); ierr != nil {
		return 0, 0, nil, false, ierr
	}
	for {
		tx, ok := tx_iter_next(&it)
		if !ok {break}
		if tx.txid == txid {
			tpos = len(ids)
		}
		append(&ids, tx.txid)
	}
	if it.err != nil {
		return 0, 0, nil, false, it.err
	}
	if tpos < 0 {
		return 0, 0, nil, false, Corruption.Bad_Record
	}
	pos = u32(tpos)

	out := make([dynamic][32]u8, allocator)
	level := ids
	p := tpos
	for len(level) > 1 {
		sib := p ~ 1
		if sib >= len(level) {
			sib = p
		}
		append(&out, level[sib])
		next := make([dynamic][32]u8, context.temp_allocator)
		i := 0
		for i < len(level) {
			a := level[i]
			b := level[min(i + 1, len(level) - 1)]
			append(&next, sha256d_parts({a[:], b[:]}))
			i += 2
		}
		level = next
		p >>= 1
	}
	mroot: [32]u8
	copy(mroot[:], hdr.raw[36:68])
	if level[0] != mroot {
		delete(out)
		return 0, 0, nil, false, Corruption.Bad_Record
	}
	return height, pos, out[:], true, nil
}
