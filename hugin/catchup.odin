package hugin

// Incremental indexing: detect new blocks, handle reorgs by unwinding the
// recent tier, index forward, and promote aged blocks into the Munin main
// body.
//
// Nothing crosses into the immutable main body until it is below the reorg
// horizon. A fork below the main body's tip is Reorg_Too_Deep: refuse to
// serve, demand a rebuild. Never fall through silently.

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

import munin "../munin"

// Buckets holding more runs than this after promotion get compacted.
COMPACT_RUN_THRESHOLD :: 4

// One block's rows scatter across nearly every bucket, so each promotion
// writes ~one run file per touched bucket per keyspace regardless of how
// many blocks it carries. Promoting block-by-block would create thousands
// of tiny runs (and fsyncs) per block; batching amortizes that cost.
// Blocks below the horizon sitting in the tier a little longer is safe —
// the tier serves queries and can still unwind them.
// Blocks that must age past the reorg horizon before a promotion runs.
//
// Promotion writes ONE run file per bucket regardless of how many blocks it
// covers — 4096 buckets x 3 keyspaces, so ~12k files and their fsyncs and a
// manifest rewrite each time. The cost is per-bucket, not per-row, so a big
// batch costs about what a small one does while creating proportionally
// fewer runs, and runs are what compaction later has to merge back.
//
// This was 24, chosen to stop per-block promotion from writing 12k tiny
// files per block. The reasoning was right and the number was too small:
// every promotion adds a run to nearly every bucket, so at 24 the whole
// database crossed the 4-run compaction threshold roughly every 20 hours
// and paid for a full 12,288-bucket sweep. At 150 that is ~6x rarer, and
// each run is ~6x larger, which queries prefer too.
//
// The tier holds horizon + promote_batch blocks, so this trades memory for
// write amplification. 150 keeps the tier around 250 blocks.
PROMOTE_BATCH_DEFAULT :: 150

// Catchup_Report, when supplied, is filled with what the cycle changed:
// scripthashes with new confirmed events (the caller initializes the map
// with its preferred allocator), whether the tip moved, and whether a
// reorg unwound anything.
Catchup_Report :: struct {
	touched:     map[[32]u8]struct {},
	tip_changed: bool,
	reorg:       bool,
}

// cancelled reports whether a long-running loop should abort. It checks
// BOTH the caller-supplied flag and the process-global stop flag: a
// caller's own flag (the daemon's catch-up runner passes one) must not
// mask process shutdown. When it did, SIGTERM was invisible to a
// compaction sweep and the daemon kept merging buckets for minutes after
// being asked to stop.
@(private)
cancelled :: proc(c: ^bool) -> bool {
	if c != nil && sync.atomic_load(c) {
		return true
	}
	return stop_was_requested()
}

// cancel_check exposes the cancelled() predicate so tests can assert the
// flag composition directly. Setting the process-global stop flag around a
// whole catch-up would cancel any test running one concurrently — the flag
// is process-wide by nature, so the assertion has to be narrow.
cancel_check :: proc(c: ^bool) -> bool {
	return cancelled(c)
}

catchup_run :: proc(
	cfg: Config,
	report: ^Catchup_Report = nil,
	cancel: ^bool = nil, // nil: use the process-global daemon stop flag
	yield: ^Yield_Check = nil, // lets compaction step aside for a new block
	allocator := context.allocator,
) -> (
	err: Error,
) {
	format_check(cfg) or_return
	cfg := config_fill_defaults(cfg)

	// --- open everything --------------------------------------------------
	// Files are mapped lazily at their use sites; a steady-state cycle
	// touches only the tail files.
	files := blkfile_enumerate(cfg.datadir, allocator) or_return
	defer blkfiles_destroy(files, allocator)
	file_index := make(map[u32]int, context.temp_allocator)
	for &f, i in files {
		file_index[f.file_no] = i
	}

	old_chain := headers_store_read(cfg.index_dir, allocator) or_return
	defer delete(old_chain, allocator)
	cp_height, cp_hash, cperr := checkpoint_read(cfg.index_dir)
	if cperr != nil {
		log.errorf("hugin: no valid CHECKPOINT; run a full index build first")
		return cperr
	}

	rt := recent_open(cfg.index_dir, allocator) or_return
	defer recent_close(rt)

	// Databases open lazily (manifest reads only), so opening them up
	// front is cheap — and the promotion-crash reconcile below needs them
	// before anything else happens.
	db_history := munin.db_open(index_subdir(cfg, "history"), allocator) or_return
	defer munin.db_close(db_history)
	db_txloc := munin.db_open(index_subdir(cfg, "txloc"), allocator) or_return
	defer munin.db_close(db_txloc)
	db_spends := munin.db_open(index_subdir(cfg, "spends"), allocator) or_return
	defer munin.db_close(db_spends)

	// A crash between promotion's munin commit and the tier drop leaves
	// blocks represented in BOTH tiers — queries then fail loudly with
	// Duplicate_Key rather than serve wrong data. Detect and heal it here,
	// before anything reads.
	reconcile_interrupted_promotion(rt, db_history, db_txloc, db_spends) or_return

	// --- rebuild the header DAG and select the most-work chain ------------
	// Incremental: headers.dat already carries every known main-chain
	// header with its file location, so the DAG is seeded from it and only
	// the TAIL files are rescanned — those that could hold new blocks or
	// fork blocks within the reorg horizon. A fork deeper than the horizon
	// is refused below anyway, so nothing relevant can hide in older
	// files. This turns a full-datadir scan (minutes) into seconds.
	dag: Header_Dag
	header_dag_init(&dag, allocator)
	defer header_dag_destroy(&dag)

	for &sh in old_chain {
		e := Header_Entry {
			hash     = sh.hash,
			raw      = sh.raw,
			file_no  = sh.file_no,
			offset   = sh.offset,
			length   = sh.length,
			tx_count = sh.tx_count,
		}
		copy(e.prev[:], sh.raw[4:36])
		header_dag_add(&dag, e)
	}

	// Any block that can still matter arrived no earlier than the block at
	// tip - horizon, so it lives in that block's file or a later one.
	window_start: u32 = 0
	if len(old_chain) > 0 {
		window_start = old_chain[max(0, len(old_chain) - 1 - int(cfg.horizon))].file_no
		for &sh in old_chain[max(0, len(old_chain) - 1 - int(cfg.horizon)):] {
			window_start = min(window_start, sh.file_no)
		}
	}

	scanned := 0
	last_report := time.now()
	for &f in files {
		if f.file_no < window_start {
			continue
		}
		if cancelled(cancel) {
			return Usage_Error.Cancelled
		}
		blkfile_map(&f) or_return
		scanned += 1
		it: Blk_Record_Iter
		blk_record_iter_init(&it, &f, config_magic(cfg))
		for {
			rec, ok := blk_record_iter_next(&it)
			if !ok {break}
			e := header_entry_from_record(&f, rec) or_return
			header_dag_add(&dag, e)
		}
		if it.err != nil {
			return it.err
		}
		if time.duration_seconds(time.since(last_report)) >= 5 {
			last_report = time.now()
			log.infof("hugin: catch-up: scanning tail headers, %d files done", scanned)
		}
	}
	log.debugf("hugin: catch-up: scanned %d tail files (window from blk%05d)", scanned, window_start)

	chain_idx := header_dag_select_chain(&dag, allocator) or_return
	defer delete(chain_idx, allocator)

	new_chain := make([]Stored_Header, len(chain_idx), allocator)
	defer delete(new_chain, allocator)
	for ci, i in chain_idx {
		e := &dag.entries[ci]
		new_chain[i] = Stored_Header {
			hash     = e.hash,
			raw      = e.raw,
			file_no  = e.file_no,
			offset   = e.offset,
			length   = e.length,
			tx_count = e.tx_count,
		}
	}
	new_tip := len(new_chain) - 1
	if new_tip != len(old_chain) - 1 {
		log.infof("hugin: chain tip %d (indexed to %d)", new_tip, len(old_chain) - 1)
	}

	// --- startup check + fork detection -----------------------------------
	// The checkpoint's hash must still be on the most-work chain at its
	// height; if not, a reorg (possibly crash-interrupted) is in progress.
	// Fork point: highest height where old and new chains agree.
	if int(cp_height) >= len(new_chain) || new_chain[cp_height].hash != cp_hash {
		log.warnf("hugin: checkpoint at height %d is off the best chain; unwinding", cp_height)
	}
	fork := -1
	limit := min(len(old_chain), len(new_chain))
	for h in 0 ..< limit {
		if old_chain[h].hash != new_chain[h].hash {
			break
		}
		fork = h
	}
	if fork < 0 {
		log.errorf("hugin: no common ancestor with the indexed chain; wrong datadir?")
		return Corruption.Bad_Header
	}

	// The main body's tip: everything below the recent tier's lowest block
	// is immutable.
	main_tip := int(cp_height)
	if len(rt.blocks) > 0 {
		main_tip = int(rt.blocks[0].height) - 1
	}

	indexed_tip := int(cp_height)
	if fork < indexed_tip {
		if fork < main_tip {
			log.fatalf(
				"hugin: reorg to height %d is below the immutable main body (tip %d). " +
				"The index cannot be unwound; rebuild from scratch with `hugin index`.",
				fork,
				main_tip,
			)
			return Usage_Error.Reorg_Too_Deep
		}
		recent_truncate_above(rt, u32(fork)) or_return
		indexed_tip = fork
		if report != nil {
			report.reorg = true
		}
	}

	// A crash after tier appends but before the checkpoint write leaves the
	// checkpoint behind the tier. Tier-resident blocks ARE indexed —
	// re-appending them would duplicate their rows — so resume from
	// whichever is further along.
	if len(rt.blocks) > 0 {
		top := rt.blocks[len(rt.blocks) - 1]
		if int(top.height) < len(new_chain) &&
		   new_chain[top.height].hash == top.hash &&
		   int(top.height) > indexed_tip {
			log.infof(
				"hugin: recent tier already holds blocks through height %d (checkpoint at %d); resuming above it",
				top.height,
				indexed_tip,
			)
			indexed_tip = int(top.height)
		}
	}

	if indexed_tip >= new_tip && len(rt.blocks) == 0 {
		log.infof("hugin: up to date at height %d", indexed_tip)
		return nil
	}

	// --- index forward into the recent tier -------------------------------
	indexed := 0
	if indexed_tip < new_tip {
		log.infof("hugin: indexing blocks %d..%d into the recent tier", indexed_tip + 1, new_tip)
		h_rows := make([dynamic]byte, allocator)
		t_rows := make([dynamic]byte, allocator)
		s_rows := make([dynamic]byte, allocator)
		defer {delete(h_rows); delete(t_rows); delete(s_rows)}

		// Outputs created earlier in the same block batch, for same-block
		// and cross-new-block spends. Values are cloned: the block buffer
		// below is reused per block, so borrowed slices would dangle.
		batch_txs := make(map[[32]u8][]byte, allocator) // txid -> owned raw tx bytes
		defer {
			for _, raw in batch_txs {delete(raw, allocator)}
			delete(batch_txs)
		}
		resolve_workers := cfg.workers
		if resolve_workers <= 0 {
			resolve_workers = os.get_processor_core_count()
		}
		rc := Resolve_Ctx {
			rt         = rt,
			db_txloc   = db_txloc,
			files      = files,
			file_index = file_index,
			batch_txs  = &batch_txs,
			workers    = resolve_workers,
			compact    = cfg.compact,
		}
		rc.cancel_flag = cancelled(cancel)

		deobf := make([dynamic]byte, allocator)
		defer delete(deobf)

		// Per-block scratch: spend resolution allocates from the temp
		// allocator on every txloc lookup and the daemon only resets temp
		// once per cycle — a long replay would accumulate gigabytes and
		// die by OOM kill. This one is reset after every block. It is a
		// default-kind temp allocator, not an arena, because maps need
		// cache-line alignment that arenas do not give.
		scratch_data: runtime.Default_Temp_Allocator
		runtime.default_temp_allocator_init(&scratch_data, runtime.DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE, context.allocator)
		defer runtime.default_temp_allocator_destroy(&scratch_data)
		scratch_alloc := runtime.default_temp_allocator(&scratch_data)

		idx_report := time.now()
		for h in indexed_tip + 1 ..= new_tip {
			if cancelled(cancel) {
				return Usage_Error.Cancelled
			}
			hdr := &new_chain[h]
			fi, fok := file_index[hdr.file_no]
			if !fok {
				return Corruption.Truncated
			}
			blkfile_map(&files[fi]) or_return
			block := blk_payload_bytes(&files[fi], hdr.offset, hdr.length, &deobf) or_return

			clear(&h_rows)
			clear(&t_rows)
			clear(&s_rows)
			{
				context.temp_allocator = scratch_alloc
				catchup_index_block(
					block,
					u32(h),
					hdr,
					&rc,
					&h_rows,
					&t_rows,
					&s_rows,
					allocator,
				) or_return
			}
			free_all(scratch_alloc)
			recent_append_block(
				rt,
				u32(h),
				hdr.hash,
				h_rows[:],
				t_rows[:],
				s_rows[:],
				full_resort = false,
			) or_return

			// The block is in the tier now, so its transactions are
			// findable through recent_lookup_txloc — batch_txs only ever
			// needs the block being indexed. Keeping every block's
			// transactions for the whole run made memory scale with the
			// LENGTH OF THE CATCH-UP, which is exactly how a 350-block
			// catch-up after two days offline got OOM-killed.
			for _, raw in batch_txs {
				delete(raw, allocator)
			}
			clear(&batch_txs)

			if report != nil {
				for off := 0; off < len(h_rows); off += HISTORY_ROW_SIZE {
					sh: [32]u8
					copy(sh[:], h_rows[off:off + 32])
					report.touched[sh] = {}
				}
			}
			indexed += 1
			if time.duration_seconds(time.since(idx_report)) >= 5 {
				idx_report = time.now()
				log.infof(
					"hugin: catch-up: indexed through height %d (%d of %d, rss %d MB)",
					h,
					indexed,
					new_tip - indexed_tip,
					proc_rss_mb(),
				)
			}
		}
		// The loop sorted only txloc per block. Bring history and spends
		// back in order now, once, before anything reads them.
		recent_resort(rt)
	}

	// --- persist chain state ----------------------------------------------
	// Rewriting headers.dat costs >100MB of writes on a full chain; skip
	// it when this cycle changed nothing — the common case for a daemon
	// polling between blocks.
	chain_unchanged := indexed == 0 && new_tip == len(old_chain) - 1 && fork == new_tip
	if !chain_unchanged {
		log.infof("hugin: writing chain state (headers + checkpoint at height %d)", new_tip)
		headers_store_write(cfg.index_dir, new_chain) or_return
		checkpoint_write(cfg.index_dir, u32(new_tip), new_chain[new_tip].hash) or_return
	}
	if indexed > 0 {
		log.infof("hugin: indexed %d new blocks, tip now %d", indexed, new_tip)
	}
	if report != nil {
		report.tip_changed = indexed > 0 || report.reorg
	}

	// --- promotion --------------------------------------------------------
	if new_tip >= int(cfg.horizon) {
		cutoff := u32(new_tip) - cfg.horizon
		promote_below(cfg, rt, db_history, db_txloc, db_spends, cutoff, cancel) or_return
	}

	// --- compaction -------------------------------------------------------
	// Only on cycles that indexed nothing. The caller does not publish this
	// cycle's results until catchup_run RETURNS, so sweeping after indexing
	// a block would hold that block back for the length of the sweep — the
	// very staleness the yield check exists to prevent. Idle cycles are
	// where the spare time is anyway, and the sweep yields the moment a
	// block shows up.
	if indexed == 0 {
		compact_sweep(cfg, db_history, db_txloc, db_spends, cancel, yield) or_return
	}
	return nil
}

@(private = "file")
index_subdir :: proc(cfg: Config, name: string) -> string {
	return fmt.tprintf("%s/%s", cfg.index_dir, name)
}

// reconcile_interrupted_promotion probes each tier block against the main
// body: fully promoted blocks lose their tier copy (the crash happened
// after commit, before drop); a partially promoted block (some keyspaces
// committed, others not — a millisecond-wide window) cannot be healed
// automatically and demands a rebuild, loudly.
@(private = "file")
reconcile_interrupted_promotion :: proc(
	rt: ^Recent_Tier,
	db_history: ^munin.Db,
	db_txloc: ^munin.Db,
	db_spends: ^munin.Db,
) -> (
	err: Error,
) {
	if len(rt.blocks) == 0 {
		return nil
	}
	probes := recent_probe_blocks(rt) or_return

	// Compact indexes are probed with the derived compact keys; identity
	// fields inside the key make an exact get reliable (see rows.odin).
	compact := format_read(rt.dir)

	drop_to := -1
	dropped := 0
	for &p in probes {
		// Every block funds at least its coinbase outputs and locates at
		// least one transaction, so history and txloc probes always exist.
		h_probe := p.h_key[:]
		t_probe := p.t_key[:]
		s_probe := p.s_key[:]
		ch: [C_HISTORY_ROW_SIZE]u8
		ct: [C_TXLOC_ROW_SIZE]u8 // conversion writes the value bytes too
		cs: [C_SPENDS_ROW_SIZE]u8
		if compact {
			history_row_compact(p.h_row[:], ch[:])
			txloc_row_compact(p.t_row[:], ct[:])
			spends_row_compact(p.s_row[:], cs[:])
			h_probe = ch[:C_HISTORY_KEY_LEN]
			t_probe = ct[:C_TXLOC_KEY_LEN]
			s_probe = cs[:C_SPENDS_KEY_LEN]
		}
		_, h_found, herr := munin.db_get(db_history, h_probe, context.temp_allocator)
		if herr != nil {
			return herr
		}
		_, t_found, terr := munin.db_get(db_txloc, t_probe, context.temp_allocator)
		if terr != nil {
			return terr
		}
		s_found := true
		if p.n_spends > 0 {
			_, sf, serr := munin.db_get(db_spends, s_probe, context.temp_allocator)
			if serr != nil {
				return serr
			}
			s_found = sf
		}

		if h_found && t_found && s_found {
			drop_to = int(p.height)
			dropped += 1
			continue
		}
		if h_found || t_found || (p.n_spends > 0 && s_found) {
			log.errorf(
				"hugin: block %d is PARTIALLY promoted (history=%v txloc=%v spends=%v): " +
				"an interrupted promotion left the keyspaces inconsistent; rebuild the index",
				p.height,
				h_found,
				t_found,
				s_found,
			)
			return Corruption.Bad_Record
		}
		break // clean boundary: this block and everything above is tier-only
	}

	if drop_to >= 0 {
		log.warnf(
			"hugin: recovering from an interrupted promotion: %d tier blocks up to height %d " +
			"already live in the main body; dropping their tier copies",
			dropped,
			drop_to,
		)
		recent_drop_below(rt, u32(drop_to)) or_return
	}
	return nil
}

// catchup_index_block walks one block, emitting rows and resolving spends
// against (in order) the current batch, the recent tier, and the main
// body.
@(private = "file")
// Resolve_Ctx bundles the lookup tiers input resolution reads. During the
// parallel phase everything here is read-only except lazy blkfile mmaps,
// which files_mu serializes.
Resolve_Ctx :: struct {
	rt:         ^Recent_Tier,
	db_txloc:   ^munin.Db,
	files:      []Blk_File,
	file_index: map[u32]int,
	batch_txs:  ^map[[32]u8][]byte,
	files_mu:   sync.Mutex,
	workers:    int,
	compact:    bool,
	cancel_flag: bool, // mirrors the cycle's cancellation source
}

// Below this many unresolved inputs the thread-spawn overhead isn't worth
// it and resolution stays inline.
PARALLEL_RESOLVE_MIN :: 128

@(private = "file")
Spend_Job :: struct {
	prev_txid: [32]u8,
	prev_vout: u32,
	txnum:     u32,
	vin:       u32,
	sh:        [32]u8,
	amount:    u64,
	resolved:  bool,
}

@(private = "file")
Resolve_Worker :: struct {
	rc:   ^Resolve_Ctx,
	jobs: []Spend_Job,
	err:  Error,
}

@(private = "file")
resolve_worker_main :: proc(t: ^thread.Thread) {
	w := (^Resolve_Worker)(t.data)
	// Each worker needs its OWN temp allocator (the spawning scope's is
	// single-threaded by design), and it must be the runtime's default
	// kind — Odin maps require cache-line-aligned allocations that a
	// mem.Dynamic_Arena cannot satisfy.
	temp_data: runtime.Default_Temp_Allocator
	runtime.default_temp_allocator_init(&temp_data, runtime.DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE, context.allocator)
	defer runtime.default_temp_allocator_destroy(&temp_data)
	context.temp_allocator = runtime.default_temp_allocator(&temp_data)

	// ONE de-obfuscation buffer for every input this worker resolves.
	scratch := make([dynamic]byte, context.allocator)
	defer delete(scratch)

	for &j, i in w.jobs {
		if i & 63 == 0 && sync.atomic_load(&w.rc.cancel_flag) {
			w.err = Usage_Error.Cancelled
			return
		}
		sh, amount, rerr := resolve_outpoint_stored(w.rc, j.prev_txid, j.prev_vout, &scratch)
		if rerr != nil {
			w.err = rerr
			return
		}
		j.sh = sh
		j.amount = amount
		j.resolved = true
	}
}

catchup_index_block :: proc(
	block: []byte,
	height: u32,
	hdr: ^Stored_Header,
	rc: ^Resolve_Ctx,
	h_rows: ^[dynamic]byte,
	t_rows: ^[dynamic]byte,
	s_rows: ^[dynamic]byte,
	batch_allocator: runtime.Allocator,
) -> (
	err: Error,
) {
	hrow: [HISTORY_ROW_SIZE]byte
	trow: [TXLOC_ROW_SIZE]byte
	srow: [SPENDS_ROW_SIZE]byte

	// Pass 1: serial walk — txloc and funding rows, batch registration,
	// and same-batch spend resolution. Inputs needing a stored lookup
	// (recent tier or main body) become jobs for the parallel pass.
	jobs := make([dynamic]Spend_Job, context.temp_allocator)

	it: Tx_Iter
	tx_iter_init(&it, block) or_return
	for {
		tx, ok := tx_iter_next(&it)
		if !ok {break}
		txnum := u32(it.index - 1)

		txloc_row_encode(
			trow[:],
			tx.txid,
			u16(hdr.file_no),
			hdr.offset + tx.offset,
			u32(len(tx.raw)),
			height,
		)
		append(t_rows, ..trow[:])

		oit: Tx_Output_Iter
		tx_output_iter_init(&oit, &tx)
		for {
			out, vout, ook := tx_output_iter_next(&oit)
			if !ook {break}
			sh := scripthash(out.script)
			history_row_encode(hrow[:], sh, height, txnum, DIRECTION_FUNDING, u32(vout), out.value)
			append(h_rows, ..hrow[:])
		}

		if !tx.is_coinbase {
			iit: Tx_Input_Iter
			tx_input_iter_init(&iit, &tx)
			for {
				inp, vin, iok := tx_input_iter_next(&iit)
				if !iok {break}
				job := Spend_Job {
					prev_txid = inp.prev_txid,
					prev_vout = inp.vout,
					txnum     = txnum,
					vin       = u32(vin),
				}
				if raw, has := rc.batch_txs[inp.prev_txid]; has {
					sh, amount := output_of_raw_tx(raw, inp.vout) or_return
					job.sh = sh
					job.amount = amount
					job.resolved = true
				}
				append(&jobs, job)
			}
		}

		// The block buffer is reused: own a copy for cross-block spends.
		if tx.txid not_in rc.batch_txs {
			owned := make([]byte, len(tx.raw), batch_allocator)
			copy(owned, tx.raw)
			rc.batch_txs[tx.txid] = owned
		}
	}
	if it.err != nil {
		return it.err
	}

	// Pass 2: resolve stored lookups, in parallel when there are enough.
	unresolved := 0
	for &j in jobs {
		if !j.resolved {unresolved += 1}
	}
	if unresolved >= PARALLEL_RESOLVE_MIN && rc.workers > 1 {
		pending := make([dynamic]int, context.temp_allocator)
		for &j, i in jobs {
			if !j.resolved {append(&pending, i)}
		}
		// Chunk by index list; workers write disjoint jobs.
		nw := min(rc.workers, len(pending))
		chunk_jobs := make([]Spend_Job, len(pending), context.temp_allocator)
		for pi, k in pending {
			chunk_jobs[k] = jobs[pi]
		}
		workers := make([]Resolve_Worker, nw, context.temp_allocator)
		threads := make([]^thread.Thread, nw, context.temp_allocator)
		per := (len(pending) + nw - 1) / nw
		for wi in 0 ..< nw {
			lo := wi * per
			hi := min(lo + per, len(pending))
			workers[wi] = Resolve_Worker {
				rc   = rc,
				jobs = chunk_jobs[lo:hi],
			}
			threads[wi] = thread.create(resolve_worker_main)
			threads[wi].data = &workers[wi]
			threads[wi].init_context = context
			thread.start(threads[wi])
		}
		for t in threads {
			thread.join(t)
			thread.destroy(t)
		}
		for &w in workers {
			if w.err != nil {
				return w.err
			}
		}
		for pi, k in pending {
			jobs[pi] = chunk_jobs[k]
		}
	} else {
		serial_scratch := make([dynamic]byte, context.temp_allocator)
		for &j in jobs {
			if j.resolved {continue}
			sh, amount := resolve_outpoint_stored(rc, j.prev_txid, j.prev_vout, &serial_scratch) or_return
			j.sh = sh
			j.amount = amount
			j.resolved = true
		}
	}

	// Pass 3: emit spend rows in input order.
	for &j in jobs {
		history_row_encode(hrow[:], j.sh, height, j.txnum, DIRECTION_SPEND, j.vin, j.amount)
		append(h_rows, ..hrow[:])
		spends_row_encode(srow[:], j.prev_txid, j.prev_vout, height, j.txnum, j.vin)
		append(s_rows, ..srow[:])
	}
	return nil
}

// resolve_outpoint_stored finds the scriptPubKey and amount an input
// spends, from the recent tier or the main body (the same-batch tier is
// pass 1's job). Thread-safe: everything read here is immutable during
// resolution except lazy blkfile mmaps, guarded by rc.files_mu.
resolve_outpoint_stored :: proc(
	rc: ^Resolve_Ctx,
	txid: [32]u8,
	vout: u32,
	scratch: ^[dynamic]byte,
) -> (
	sh: [32]u8,
	amount: u64,
	err: Error,
) {
	txid := txid

	// 1. The recent tier.
	if loc, found := recent_lookup_txloc(rc.rt, txid); found {
		return output_of_located_tx(rc, loc, vout, scratch)
	}

	// 2. The main body.
	if rc.compact {
		cloc, cfound := c_txloc_scan(rc.db_txloc, rc.files, rc.file_index, &rc.files_mu, txid) or_return
		if !cfound {
			log.errorf(
				"hugin: catch-up input references unknown outpoint %02x%02x%02x%02x...:%d",
				txid[0], txid[1], txid[2], txid[3],
				vout,
			)
			return {}, 0, Corruption.Unknown_Outpoint
		}
		return output_of_located_tx(rc, cloc, vout, scratch)
	}
	value, found, gerr := munin.db_get(rc.db_txloc, txid[:], context.temp_allocator)
	if gerr != nil {
		return {}, 0, gerr
	}
	if !found {
		log.errorf(
			"hugin: catch-up input references unknown outpoint %02x%02x%02x%02x...:%d",
			txid[0], txid[1], txid[2], txid[3],
			vout,
		)
		return {}, 0, Corruption.Unknown_Outpoint
	}
	return output_of_located_tx(rc, txloc_value_decode(value), vout, scratch)
}

@(private = "file")
// scratch is CALLER-OWNED and reused. On an XOR-obfuscated datadir every
// call de-obfuscates a whole block (~2MB) into it; allocating a fresh
// buffer per input instead accumulates gigabytes within a single block —
// that is what OOM-killed the daemon during a 350-block catch-up.
output_of_located_tx :: proc(
	rc: ^Resolve_Ctx,
	loc: Txloc_Value,
	vout: u32,
	scratch: ^[dynamic]byte,
) -> (
	sh: [32]u8,
	amount: u64,
	err: Error,
) {
	fi, fok := rc.file_index[u32(loc.file_no)]
	if !fok {
		return {}, 0, Corruption.Truncated
	}
	{
		sync.mutex_lock(&rc.files_mu)
		defer sync.mutex_unlock(&rc.files_mu)
		blkfile_map(&rc.files[fi]) or_return
	}
	raw := blk_payload_bytes(&rc.files[fi], loc.offset, loc.length, scratch) or_return
	return output_of_raw_tx(raw, vout)
}

output_of_raw_tx :: proc(raw: []byte, vout: u32) -> (sh: [32]u8, amount: u64, err: Error) {
	tx, consumed := tx_parse(raw, false)
	if consumed == 0 {
		return {}, 0, Corruption.Bad_Transaction
	}
	oit: Tx_Output_Iter
	tx_output_iter_init(&oit, &tx)
	for {
		out, v, ok := tx_output_iter_next(&oit)
		if !ok {break}
		if u32(v) == vout {
			return scripthash(out.script), out.value, nil
		}
	}
	return {}, 0, Corruption.Unknown_Outpoint
}

// ---------------------------------------------------------------------------
// Promotion: blocks aged past the horizon move from the recent tier into
// the main body as additional level-0 runs (bucket-partitioned ingest),
// with opportunistic compaction after.

@(private = "file")
promote_below :: proc(
	cfg: Config,
	rt: ^Recent_Tier,
	db_history: ^munin.Db,
	db_txloc: ^munin.Db,
	db_spends: ^munin.Db,
	cutoff: u32,
	cancel: ^bool = nil,
) -> (
	err: Error,
) {
	// Anything to promote?
	count := 0
	for b in rt.blocks {
		if b.height <= cutoff {count += 1}
	}
	if count < int(cfg.promote_batch) {
		return nil
	}

	log.infof(
		"hugin: promoting %d blocks (heights <= %d) into the main body — bucket ingests + fsyncs, may take a minute",
		count,
		cutoff,
	)
	h_rows := make([dynamic]byte, context.temp_allocator)
	t_rows := make([dynamic]byte, context.temp_allocator)
	s_rows := make([dynamic]byte, context.temp_allocator)
	recent_collect_below(rt, cutoff, &h_rows, &t_rows, &s_rows) or_return

	log.infof("hugin: promotion: ingesting history keyspace (%d rows)", len(h_rows) / HISTORY_ROW_SIZE)
	promote_keyspace(cfg, db_history, h_rows[:], HISTORY_ROW_SIZE, HISTORY_KEY_LEN, .History) or_return
	log.infof("hugin: promotion: ingesting txloc keyspace (%d rows)", len(t_rows) / TXLOC_ROW_SIZE)
	promote_keyspace(cfg, db_txloc, t_rows[:], TXLOC_ROW_SIZE, TXLOC_KEY_LEN, .Txloc) or_return
	log.infof("hugin: promotion: ingesting spends keyspace (%d rows)", len(s_rows) / SPENDS_ROW_SIZE)
	promote_keyspace(cfg, db_spends, s_rows[:], SPENDS_ROW_SIZE, SPENDS_KEY_LEN, .Spends) or_return

	log.infof("hugin: promotion: committing")
	munin.db_commit(db_history) or_return
	munin.db_commit(db_txloc) or_return
	munin.db_commit(db_spends) or_return

	// Only after the main body is durable may the tier shrink.
	recent_drop_below(rt, cutoff) or_return
	log.infof("hugin: promoted %d blocks at or below height %d into the main body", count, cutoff)

	// Compaction is NOT done here. It is debt created by this promotion but
	// outlives it, and it must be interruptible — see compact_sweep, which
	// the catch-up cycle calls on every pass.
	return nil
}

// Yield_Check lets a long-running maintenance loop step aside for more
// urgent work. The daemon backs it with its tip watch, so a compaction
// sweep abandons the rest of its buckets the moment a block arrives and
// picks them up on a later cycle. Without it a full sweep held the
// catch-up thread for ~48 minutes, during which the daemon indexed no
// blocks at all — wallets stopped seeing confirmations, and pushes for
// blockchain.headers.subscribe never fired.
Yield_Check :: struct {
	fn:   proc(user: rawptr) -> bool,
	user: rawptr,
}

// yield_always makes a sweep stop after its first bucket. The daemon uses
// it for the pre-serving catch-up: compaction debt must not delay opening
// the Electrum and esplora ports, and the runner will work the debt off on
// its first idle cycle once we are actually serving.
yield_always :: proc(user: rawptr) -> bool {
	return true
}

@(private)
should_yield :: proc(y: ^Yield_Check) -> bool {
	return y != nil && y.fn != nil && y.fn(y.user)
}

// compact_sweep merges runs in buckets that have accumulated more than
// COMPACT_RUN_THRESHOLD of them. It is called on EVERY catch-up cycle, not
// just after a promotion: the debt outlives the promotion that created it,
// and a sweep that yields to a new block has to be able to resume on the
// next cycle rather than waiting for the next promotion (~150 blocks away).
//
// Yielding is checked only between completed buckets, never inside a merge.
// Each bucket commits its own manifest swap, so stopping between them is a
// clean boundary — and a hard kill there leaves only an orphan run file,
// which the next open deletes.
@(private)
compact_sweep :: proc(
	cfg: Config,
	db_history: ^munin.Db,
	db_txloc: ^munin.Db,
	db_spends: ^munin.Db,
	cancel: ^bool,
	yield: ^Yield_Check,
) -> (
	err: Error,
) {
	to_compact := 0
	for db in ([]^munin.Db{db_history, db_txloc, db_spends}) {
		for bucket in 0 ..< 1 << cfg.bucket_bits {
			if munin.db_bucket_run_count(db, u32(bucket)) > COMPACT_RUN_THRESHOLD {
				to_compact += 1
			}
		}
	}
	if to_compact == 0 {
		return nil
	}
	log.infof(
		// "compaction" here is Munin merging a bucket's accumulated runs.
		// It has nothing to do with the --compact index mode; say so,
		// because the two are easy to confuse in a log.
		"hugin: merging runs in %d over-full storage buckets (routine maintenance, not --compact mode)",
		to_compact,
	)
	compact_start := time.now()
	done := 0
	last_report := time.now()

	// Per-bucket scratch. db_compact_bucket takes its run list, its k-way
	// merge iterator (which holds a decoded block per input run) and its
	// old-id set from the temp allocator, and a sweep runs over thousands
	// of buckets before the caller next resets temp — so without a reset
	// here memory grows with the NUMBER OF BUCKETS COMPACTED. Same failure
	// as the recent-tier append path: it OOM-killed the daemon partway
	// through a full sweep.
	cscratch: runtime.Default_Temp_Allocator
	runtime.default_temp_allocator_init(&cscratch, runtime.DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE, context.allocator)
	defer runtime.default_temp_allocator_destroy(&cscratch)
	cscratch_alloc := runtime.default_temp_allocator(&cscratch)

	for db in ([]^munin.Db{db_history, db_txloc, db_spends}) {
		for bucket in 0 ..< 1 << cfg.bucket_bits {
			if cancelled(cancel) {
				return Usage_Error.Cancelled
			}
			if munin.db_bucket_run_count(db, u32(bucket)) <= COMPACT_RUN_THRESHOLD {
				continue
			}
			paused := false
			{
				context.temp_allocator = cscratch_alloc
				munin.db_compact_bucket(db, u32(bucket)) or_return
				// Stat-based; runs in the scratch so it cannot accumulate.
				paused = should_yield(yield)
			}
			free_all(cscratch_alloc)
			done += 1
			if paused {
				log.infof(
					"hugin: merging runs: paused for a new block after %d/%d buckets (%v); resumes next cycle",
					done,
					to_compact,
					time.since(compact_start),
				)
				return nil
			}
			if time.duration_seconds(time.since(last_report)) >= 10 {
				last_report = time.now()
				log.infof("hugin: merging runs: %d/%d buckets done", done, to_compact)
			}
		}
	}
	log.infof("hugin: compaction done in %v (%d buckets)", time.since(compact_start), done)
	return nil
}

// promote_keyspace partitions rows by bucket, sorts each partition, and
// ingests it as one run.
@(private = "file")
promote_keyspace :: proc(
	cfg: Config,
	db: ^munin.Db,
	rows: []byte,
	row_size: int,
	key_len: int,
	ks: Compact_Keyspace,
) -> (
	err: Error,
) {
	if len(rows) == 0 {
		return nil
	}
	n := len(rows) / row_size
	n_buckets := 1 << cfg.bucket_bits

	parts := make([][dynamic]byte, n_buckets, context.temp_allocator)
	for i in 0 ..< n {
		row := rows[i * row_size:(i + 1) * row_size]
		b := key_bucket(row, cfg.bucket_bits)
		if parts[b] == nil {
			parts[b] = make([dynamic]byte, context.temp_allocator)
		}
		append(&parts[b], ..row)
	}

	for &part, bucket in parts {
		if len(part) == 0 {continue}
		if cfg.compact {
			compact_ingest(db, u32(bucket), part[:], ks) or_return
			continue
		}
		scratch := make([]byte, len(part), context.temp_allocator)
		radix_sort_rows(part[:], row_size, key_len, scratch)

		ing := munin.ingest_begin(db, u32(bucket)) or_return
		np := len(part) / row_size
		for i in 0 ..< np {
			row := part[i * row_size:(i + 1) * row_size]
			// Adjacent duplicates cannot occur in promotion (heights are
			// fresh and unique); a duplicate here is a real bug upstream.
			if i > 0 && bytes.compare(part[(i - 1) * row_size:(i - 1) * row_size + key_len], row[:key_len]) == 0 {
				munin.ingest_abort(ing)
				return Corruption.Bad_Record
			}
			munin.ingest_add(ing, row[:key_len], row[key_len:]) or_return
		}
		_, ferr := munin.ingest_finish(ing)
		if ferr != nil {
			return ferr
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Catch-up runner: indexing new blocks on its OWN thread.
//
// It used to run inline in the daemon's serve loop, so every arriving
// block froze all serving for as long as indexing took — a load test
// across a block arrival showed a ~3.1s ceiling in EVERY category. The
// runner keeps chain work off the I/O path; the serve loop only picks up
// the result and pushes notifications (the subscription table stays
// loop-thread-only by design).

Catchup_Runner :: struct {
	cfg:          Config,
	slot:         ^Index_Slot,
	poll_seconds: int,
	stop:         bool, // atomic
	fatal:        bool, // atomic: the loop must shut the daemon down
	fatal_err:    Error,

	mu:          sync.Mutex, // guards the fields below
	touched:     map[[32]u8]struct {},
	tip_changed: bool,
	reorg:       bool,
	refreshed:   bool, // a new index generation is in the slot
	allocator:   runtime.Allocator,
	thread:      ^thread.Thread,
}

catchup_runner_start :: proc(
	r: ^Catchup_Runner,
	cfg: Config,
	slot: ^Index_Slot,
	poll_seconds: int,
	allocator := context.allocator,
) {
	r.cfg = cfg
	r.slot = slot
	r.poll_seconds = max(poll_seconds, 1)
	r.allocator = allocator
	r.touched = make(map[[32]u8]struct {}, allocator)
	r.thread = thread.create(catchup_runner_main)
	r.thread.data = r
	r.thread.init_context = context
	thread.start(r.thread)
}

catchup_runner_stop :: proc(r: ^Catchup_Runner) {
	if r.thread == nil {
		return
	}
	sync.atomic_store(&r.stop, true)
	thread.join(r.thread)
	thread.destroy(r.thread)
	r.thread = nil
	delete(r.touched)
}

// catchup_runner_take reports what the last cycles changed, and clears it.
catchup_runner_take :: proc(
	r: ^Catchup_Runner,
	out: ^map[[32]u8]struct {},
) -> (
	tip_changed: bool,
	reorg: bool,
	refreshed: bool,
) {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	tip_changed, reorg, refreshed = r.tip_changed, r.reorg, r.refreshed
	for sh in r.touched {
		out^[sh] = {}
	}
	clear(&r.touched)
	r.tip_changed, r.reorg, r.refreshed = false, false, false
	return
}

// catchup_runner_fatal reports an error the daemon cannot continue past
// (a reorg below the immutable body).
catchup_runner_fatal :: proc(r: ^Catchup_Runner) -> (fatal: bool, err: Error) {
	if !sync.atomic_load(&r.fatal) {
		return false, nil
	}
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	return true, r.fatal_err
}

// Runner_Yield decides when a compaction sweep must step aside. It checks
// TWO independent things on purpose: the tip watch (fast, but it is a
// heuristic over file metadata and has been wrong before), and a hard time
// slice (dumb, but it cannot be wrong). Relying on the watch alone left the
// daemon a block behind for the length of a sweep when the watch missed an
// append — never give a long-running loop a single escape hatch.
@(private = "file")
Runner_Yield :: struct {
	watch:       ^Tip_Watch,
	started:     time.Time,
	max_slice_s: f64,
}

@(private = "file")
runner_should_yield :: proc(user: rawptr) -> bool {
	ry := (^Runner_Yield)(user)
	if tip_watch_changed(ry.watch) {
		return true
	}
	return time.duration_seconds(time.since(ry.started)) >= ry.max_slice_s
}

@(private = "file")
catchup_runner_main :: proc(t: ^thread.Thread) {
	r := (^Catchup_Runner)(t.data)
	// Own temp allocator, runtime kind — maps need cache-line alignment
	// that a mem.Dynamic_Arena cannot give.
	temp_data: runtime.Default_Temp_Allocator
	runtime.default_temp_allocator_init(&temp_data, runtime.DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE, context.allocator)
	defer runtime.default_temp_allocator_destroy(&temp_data)
	context.temp_allocator = runtime.default_temp_allocator(&temp_data)

	watch: Tip_Watch
	tip_watch_refresh(&watch, r.cfg)
	defer tip_watch_destroy(&watch)
	// Compaction polls this between buckets and abandons the sweep when a
	// block is waiting, so following the tip is never behind maintenance.
	// tip_watch_changed only stats and compares — it does NOT consume the
	// signal, so the loop below still sees it and indexes the block.
	ry := Runner_Yield {
		watch       = &watch,
		// Bounded by the fallback poll interval, so a sweep can never make
		// the tip staler than the daemon's existing worst case.
		max_slice_s = f64(r.poll_seconds),
	}
	yield := Yield_Check {
		fn   = runner_should_yield,
		user = &ry,
	}

	state := daemon_state_snapshot(r.cfg)
	last := time.now()

	for !sync.atomic_load(&r.stop) {
		due := time.duration_seconds(time.since(last)) >= f64(r.poll_seconds)
		if !due && !tip_watch_changed(&watch) {
			time.sleep(200 * time.Millisecond)
			free_all(context.temp_allocator)
			continue
		}
		last = time.now()

		rep: Catchup_Report
		rep.touched = make(map[[32]u8]struct {}, context.temp_allocator)
		ry.started = time.now()
		if cerr := catchup_run(r.cfg, &rep, &r.stop, &yield); cerr != nil {
			if is_fatal_catchup_error(cerr) {
				log.errorf("hrafnar: fatal during catch-up: %v", cerr)
				sync.mutex_lock(&r.mu)
				r.fatal_err = cerr
				sync.mutex_unlock(&r.mu)
				sync.atomic_store(&r.fatal, true)
				return
			}
			log.warnf("hrafnar: catch-up failed (will retry): %v", cerr)
		}
		tip_watch_refresh(&watch, r.cfg)

		// A changed on-disk state means a new index generation. Opening it
		// here keeps that cost off the serve loop too; the swap itself is
		// refcounted, so in-flight requests finish against the old one.
		refreshed := false
		new_state := daemon_state_snapshot(r.cfg)
		if new_state != state {
			state = new_state
			if new_idx, oerr := index_open(r.cfg); oerr == nil {
				// Hand the resolved-txid cache to the new generation before
				// publishing it, so a new block does not reset every
				// address query to cold.
				if cur := index_slot_get(r.slot); cur != nil {
					index_adopt_txid_cache(new_idx, cur)
					index_release(cur)
				}
				index_slot_swap(r.slot, new_idx)
				refreshed = true
				log.infof("hrafnar: index refreshed, tip %d", index_tip_height(new_idx))
			} else {
				log.errorf("hrafnar: cannot reopen the index after catch-up: %v", oerr)
			}
		}

		if rep.tip_changed || refreshed {
			sync.mutex_lock(&r.mu)
			for sh in rep.touched {
				r.touched[sh] = {}
			}
			r.tip_changed ||= rep.tip_changed
			r.reorg ||= rep.reorg
			r.refreshed ||= refreshed
			sync.mutex_unlock(&r.mu)
		}
		free_all(context.temp_allocator)
	}
}
