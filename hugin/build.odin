package hugin

// The three-phase bulk build pipeline.
//
//   phase 0: header scan -> chain selection -> headers.dat + CHECKPOINT
//   phase 1: parallel parse and scatter (worker per blk file)
//   phase 2: parallel sort-merge join per join bucket
//   phase 3: parallel sort + munin ingest per bucket, one commit per db
//
// Performance rules honored here: mmap and never copy block bytes, no
// transaction structs, rows partitioned at emission, radix sort, zero
// allocation in the hot loop.

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

import munin "../munin"

Build :: struct {
	cfg:             Config,
	files:           []Blk_File,
	file_index:      map[u32]int, // file_no -> index into files
	chain:           []Stored_Header,
	heights_by_file: map[u32][dynamic]u32, // file_no -> heights it holds
	n_buckets:       int,
	sc_history:      Scatter, // phase-2 output, phase-3 input
	sc_txloc:        Scatter,
	sc_joinf:        Scatter,
	sc_joins:        Scatter,
	db_history:      ^munin.Db,
	db_txloc:        ^munin.Db,
	db_spends:       ^munin.Db,
	first_err:       Error, // first task error, under err_mu
	err_mu:          sync.Mutex,
	files_done:      int, // atomic progress counters
	txs_done:        u64,
	p2_done:         int,
	p3_done:         int,
	last_report_ns:  i64, // shared heartbeat clock for worker-side progress
	allocator:       runtime.Allocator,
}

// Global build status: a short line the daemon's during-build responder
// serves to queries ("index building: phase 2: joining 1042/4096").
@(private = "file")
build_status_mu: sync.Mutex
@(private = "file")
build_status_buf: [160]byte
@(private = "file")
build_status_len: int

build_status_set :: proc(s: string) {
	sync.mutex_lock(&build_status_mu)
	n := min(len(s), len(build_status_buf))
	copy(build_status_buf[:n], s)
	build_status_len = n
	sync.mutex_unlock(&build_status_mu)
}

build_status_get :: proc(buf: []byte) -> string {
	sync.mutex_lock(&build_status_mu)
	n := min(build_status_len, len(buf))
	copy(buf[:n], build_status_buf[:n])
	sync.mutex_unlock(&build_status_mu)
	return string(buf[:n])
}

// build_progress_tick logs a progress line when at least 5 seconds have
// passed since the last one (or on the final item), from whichever worker
// crosses the threshold. Lock-free: one CAS decides who reports.
@(private)
build_progress_tick :: proc(b: ^Build, counter: ^int, total: int, label: string) {
	done := sync.atomic_add(counter, 1) + 1
	now := time.tick_now()._nsec
	last := sync.atomic_load(&b.last_report_ns)
	if done == total {
		log.infof("hugin: %s: %d/%d buckets", label, done, total)
		return
	}
	if now - last >= 5_000_000_000 {
		_, swapped := sync.atomic_compare_exchange_strong(&b.last_report_ns, last, now)
		if swapped {
			log.infof("hugin: %s: %d/%d buckets", label, done, total)
			sbuf: [160]byte
			status := fmt.bprintf(sbuf[:], "%s: %d/%d buckets", label, done, total)
			build_status_set(status)
		}
	}
}

@(private)
build_set_err :: proc(b: ^Build, err: Error) {
	if err == nil {return}
	sync.mutex_lock(&b.err_mu)
	if b.first_err == nil {
		b.first_err = err
	}
	sync.mutex_unlock(&b.err_mu)
}

// build_index runs the full bulk build. max_height truncates the chain for
// partial builds (negative = full chain).
build_index :: proc(cfg: Config, max_height: int = -1, allocator := context.allocator) -> (err: Error) {
	cfg := config_fill_defaults(cfg)
	start_time := time.now()

	log.infof("hugin: sha256 path: %s; crc32c path: %s", sha_accel_name(), munin.crc32c_accel_name())

	b: Build
	b.cfg = cfg
	b.n_buckets = 1 << cfg.bucket_bits
	b.allocator = allocator
	defer build_teardown(&b)

	ensure_dir(cfg.index_dir) or_return
	format_write(cfg.index_dir, cfg.compact) or_return

	// --- enumerate and map ------------------------------------------------
	b.files = blkfile_enumerate(cfg.datadir, allocator) or_return
	if len(b.files) == 0 {
		log.errorf("hugin: no blk*.dat files in %s", cfg.datadir)
		return Usage_Error.Bad_Config
	}
	b.file_index = make(map[u32]int, allocator)
	total_bytes: u64
	for &f, i in b.files {
		blkfile_map(&f) or_return
		b.file_index[f.file_no] = i
		total_bytes += u64(len(f.data))
	}
	// Phase 1 spills three keyspaces (txloc + the two join sides) before
	// anything is deleted: peak work-dir usage lands near 0.75x the
	// datadir regardless of mode (work rows are always full-size), and
	// the final index adds roughly 0.7x exact / 0.3x compact. Say so up
	// front — running out of disk at hour one is the worst way to learn.
	gb := total_bytes / (1 << 30)
	final_gb := gb * 7 / 10
	if cfg.compact {
		final_gb = gb * 3 / 10
	}
	log.infof(
		"hugin: mapped %d blk files (%d GB); expect up to ~%d GB of work-dir scratch at peak and ~%d GB of final index%s",
		len(b.files),
		gb,
		gb * 3 / 4,
		final_gb,
		" (compact)" if cfg.compact else "",
	)

	// --- phase 0: headers -------------------------------------------------
	build_status_set("phase 0: scanning headers")
	defer build_status_set("")
	phase0_start := time.now()
	{
		dag: Header_Dag
		header_dag_init(&dag, allocator)
		defer header_dag_destroy(&dag)

		last_report := time.now()
		for &f, fi in b.files {
			if stop_was_requested() {
				return Usage_Error.Cancelled
			}
			it: Blk_Record_Iter
			blk_record_iter_init(&it, &f, network_magic(cfg.network))
			for {
				rec, ok := blk_record_iter_next(&it)
				if !ok {break}
				e := header_entry_from_record(&f, rec) or_return
				header_dag_add(&dag, e)
			}
			if it.err != nil {
				log.errorf("hugin: bad framing in %s: %v", f.path, it.err)
				return it.err
			}
			if time.duration_seconds(time.since(last_report)) >= 5 {
				last_report = time.now()
				log.infof(
					"hugin: phase 0: scanning headers, %d/%d files, %d blocks seen",
					fi + 1,
					len(b.files),
					len(dag.entries),
				)
			}
		}

		chain_idx := header_dag_select_chain(&dag, allocator) or_return
		defer delete(chain_idx, allocator)

		n := len(chain_idx)
		if max_height >= 0 && max_height + 1 < n {
			n = max_height + 1
		}
		b.chain = make([]Stored_Header, n, allocator)
		for i in 0 ..< n {
			e := &dag.entries[chain_idx[i]]
			b.chain[i] = Stored_Header {
				hash     = e.hash,
				raw      = e.raw,
				file_no  = e.file_no,
				offset   = e.offset,
				length   = e.length,
				tx_count = e.tx_count,
			}
		}
	}
	headers_store_write(cfg.index_dir, b.chain) or_return
	tip := len(b.chain) - 1

	// Nothing crosses into Munin's immutable main body until it is below
	// the reorg horizon: the bulk build stops at main_tip and catch-up
	// indexes the top horizon blocks into the recent tier.
	main_tip := max(0, tip - int(cfg.horizon))
	log.infof(
		"hugin: phase 0 done in %v: height %d, main body to %d, tip %02x%02x%02x%02x...",
		time.since(phase0_start),
		tip,
		main_tip,
		b.chain[tip].hash[31],
		b.chain[tip].hash[30],
		b.chain[tip].hash[29],
		b.chain[tip].hash[28],
	)

	// --- create stores ----------------------------------------------------
	b.heights_by_file = make(map[u32][dynamic]u32, allocator)
	for &h, height in b.chain {
		if height > main_tip {
			continue
		}
		lst, ok := &b.heights_by_file[h.file_no]
		if !ok {
			b.heights_by_file[h.file_no] = make([dynamic]u32, allocator)
			lst = &b.heights_by_file[h.file_no]
		}
		append(lst, u32(height))
	}

	work := fmt.tprintf("%s/work", cfg.index_dir)
	if cfg.work_dir != "" {
		work = cfg.work_dir
	}
	scatter_init(&b.sc_history, fmt.tprintf("%s/history", work), b.n_buckets, allocator) or_return
	scatter_init(&b.sc_txloc, fmt.tprintf("%s/txloc", work), b.n_buckets, allocator) or_return
	scatter_init(&b.sc_joinf, fmt.tprintf("%s/joinf", work), b.n_buckets, allocator) or_return
	scatter_init(&b.sc_joins, fmt.tprintf("%s/joins", work), b.n_buckets, allocator) or_return

	b.db_history = munin.db_create(
		fmt.tprintf("%s/history", cfg.index_dir),
		munin.Config {
			bucket_bits       = cfg.bucket_bits,
			filter_prefix_len = 32,
		},
		allocator,
	) or_return
	b.db_txloc = munin.db_create(
		fmt.tprintf("%s/txloc", cfg.index_dir),
		munin.Config {
			bucket_bits       = cfg.bucket_bits,
			filter_prefix_len = 32,
		},
		allocator,
	) or_return
	b.db_spends = munin.db_create(
		fmt.tprintf("%s/spends", cfg.index_dir),
		munin.Config {
			bucket_bits       = cfg.bucket_bits,
			filter_prefix_len = 32,
		},
		allocator,
	) or_return

	// --- worker pool ------------------------------------------------------
	// One pool PER PHASE: thread.pool_finish drains the queue and then
	// permanently joins the worker threads, so a finished pool silently
	// degrades every later phase to single-threaded execution on the
	// calling thread.
	workers := cfg.workers
	if workers <= 0 {
		workers = os.get_processor_core_count()
	}

	// --- phase 1: parse and scatter --------------------------------------
	build_status_set("phase 1: parsing and scattering blocks")
	phase1_start := time.now()
	pool1: thread.Pool
	thread.pool_init(&pool1, allocator, workers)
	// Worker threads must inherit the logger; they do not inherit the
	// context on their own.
	for t in pool1.threads {
		t.init_context = context
	}
	thread.pool_start(&pool1)
	p1_tasks := make([]P1_Task, len(b.files), allocator)
	defer delete(p1_tasks, allocator)
	for &f, i in b.files {
		p1_tasks[i] = P1_Task {
			b          = &b,
			file_index = i,
		}
		if f.file_no not_in b.heights_by_file {
			continue // file holds no main-chain blocks
		}
		thread.pool_add_task(&pool1, allocator, p1_task_proc, &p1_tasks[i], i)
	}
	thread.pool_finish(&pool1)
	thread.pool_destroy(&pool1)
	if b.first_err != nil {
		return b.first_err
	}
	log.infof(
		"hugin: phase 1 done in %v: %d files, %d txs",
		time.since(phase1_start),
		len(b.files),
		sync.atomic_load(&b.txs_done),
	)

	// --- phase 2: join ----------------------------------------------------
	log.infof(
		"hugin: phase 2: joining %d buckets on %d workers (each: load, sort, derive history rows, ingest spends)",
		b.n_buckets,
		workers,
	)
	build_status_set("phase 2: resolving spends")
	phase2_start := time.now()
	pool2: thread.Pool
	thread.pool_init(&pool2, allocator, workers)
	for t in pool2.threads {
		t.init_context = context
	}
	thread.pool_start(&pool2)
	p2_tasks := make([]P2_Task, b.n_buckets, allocator)
	defer delete(p2_tasks, allocator)
	for bucket in 0 ..< b.n_buckets {
		p2_tasks[bucket] = P2_Task {
			b      = &b,
			bucket = bucket,
		}
		thread.pool_add_task(&pool2, allocator, p2_task_proc, &p2_tasks[bucket], bucket)
	}
	thread.pool_finish(&pool2)
	thread.pool_destroy(&pool2)
	if b.first_err != nil {
		return b.first_err
	}
	total_fundings, total_spends := 0, 0
	for &t in p2_tasks {
		total_fundings += t.funding_rows
		total_spends += t.spend_rows
	}
	log.infof(
		"hugin: phase 2 done in %v: %d funding rows, %d spend rows, spends keyspace ingested",
		time.since(phase2_start),
		total_fundings,
		total_spends,
	)

	// --- phase 3: sort and ingest -----------------------------------------
	log.infof("hugin: phase 3: sorting and ingesting %d history+txloc buckets", 2 * b.n_buckets)
	build_status_set("phase 3: sorting and ingesting the index")
	phase3_start := time.now()
	pool3: thread.Pool
	thread.pool_init(&pool3, allocator, workers)
	for t in pool3.threads {
		t.init_context = context
	}
	thread.pool_start(&pool3)
	p3_tasks := make([]P3_Task, 2 * b.n_buckets, allocator)
	defer delete(p3_tasks, allocator)
	for bucket in 0 ..< b.n_buckets {
		p3_tasks[bucket * 2 + 0] = P3_Task{b = &b, bucket = bucket, keyspace = .History}
		p3_tasks[bucket * 2 + 1] = P3_Task{b = &b, bucket = bucket, keyspace = .Txloc}
		thread.pool_add_task(&pool3, allocator, p3_task_proc, &p3_tasks[bucket * 2 + 0], bucket)
		thread.pool_add_task(&pool3, allocator, p3_task_proc, &p3_tasks[bucket * 2 + 1], bucket)
	}
	thread.pool_finish(&pool3)
	thread.pool_destroy(&pool3)
	if b.first_err != nil {
		return b.first_err
	}

	munin.db_commit(b.db_history) or_return
	munin.db_commit(b.db_txloc) or_return
	munin.db_commit(b.db_spends) or_return
	log.infof("hugin: phase 3 done in %v", time.since(phase3_start))

	// The work directory is scratch; the index is committed.
	scatter_remove_all(&b.sc_history)
	scatter_remove_all(&b.sc_txloc)
	scatter_remove_all(&b.sc_joinf)
	scatter_remove_all(&b.sc_joins)
	os.remove(work)

	// The checkpoint records the indexed tip: the main body's top. Blocks
	// above it are catch-up's job (they belong in the recent tier).
	checkpoint_write(cfg.index_dir, u32(main_tip), b.chain[main_tip].hash) or_return

	log.infof(
		"hugin: bulk build complete in %v: main body to height %d (chain tip %d; run catchup for the rest)",
		time.since(start_time),
		main_tip,
		tip,
	)
	return nil
}

@(private = "file")
build_teardown :: proc(b: ^Build) {
	if b.db_history != nil {munin.db_close(b.db_history)}
	if b.db_txloc != nil {munin.db_close(b.db_txloc)}
	if b.db_spends != nil {munin.db_close(b.db_spends)}
	if b.sc_history.dir != "" {scatter_destroy(&b.sc_history)}
	if b.sc_txloc.dir != "" {scatter_destroy(&b.sc_txloc)}
	if b.sc_joinf.dir != "" {scatter_destroy(&b.sc_joinf)}
	if b.sc_joins.dir != "" {scatter_destroy(&b.sc_joins)}
	for _, &lst in b.heights_by_file {delete(lst)}
	delete(b.heights_by_file)
	delete(b.file_index)
	delete(b.chain, b.allocator)
	if b.files != nil {blkfiles_destroy(b.files, b.allocator)}
}

// ---------------------------------------------------------------------------
// Phase 1 task: one blk file.

P1_Task :: struct {
	b:          ^Build,
	file_index: int,
	err:        Error,
}

@(private = "file")
p1_task_proc :: proc(task: thread.Task) {
	t := cast(^P1_Task)task.data
	if stop_was_requested() {
		t.err = Usage_Error.Cancelled
		build_set_err(t.b, t.err)
		return
	}
	t.err = p1_run(t.b, t.file_index)
	build_set_err(t.b, t.err)
}

@(private = "file")
p1_run :: proc(b: ^Build, file_index: int) -> (err: Error) {
	f := &b.files[file_index]
	heights, has := b.heights_by_file[f.file_no]
	if !has {
		return nil
	}

	ws_txloc, ws_joinf, ws_joins: Worker_Scatter
	worker_scatter_init(&ws_txloc, &b.sc_txloc, TXLOC_ROW_SIZE)
	worker_scatter_init(&ws_joinf, &b.sc_joinf, JOINF_ROW_SIZE)
	worker_scatter_init(&ws_joins, &b.sc_joins, JOINS_ROW_SIZE)
	defer {
		worker_scatter_destroy(&ws_txloc)
		worker_scatter_destroy(&ws_joinf)
		worker_scatter_destroy(&ws_joins)
	}

	trow: [TXLOC_ROW_SIZE]byte
	jfrow: [JOINF_ROW_SIZE]byte
	jsrow: [JOINS_ROW_SIZE]byte

	bits := b.cfg.bucket_bits
	txs: u64

	// De-obfuscation scratch, reused per block; a no-op slice pass-through
	// on plain datadirs.
	deobf := make([dynamic]byte)
	defer delete(deobf)

	for height in heights {
		h := &b.chain[height]
		block, berr := blk_payload_bytes(f, h.offset, h.length, &deobf)
		if berr != nil {
			log.errorf("hugin: block at height %d extends past %s", height, f.path)
			return berr
		}

		it: Tx_Iter
		tx_iter_init(&it, block) or_return
		for {
			tx, ok := tx_iter_next(&it)
			if !ok {break}
			txnum := u32(it.index - 1)
			txs += 1

			// txloc row: absolute offset of the tx within the blk file.
			txloc_row_encode(
				trow[:],
				tx.txid,
				u16(f.file_no),
				h.offset + tx.offset,
				u32(len(tx.raw)),
				height,
			)
			worker_scatter_add(&ws_txloc, key_bucket(trow[:], bits), trow[:]) or_return

			// Outputs: funding join rows only. Phase 2 derives the history
			// funding rows from these, so no separate history scatter.
			oit: Tx_Output_Iter
			tx_output_iter_init(&oit, &tx)
			for {
				out, vout, ook := tx_output_iter_next(&oit)
				if !ook {break}
				sh := scripthash(out.script)
				joinf_row_encode(jfrow[:], tx.txid, u32(vout), sh, out.value, height, txnum)
				worker_scatter_add(&ws_joinf, key_bucket(jfrow[:], bits), jfrow[:]) or_return
			}

			// Inputs: spend join rows. Phase 2 ingests these directly as
			// the spends keyspace. Coinbase has none.
			if !tx.is_coinbase {
				iit: Tx_Input_Iter
				tx_input_iter_init(&iit, &tx)
				for {
					inp, vin, iok := tx_input_iter_next(&iit)
					if !iok {break}
					joins_row_encode(jsrow[:], inp.prev_txid, inp.vout, height, txnum, u32(vin))
					worker_scatter_add(&ws_joins, key_bucket(jsrow[:], bits), jsrow[:]) or_return
				}
			}
		}
		if it.err != nil {
			log.errorf("hugin: bad transaction data at height %d in %s", height, f.path)
			return it.err
		}
	}

	worker_scatter_flush(&ws_txloc) or_return
	worker_scatter_flush(&ws_joinf) or_return
	worker_scatter_flush(&ws_joins) or_return

	sync.atomic_add(&b.txs_done, txs)
	done := sync.atomic_add(&b.files_done, 1) + 1
	log.infof(
		"hugin: phase 1: %s done (%d blocks, %d txs) [%d/%d files]",
		f.path,
		len(heights),
		txs,
		done,
		len(b.files),
	)
	return nil
}

// ---------------------------------------------------------------------------
// Phase 2 task: one join bucket.

P2_Task :: struct {
	b:            ^Build,
	bucket:       int,
	funding_rows: int,
	spend_rows:   int,
	err:          Error,
}

@(private = "file")
p2_task_proc :: proc(task: thread.Task) {
	t := cast(^P2_Task)task.data
	if stop_was_requested() {
		t.err = Usage_Error.Cancelled
		build_set_err(t.b, t.err)
		return
	}
	ws: Worker_Scatter
	worker_scatter_init(&ws, &t.b.sc_history, HISTORY_ROW_SIZE)
	defer worker_scatter_destroy(&ws)

	t.funding_rows, t.spend_rows, t.err = join_bucket(
		&t.b.sc_joinf,
		&t.b.sc_joins,
		t.bucket,
		&ws,
		t.b.cfg.bucket_bits,
		t.b.db_spends,
		t.b.cfg.compact,
	)
	if t.err == nil {
		t.err = worker_scatter_flush(&ws)
	}
	build_set_err(t.b, t.err)

	build_progress_tick(t.b, &t.b.p2_done, t.b.n_buckets, "phase 2: joined")
}

// ---------------------------------------------------------------------------
// Phase 3 task: one bucket of one keyspace.

P3_Keyspace :: enum {
	History,
	Txloc,
}

P3_Task :: struct {
	b:        ^Build,
	bucket:   int,
	keyspace: P3_Keyspace,
	err:      Error,
}

@(private = "file")
p3_task_proc :: proc(task: thread.Task) {
	t := cast(^P3_Task)task.data
	if stop_was_requested() {
		t.err = Usage_Error.Cancelled
		build_set_err(t.b, t.err)
		return
	}
	t.err = p3_run(t.b, t.bucket, t.keyspace)
	build_set_err(t.b, t.err)

	build_progress_tick(t.b, &t.b.p3_done, 2 * t.b.n_buckets, "phase 3: sorted and ingested")
}

Compact_Keyspace :: enum {
	History,
	Txloc,
	Spends,
}

// compact_ingest converts full rows to their compact form, re-sorts (the
// full-key order does not survive prefix truncation: bytes 8..31 of the
// hash broke ties that the compact key breaks differently), and ingests
// one bucket. Shared by the bulk build and tier promotion.
compact_ingest :: proc(db: ^munin.Db, bucket: u32, data: []byte, ks: Compact_Keyspace) -> (err: Error) {
	full_size, crow, ckey: int
	switch ks {
	case .History:
		full_size = HISTORY_ROW_SIZE
		crow = C_HISTORY_ROW_SIZE
		ckey = C_HISTORY_KEY_LEN
	case .Txloc:
		full_size = TXLOC_ROW_SIZE
		crow = C_TXLOC_ROW_SIZE
		ckey = C_TXLOC_KEY_LEN
	case .Spends:
		full_size = SPENDS_ROW_SIZE
		crow = C_SPENDS_ROW_SIZE
		ckey = C_SPENDS_KEY_LEN
	}
	n := len(data) / full_size
	if n == 0 {
		return nil
	}
	cdata := make([]byte, n * crow)
	defer delete(cdata)
	for i in 0 ..< n {
		src := data[i * full_size:(i + 1) * full_size]
		dst := cdata[i * crow:(i + 1) * crow]
		switch ks {
		case .History:
			history_row_compact(src, dst)
		case .Txloc:
			txloc_row_compact(src, dst)
		case .Spends:
			spends_row_compact(src, dst)
		}
	}
	scratch := make([]byte, len(cdata))
	defer delete(scratch)
	radix_sort_rows(cdata, crow, ckey, scratch)

	ing := munin.ingest_begin(db, bucket) or_return
	for i in 0 ..< n {
		row := cdata[i * crow:(i + 1) * crow]
		if i > 0 && bytes_equal(cdata[(i - 1) * crow:][:ckey], row[:ckey]) {
			// Real entries have unique compact keys by construction (disk
			// locations and io slots are unique); a duplicate means the
			// same row was fed twice.
			munin.ingest_abort(ing)
			return Corruption.Bad_Record
		}
		munin.ingest_add(ing, row[:ckey], row[ckey:]) or_return
	}
	if _, ferr := munin.ingest_finish(ing); ferr != nil {
		return ferr
	}
	return nil
}

@(private = "file")
p3_run :: proc(b: ^Build, bucket: int, keyspace: P3_Keyspace) -> (err: Error) {
	sc: ^Scatter
	db: ^munin.Db
	row_size, key_len: int
	switch keyspace {
	case .History:
		sc = &b.sc_history
		db = b.db_history
		row_size = HISTORY_ROW_SIZE
		key_len = HISTORY_KEY_LEN
	case .Txloc:
		sc = &b.sc_txloc
		db = b.db_txloc
		row_size = TXLOC_ROW_SIZE
		key_len = TXLOC_KEY_LEN
	}

	data := scatter_read_bucket(sc, bucket) or_return
	defer delete(data)
	// In memory now: free the spill file so the index being written below
	// can reuse the space.
	scatter_delete_bucket(sc, bucket)
	if len(data) == 0 {
		return nil
	}
	if len(data) % row_size != 0 {
		return Corruption.Bad_Record
	}
	n := len(data) / row_size

	if b.cfg.compact {
		// BIP-30 duplicate txids keep both rows in compact form (their
		// disk locations differ); queries pick the later height.
		return compact_ingest(
			db,
			u32(bucket),
			data,
			.History if keyspace == .History else .Txloc,
		)
	}

	scratch := make([]byte, len(data))
	defer delete(scratch)
	radix_sort_rows(data, row_size, key_len, scratch)

	ing := munin.ingest_begin(db, u32(bucket)) or_return
	added := 0
	for i in 0 ..< n {
		row := data[i * row_size:(i + 1) * row_size]
		key := row[:key_len]
		value := row[key_len:]

		if i + 1 < n {
			next := data[(i + 1) * row_size:]
			if bytes_equal(key, next[:key_len]) {
				// Duplicate key. For txloc this is BIP-30: identical
				// coinbase txids at two heights, later height wins — skip
				// this earlier row. Rows are height-ordered within equal
				// txids because phase 1 encodes height into the value and
				// the radix sort is stable only over the key, so compare
				// heights explicitly.
				if keyspace == .Txloc {
					h_this := txloc_value_decode(value).height
					h_next := txloc_value_decode(next[key_len:key_len + 14]).height
					if h_this <= h_next {
						continue // later height wins
					}
					// This row is the later one: skip the next instead by
					// swapping it forward.
					copy(next[:row_size], row)
					continue
				}
				// Any other keyspace: duplicate keys are impossible on a
				// valid chain.
				log.errorf(
					"hugin: duplicate key in %v bucket %04x",
					keyspace,
					bucket,
				)
				munin.ingest_abort(ing)
				return Corruption.Bad_Record
			}
		}
		munin.ingest_add(ing, key, value) or_return
		added += 1
	}
	_, ferr := munin.ingest_finish(ing)
	if ferr != nil {
		return ferr
	}
	_ = added
	return nil
}

@(private)
bytes_equal :: proc "contextless" (a, b: []byte) -> bool {
	if len(a) != len(b) {return false}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {return false}
	}
	return true
}
