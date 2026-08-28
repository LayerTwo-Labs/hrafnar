package munin

// In-bucket compaction: merge every run in a bucket into a single level-1
// run and atomically swap the manifest. Because keys are unique and never
// overwritten this is a plain k-way merge — no tombstones, no versions.
//
// Old run files pinned by open iterators are not deleted until the last
// iterator releases them (refcount-deferred deletion).

import "core:log"
import "core:sync"

// db_run_count reports how many runs the database holds in total. Every
// one of them costs a Run struct and a parsed manifest record each time
// the database is opened, so this is the number that makes reopening
// progressively more expensive when compaction falls behind.
db_run_count :: proc(db: ^Db) -> int {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)
	return len(db.manifest.runs)
}

// db_bucket_run_count reports how many runs a bucket currently holds,
// the signal callers use to decide when compaction pays.
db_bucket_run_count :: proc(db: ^Db, bucket: u32) -> int {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)
	if runs, has := db.bucket_runs[bucket]; has {
		return len(runs)
	}
	return 0
}

// db_compact_bucket merges all of a bucket's runs into one level-1 run.
// No-op when the bucket has fewer than two runs. Concurrent ingest into
// the same bucket is excluded via the same reservation ingests use.
db_compact_bucket :: proc(db: ^Db, bucket: u32) -> (err: Error) {
	if bucket >= 1 << db.cfg.bucket_bits {
		return Usage_Error.Wrong_Bucket
	}

	// Reserve the bucket against concurrent ingest/compaction.
	sync.mutex_lock(&db.mu)
	if bucket in db.active_ingests {
		sync.mutex_unlock(&db.mu)
		return Usage_Error.Bucket_Busy
	}
	db.active_ingests[bucket] = nil
	old_runs := make([dynamic]^Run, context.temp_allocator)
	if runs, has := db.bucket_runs[bucket]; has {
		for r in runs {
			append(&old_runs, r)
		}
	}
	if len(old_runs) < 2 {
		delete_key(&db.active_ingests, bucket)
		sync.mutex_unlock(&db.mu)
		return nil
	}
	// Pin the inputs for the duration of the merge.
	for r in old_runs {r.refs += 1}
	run_id := db.manifest.next_run_id
	db.manifest.next_run_id += 1
	sync.mutex_unlock(&db.mu)

	defer {
		sync.mutex_lock(&db.mu)
		delete_key(&db.active_ingests, bucket)
		sync.mutex_unlock(&db.mu)
	}
	unpin := true
	defer if unpin {
		sync.mutex_lock(&db.mu)
		for r in old_runs {r.refs -= 1}
		sync.mutex_unlock(&db.mu)
	}

	// Merge into a new run file.
	it: Iter
	iter_init(&it, context.temp_allocator)
	defer iter_close(&it)
	for r in old_runs {
		iter_add_run(&it, r)
	}

	path := run_path(db.dir, run_id)
	w: Run_Writer
	run_writer_begin(
		&w,
		path,
		Run_Writer_Config {
			block_size          = db.cfg.block_size,
			restart_interval    = db.cfg.restart_interval,
			key_only            = db.cfg.key_only,
			filter_prefix_len   = db.cfg.filter_prefix_len,
			filter_bits_per_key = db.cfg.filter_bits_per_key,
		},
		db.allocator,
	) or_return
	// After a successful finish the writer's file handle is nil, so this
	// destroys buffers only; on an earlier error it also removes the
	// partial file.
	defer run_writer_abort(&w)

	iter_seek(&it, []byte{}) or_return
	for iter_valid(&it) {
		run_writer_add(&w, iter_key(&it), iter_value(&it)) or_return
		iter_next(&it) or_return
	}

	res := run_writer_finish(&w) or_return

	min_key := make([]byte, len(w.min_key), db.allocator)
	copy(min_key, w.min_key[:])
	max_key := make([]byte, len(w.max_key), db.allocator)
	copy(max_key, w.max_key[:])

	// Swap the manifest: drop the old records, add the new one.
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)

	old_ids := make(map[u64]struct {}, context.temp_allocator)
	for r in old_runs {
		old_ids[r.run_id] = {}
	}
	kept := make([dynamic]Manifest_Run, db.allocator)
	for &mr in db.manifest.runs {
		if mr.run_id in old_ids {
			delete(mr.min_key, db.allocator)
			delete(mr.max_key, db.allocator)
			continue
		}
		append(&kept, mr)
	}
	append(
		&kept,
		Manifest_Run {
			run_id      = run_id,
			bucket      = bucket,
			level       = 1,
			entry_count = res.entry_count,
			file_size   = res.file_size,
			min_key     = min_key,
			max_key     = max_key,
		},
	)
	old_manifest_runs := db.manifest.runs
	db.manifest.runs = kept

	werr := manifest_write(db.dir, &db.manifest)
	if werr != nil {
		// Restore the previous manifest state; the new file becomes an
		// orphan for the next open to clean up.
		for &mr in db.manifest.runs {
			if mr.run_id == run_id {
				delete(mr.min_key, db.allocator)
				delete(mr.max_key, db.allocator)
			}
		}
		delete(db.manifest.runs)
		db.manifest.runs = old_manifest_runs
		return werr
	}
	delete(old_manifest_runs)

	// Register the new run (lazily opened) and swap the in-memory maps.
	new_run, oerr := run_make_lazy(path, run_id, res.file_size, &db.cache, db.allocator)
	if oerr != nil {
		// The manifest is already durable with the new run; failing to
		// open it now is a hard fault.
		return oerr
	}

	blist := &db.bucket_runs[bucket]
	clear(blist)
	append(blist, new_run)
	db.runs[run_id] = new_run

	// Unpin and retire the old runs.
	unpin = false
	for r in old_runs {
		delete_key(&db.runs, r.run_id)
		r.refs -= 1
		db_retire_run(db, r)
	}
	log.debugf(
		"munin: compacted bucket %04x: %d runs -> run %08x (%d entries)",
		bucket,
		len(old_runs),
		run_id,
		res.entry_count,
	)
	return nil
}

// db_retire_run removes a run that is no longer in the manifest. Deletion
// happens now if unpinned, or when the last iterator releases it.
// Caller holds db.mu.
db_retire_run :: proc(db: ^Db, r: ^Run) {
	if r.refs > 0 {
		append(&db.obsolete, r)
		return
	}
	db_delete_run_now(db, r)
}

// Caller holds db.mu.
db_delete_run_now :: proc(db: ^Db, r: ^Run) {
	cache_drop_run(&db.cache, r.run_id)
	path := r.path
	log.debugf("munin: deleting obsolete run %08x", r.run_id)
	os_remove_best_effort(path)
	run_close(r)
}
