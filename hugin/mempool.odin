package hugin

// The mempool tier: unconfirmed transactions held purely in RAM,
// synchronized by diffing bitcoind's mempool (electrs-style). Nothing here
// ever touches the on-disk index; a restart simply resyncs.
//
// Sync is abstracted behind Mempool_Source so tests feed synthetic
// transactions without a node; the RPC-backed source lives at the bottom.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:thread"
import "core:time"
import "core:slice"
import "core:sync"

// One address-visible effect of an unconfirmed transaction.
Mempool_Entry :: struct {
	txid:      [32]u8,
	direction: u8, // DIRECTION_FUNDING / DIRECTION_SPEND
	io_index:  u32,
	amount:    u64,
}

@(private = "file")
Mempool_Tx :: struct {
	raw:     []byte, // owned
	touches: [dynamic]Touched, // effects, for clean eviction
	spends:  [dynamic][SPENDS_KEY_LEN]u8, // outpoints consumed
	fee:     u64, // sum(inputs) - sum(outputs)
	vsize:   int,
}

@(private = "file")
Touched :: struct {
	sh:    [32]u8,
	entry: Mempool_Entry,
}

Mempool :: struct {
	txs:       map[[32]u8]^Mempool_Tx,
	by_sh:     map[[32]u8][dynamic]Mempool_Entry,
	spent:     map[[SPENDS_KEY_LEN]u8][32]u8, // outpoint -> spending txid
	// Transactions whose inputs cannot be resolved yet (they spend
	// unconfirmed parents we have not fetched). Without this they are
	// re-fetched every single cycle forever.
	deferred:  map[[32]u8]u8, // txid -> failed attempts
	allocator: runtime.Allocator,
	// Writers (mempool_sync) take it exclusively; each query request runs
	// under a shared lock for its whole duration.
	lock:      sync.RW_Mutex,
}

// Mempool_Source supplies the current txid set and raw transactions.
// fetch_many returns a parallel array (nil element = unavailable), so a
// backend can batch thousands of fetches into a handful of round trips.
Mempool_Source :: struct {
	user:       rawptr,
	list:       proc(user: rawptr) -> (txids: [][32]u8, ok: bool), // temp-allocated
	fetch_many: proc(user: rawptr, txids: [][32]u8) -> (raws: [][]byte, ok: bool), // temp-allocated
}

mempool_init :: proc(mp: ^Mempool, allocator := context.allocator) {
	mp.txs = make(map[[32]u8]^Mempool_Tx, allocator)
	mp.by_sh = make(map[[32]u8][dynamic]Mempool_Entry, allocator)
	mp.spent = make(map[[SPENDS_KEY_LEN]u8][32]u8, allocator)
	mp.deferred = make(map[[32]u8]u8, allocator)
	mp.allocator = allocator
}

mempool_destroy :: proc(mp: ^Mempool) {
	for _, tx in mp.txs {
		mempool_tx_free(mp, tx)
	}
	delete(mp.txs)
	for _, &lst in mp.by_sh {
		delete(lst)
	}
	delete(mp.by_sh)
	delete(mp.spent)
	delete(mp.deferred)
}

mempool_size :: proc(mp: ^Mempool) -> int {
	return len(mp.txs)
}

@(private = "file")
mempool_tx_free :: proc(mp: ^Mempool, tx: ^Mempool_Tx) {
	delete(tx.raw, mp.allocator)
	delete(tx.touches)
	delete(tx.spends)
	free(tx, mp.allocator)
}

// mempool_sync diffs the source's txid set against the tracked one. At
// most max_new transactions are ingested per call so the caller's serve
// loop is never starved during the initial backfill of a large mempool;
// the remainder is reported as backlog and picked up next cycle.
// Unresolvable transactions (parent not yet visible) are skipped and
// retried next cycle.
MEMPOOL_MAX_INGEST_ATTEMPTS :: 3

mempool_sync :: proc(
	mp: ^Mempool,
	idx: ^Index,
	src: Mempool_Source,
	max_new := 1000,
	touched: ^map[[32]u8]struct {} = nil, // filled with scripthashes whose unconfirmed state changed
) -> (
	added: int,
	removed: int,
	backlog: int,
	err: Error,
) {
	// NOTHING here may hold the write lock across a network call. Readers
	// (query workers) block on it, and the daemon's serve loop calls this
	// on its own thread — so an RPC under the lock freezes ALL I/O for the
	// duration. That is what made a broadcast look like a dead server.
	txids, ok := src.list(src.user)
	if !ok {
		return 0, 0, 0, Usage_Error.Rpc_Unavailable
	}

	current := make(map[[32]u8]struct {}, context.temp_allocator)
	for id in txids {
		current[id] = {}
	}

	// --- phase 1 (locked, no I/O): evict, and decide what to fetch ------
	to_remove := make([dynamic][32]u8, context.temp_allocator)
	new_ids := make([dynamic][32]u8, context.temp_allocator)
	{
		sync.rw_mutex_lock(&mp.lock)
		defer sync.rw_mutex_unlock(&mp.lock)

		for id in mp.txs {
			if id not_in current {
				append(&to_remove, id)
			}
		}
		for id in to_remove {
			mempool_evict(mp, id, touched)
			removed += 1
		}
		for id in txids {
			if id in mp.txs {
				continue
			}
			if att, seen := mp.deferred[id]; seen && att >= MEMPOOL_MAX_INGEST_ATTEMPTS {
				continue // unresolvable for now; mempool_retry_deferred re-arms it
			}
			if len(new_ids) < max_new {
				append(&new_ids, id)
			} else {
				backlog += 1
			}
		}
	}
	if len(new_ids) == 0 {
		return 0, removed, backlog, nil
	}

	// --- phase 2 (UNLOCKED): fetch the raw transactions -----------------
	raws, fok := src.fetch_many(src.user, new_ids[:])
	if !fok || len(raws) != len(new_ids) {
		return 0, removed, backlog, Usage_Error.Rpc_Unavailable
	}

	// --- phase 3 (locked, no I/O): ingest -------------------------------
	sync.rw_mutex_lock(&mp.lock)
	defer sync.rw_mutex_unlock(&mp.lock)

	// Two passes: parents can appear after children in the listing.
	pending := make([dynamic]int, context.temp_allocator)
	for id, i in new_ids {
		if raws[i] == nil {
			continue // vanished between list and fetch; next cycle
		}
		if mempool_ingest(mp, idx, id, raws[i]) {
			added += 1
			delete_key(&mp.deferred, id)
			mempool_mark_touched(mp, id, touched)
		} else {
			append(&pending, i)
		}
	}
	for i in pending {
		if mempool_ingest(mp, idx, new_ids[i], raws[i]) {
			added += 1
			delete_key(&mp.deferred, new_ids[i])
			mempool_mark_touched(mp, new_ids[i], touched)
		} else {
			mp.deferred[new_ids[i]] = min(mp.deferred[new_ids[i]] + 1, 255)
		}
	}
	return added, removed, backlog, nil
}

@(private = "file")
// mempool_retry_deferred clears the give-up list so unresolvable
// transactions get another chance — their parents may have arrived or
// confirmed since.
mempool_retry_deferred :: proc(mp: ^Mempool) {
	sync.rw_mutex_lock(&mp.lock)
	defer sync.rw_mutex_unlock(&mp.lock)
	clear(&mp.deferred)
}

mempool_evict :: proc(mp: ^Mempool, txid: [32]u8, touched: ^map[[32]u8]struct {} = nil) {
	delete_key(&mp.deferred, txid)
	tx, has := mp.txs[txid]
	if !has {
		return
	}
	if touched != nil {
		for &t in tx.touches {
			touched^[t.sh] = {}
		}
	}
	for &t in tx.touches {
		if lst, lok := &mp.by_sh[t.sh]; lok {
			for i := 0; i < len(lst); i += 1 {
				if lst[i].txid == txid && lst[i].io_index == t.entry.io_index && lst[i].direction == t.entry.direction {
					lst[i] = lst[len(lst) - 1]
					resize(lst, len(lst) - 1)
					break
				}
			}
			if len(lst) == 0 {
				lst_copy := lst^
				delete_key(&mp.by_sh, t.sh)
				delete(lst_copy)
			}
		}
	}
	for &op in tx.spends {
		delete_key(&mp.spent, op)
	}
	delete_key(&mp.txs, txid)
	mempool_tx_free(mp, tx)
}

@(private = "file")
mempool_ingest :: proc(mp: ^Mempool, idx: ^Index, txid: [32]u8, raw_tmp: []byte) -> bool {
	tx, consumed := tx_parse(raw_tmp, false)
	if consumed == 0 || tx.txid != txid {
		return false
	}

	mtx := new(Mempool_Tx, mp.allocator)
	mtx.raw = make([]byte, len(raw_tmp), mp.allocator)
	copy(mtx.raw, raw_tmp)
	mtx.touches = make([dynamic]Touched, mp.allocator)
	mtx.spends = make([dynamic][SPENDS_KEY_LEN]u8, mp.allocator)

	// Re-parse against the owned bytes so borrowed slices stay valid.
	tx, _ = tx_parse(mtx.raw, false)

	commit := true
	in_sum, out_sum: u64

	// Outputs: unconfirmed funding entries.
	oit: Tx_Output_Iter
	tx_output_iter_init(&oit, &tx)
	for {
		out, vout, ook := tx_output_iter_next(&oit)
		if !ook {break}
		out_sum += out.value
		sh := scripthash(out.script)
		append(
			&mtx.touches,
			Touched {
				sh = sh,
				entry = Mempool_Entry {
					txid      = txid,
					direction = DIRECTION_FUNDING,
					io_index  = u32(vout),
					amount    = out.value,
				},
			},
		)
	}

	// Inputs: resolve the spent output to (scripthash, amount) via an
	// in-mempool parent or the on-chain index.
	if !tx.is_coinbase {
		iit: Tx_Input_Iter
		tx_input_iter_init(&iit, &tx)
		for {
			inp, vin, iok := tx_input_iter_next(&iit)
			if !iok {break}

			sh, amount, resolved := mempool_resolve_output(mp, idx, inp.prev_txid, inp.vout)
			if !resolved {
				commit = false
				break
			}
			in_sum += amount
			append(
				&mtx.touches,
				Touched {
					sh = sh,
					entry = Mempool_Entry {
						txid      = txid,
						direction = DIRECTION_SPEND,
						io_index  = u32(vin),
						amount    = amount,
					},
				},
			)
			op: [SPENDS_KEY_LEN]u8
			copy(op[0:32], inp.prev_txid[:])
			put_u32be(op[32:], inp.vout)
			append(&mtx.spends, op)
		}
	}

	if !commit {
		mempool_tx_free(mp, mtx)
		return false
	}

	for &t in mtx.touches {
		lst, lok := &mp.by_sh[t.sh]
		if !lok {
			mp.by_sh[t.sh] = make([dynamic]Mempool_Entry, mp.allocator)
			lst = &mp.by_sh[t.sh]
		}
		append(lst, t.entry)
	}
	if in_sum >= out_sum {
		mtx.fee = in_sum - out_sum
	}
	mtx.vsize = tx.vsize
	for &op in mtx.spends {
		mp.spent[op] = txid
	}
	mp.txs[txid] = mtx
	return true
}

Fee_Bin :: struct {
	rate:  f64, // sat/vB of the cheapest transaction in the bin
	vsize: u64, // virtual bytes accumulated in the bin
}

// mempool_fee_histogram groups mempool transactions into ~100 kvB bins by
// descending fee rate — the shape Electrum's get_fee_histogram serves: a
// wallet reads it as "to be within the first N vbytes of the mempool, pay
// at least this rate".
mempool_fee_histogram :: proc(mp: ^Mempool, allocator := context.allocator) -> []Fee_Bin {
	Item :: struct {
		rate:  f64,
		vsize: int,
	}
	items := make([dynamic]Item, context.temp_allocator)
	for _, mtx in mp.txs {
		if mtx.vsize <= 0 {continue}
		append(&items, Item{rate = f64(mtx.fee) / f64(mtx.vsize), vsize = mtx.vsize})
	}
	slice.sort_by(items[:], proc(a, b: Item) -> bool {return a.rate > b.rate})

	bins := make([dynamic]Fee_Bin, allocator)
	acc: u64
	rate: f64
	for it in items {
		acc += u64(it.vsize)
		rate = it.rate
		if acc >= 100_000 {
			append(&bins, Fee_Bin{rate = rate, vsize = acc})
			acc = 0
		}
	}
	if acc > 0 {
		append(&bins, Fee_Bin{rate = rate, vsize = acc})
	}
	return bins[:]
}

// mempool_resolve_output finds the scripthash and amount of an output,
// checking in-mempool parents first, then the on-chain index.
@(private = "file")
mempool_resolve_output :: proc(
	mp: ^Mempool,
	idx: ^Index,
	txid: [32]u8,
	vout: u32,
) -> (
	sh: [32]u8,
	amount: u64,
	resolved: bool,
) {
	if parent, has := mp.txs[txid]; has {
		ptx, consumed := tx_parse(parent.raw, false)
		if consumed == 0 {
			return {}, 0, false
		}
		oit: Tx_Output_Iter
		tx_output_iter_init(&oit, &ptx)
		for {
			out, v, ok := tx_output_iter_next(&oit)
			if !ok {break}
			if u32(v) == vout {
				return scripthash(out.script), out.value, true
			}
		}
		return {}, 0, false
	}

	osh, oamount, found, oerr := index_output(idx, txid, vout)
	if oerr != nil || !found {
		return {}, 0, false
	}
	return osh, oamount, true
}

// ---------------------------------------------------------------------------
// Query surface.

// mempool_delta sums the unconfirmed effect on an address: incoming
// fundings minus outgoing spends.
mempool_delta :: proc(mp: ^Mempool, sh: [32]u8) -> (delta: i64, pending: int) {
	sh := sh
	if lst, ok := mp.by_sh[sh]; ok {
		for e in lst {
			if e.direction == DIRECTION_FUNDING {
				delta += i64(e.amount)
			} else {
				delta -= i64(e.amount)
			}
			pending += 1
		}
	}
	return
}

// mempool_entries lists the unconfirmed entries touching an address
// (temp-allocated view; copy to retain).
mempool_entries :: proc(mp: ^Mempool, sh: [32]u8) -> []Mempool_Entry {
	sh := sh
	if lst, ok := mp.by_sh[sh]; ok {
		return lst[:]
	}
	return nil
}

// mempool_spender reports the unconfirmed transaction spending an
// outpoint, if any.
mempool_spender :: proc(mp: ^Mempool, txid: [32]u8, vout: u32) -> (spender: [32]u8, found: bool) {
	op: [SPENDS_KEY_LEN]u8
	txid := txid
	copy(op[0:32], txid[:])
	put_u32be(op[32:], vout)
	spender, found = mp.spent[op]
	return
}

// ---------------------------------------------------------------------------
// The RPC-backed source.

Rpc_Mempool_Source :: struct {
	rc:  ^Rpc_Client,
}

rpc_mempool_source :: proc(s: ^Rpc_Mempool_Source) -> Mempool_Source {
	return Mempool_Source{user = s, list = rpc_mp_list, fetch_many = rpc_mp_fetch_many}
}

@(private = "file")
rpc_mp_list :: proc(user: rawptr) -> (txids: [][32]u8, ok: bool) {
	s := cast(^Rpc_Mempool_Source)user
	env, err := rpc_call(s.rc, "getrawmempool", "", context.temp_allocator)
	if err != nil {
		return nil, false
	}
	arr, aok := rpc_result(env).(json.Array)
	if !aok {
		return nil, false
	}
	out := make([dynamic][32]u8, context.temp_allocator)
	for v in arr {
		hexs, sok := v.(string)
		if !sok {continue}
		id, idok := txid_from_hex(hexs)
		if !idok {continue}
		append(&out, id)
	}
	return out[:], true
}

@(private = "file")
RPC_FETCH_CHUNK :: 250

@(private = "file")
rpc_mp_fetch_many :: proc(user: rawptr, txids: [][32]u8) -> (raws: [][]byte, ok: bool) {
	s := cast(^Rpc_Mempool_Source)user
	raws = make([][]byte, len(txids), context.temp_allocator)
	hexbuf: [64]byte

	for start := 0; start < len(txids); start += RPC_FETCH_CHUNK {
		end := min(start + RPC_FETCH_CHUNK, len(txids))
		params := make([]string, end - start, context.temp_allocator)
		for i in start ..< end {
			params[i - start] = fmt.tprintf(`["%s",false]`, txid_to_hex(txids[i], hexbuf[:]))
		}
		env, err := rpc_call_batch(s.rc, "getrawtransaction", params, context.temp_allocator)
		if err != nil {
			return nil, false
		}
		arr := env.(json.Array)
		for elem in arr {
			obj, is_obj := elem.(json.Object)
			if !is_obj {continue}
			idf, idok := obj["id"].(json.Float)
			if !idok {continue}
			i := start + int(idf)
			if i < start || i >= end {continue}
			hexs, sok := obj["result"].(string)
			if !sok {continue} // per-tx error (evicted meanwhile): leave nil
			if decoded, dok := hex_decode_temp(hexs); dok {
				raws[i] = decoded
			}
		}
	}
	return raws, true
}

// hex_decode_temp decodes arbitrary-length hex into a temp allocation.
hex_decode_temp :: proc(s: string) -> (out: []byte, ok: bool) {
	if len(s) % 2 != 0 {
		return nil, false
	}
	buf := make([]byte, len(s) / 2, context.temp_allocator)
	for i in 0 ..< len(buf) {
		hi := hexv(s[i * 2])
		lo := hexv(s[i * 2 + 1])
		if hi < 0 || lo < 0 {
			return nil, false
		}
		buf[i] = byte(hi << 4 | lo)
	}
	return buf, true
}

@(private = "file")
hexv :: proc "contextless" (c: byte) -> int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c - 'a' + 10)
	case c >= 'A' && c <= 'F':
		return int(c - 'A' + 10)
	}
	return -1
}


@(private = "file")
mempool_mark_touched :: proc(mp: ^Mempool, txid: [32]u8, touched: ^map[[32]u8]struct {}) {
	if touched == nil {
		return
	}
	if mtx, ok := mp.txs[txid]; ok {
		for &t in mtx.touches {
			touched^[t.sh] = {}
		}
	}
}

// ---------------------------------------------------------------------------
// Mempool runner: the sync loop on its OWN thread.
//
// It used to run inline in the daemon's serve loop, where its several
// seconds of RPC round-trips (a big backfill is ~20 batched calls) blocked
// the one thread that writes responses — so a broadcast could sit
// finished-but-unsent long enough for a wallet to give up. The runner
// keeps that work off the I/O path entirely; the loop only drains the
// touched-scripthash set for push notifications.

Mempool_Runner :: struct {
	mp:        ^Mempool,
	slot:      ^Index_Slot,
	src:       Mempool_Source,
	max_new:   int,
	stop:      bool, // atomic
	mu:        sync.Mutex, // guards the fields below
	touched:   map[[32]u8]struct {}, // accumulated for the serve loop
	dirty:     bool, // something changed since the loop last looked
	allocator: runtime.Allocator,
	thread:    ^thread.Thread,
}

mempool_runner_start :: proc(
	r: ^Mempool_Runner,
	mp: ^Mempool,
	slot: ^Index_Slot,
	src: Mempool_Source,
	max_new := 1000,
	allocator := context.allocator,
) {
	r.mp = mp
	r.slot = slot
	r.src = src
	r.max_new = max_new
	r.allocator = allocator
	r.touched = make(map[[32]u8]struct {}, allocator)
	r.thread = thread.create(mempool_runner_main)
	r.thread.data = r
	r.thread.init_context = context
	thread.start(r.thread)
}

mempool_runner_stop :: proc(r: ^Mempool_Runner) {
	if r.thread == nil {
		return
	}
	sync.atomic_store(&r.stop, true)
	thread.join(r.thread)
	thread.destroy(r.thread)
	r.thread = nil
	delete(r.touched)
}

// mempool_runner_take hands the accumulated touched set to the caller
// (the serve loop) and clears it. Returns false when nothing changed.
mempool_runner_take :: proc(
	r: ^Mempool_Runner,
	out: ^map[[32]u8]struct {},
) -> (
	changed: bool,
) {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	if !r.dirty {
		return false
	}
	for sh in r.touched {
		out^[sh] = {}
	}
	clear(&r.touched)
	r.dirty = false
	return true
}

@(private = "file")
mempool_runner_main :: proc(t: ^thread.Thread) {
	r := (^Mempool_Runner)(t.data)
	// A private temp allocator for this thread. It must be the RUNTIME's
	// default kind, not a mem.Dynamic_Arena: Odin maps (and json.Object,
	// which is a map) require cache-line-aligned allocations, and an arena
	// does not provide that — it panics with "allocation not aligned to a
	// cache line" the moment a map is allocated from it. Inheriting the
	// spawning thread's temp allocator would be worse: two threads on one
	// arena.
	temp_data: runtime.Default_Temp_Allocator
	runtime.default_temp_allocator_init(&temp_data, runtime.DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE, context.allocator)
	defer runtime.default_temp_allocator_destroy(&temp_data)
	context.temp_allocator = runtime.default_temp_allocator(&temp_data)

	warned := time.Time{}
	cycles := 0
	for !sync.atomic_load(&r.stop) {
		idx := index_slot_get(r.slot)
		local := make(map[[32]u8]struct {}, context.temp_allocator)
		added, removed, backlog, err := mempool_sync(r.mp, idx, r.src, r.max_new, &local)
		index_release(idx)

		if err != nil {
			if time.duration_seconds(time.since(warned)) >= 60 {
				warned = time.now()
				log.warnf("hrafnar: mempool sync failing (is bitcoind's RPC reachable?): %v", err)
			}
		} else if (added > 0 || removed > 0) && (backlog > 0 || added >= 100) {
			log.infof(
				"hrafnar: mempool: %d txs tracked (+%d/-%d this cycle, %d still queued)",
				mempool_size(r.mp),
				added,
				removed,
				backlog,
			)
		}
		if err == nil && (added > 0 || removed > 0) {
			sync.mutex_lock(&r.mu)
			for sh in local {
				r.touched[sh] = {}
			}
			r.dirty = true
			sync.mutex_unlock(&r.mu)
		}
		free_all(context.temp_allocator)

		// A real backfill (transactions actually landing) may hurry; a
		// stuck backlog must NOT — retrying unresolvable transactions at
		// full speed spins the CPU and floods bitcoind's RPC.
		cycles += 1
		if cycles % 60 == 0 {
			mempool_retry_deferred(r.mp) // give the give-up list another chance
		}
		making_progress := err == nil && backlog > 0 && (added > 0 || removed > 0)
		pause := 2 if making_progress else 20
		for _ in 0 ..< pause {
			if sync.atomic_load(&r.stop) {
				break
			}
			time.sleep(100 * time.Millisecond)
		}
	}
}
