package munin

// Bucket ingest path. The caller supplies keys already sorted and already
// routed to the right bucket; Munin verifies both. Multiple Ingest handles
// for different buckets may be live on different threads simultaneously;
// two handles for the same bucket is Usage_Error. Nothing is visible to
// readers until db_commit.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sync"

Ingest :: struct {
	db:     ^Db,
	bucket: u32,
	run_id: u64,
	rw:     Run_Writer,
	path:   string, // owned
	active: bool,
}

ingest_begin :: proc(db: ^Db, bucket: u32) -> (ing: ^Ingest, err: Error) {
	if bucket >= 1 << db.cfg.bucket_bits {
		return nil, Usage_Error.Wrong_Bucket
	}

	sync.mutex_lock(&db.mu)
	if bucket in db.active_ingests {
		sync.mutex_unlock(&db.mu)
		return nil, Usage_Error.Bucket_Busy
	}
	run_id := db.manifest.next_run_id
	db.manifest.next_run_id += 1
	// Reserve the bucket before dropping the lock.
	db.active_ingests[bucket] = nil
	sync.mutex_unlock(&db.mu)

	defer if err != nil {
		sync.mutex_lock(&db.mu)
		delete_key(&db.active_ingests, bucket)
		sync.mutex_unlock(&db.mu)
	}

	ing = new(Ingest, db.allocator)
	defer if err != nil {
		free(ing, db.allocator)
		ing = nil
	}
	ing.db = db
	ing.bucket = bucket
	ing.run_id = run_id
	perr: runtime.Allocator_Error
	ing.path, perr = clone_string(fmt.tprintf("%s/%08x.run", db.dir, run_id), db.allocator)
	if perr != nil {
		return nil, os.Error(perr)
	}
	defer if err != nil {delete(ing.path, db.allocator)}

	run_writer_begin(
		&ing.rw,
		ing.path,
		Run_Writer_Config {
			block_size          = db.cfg.block_size,
			restart_interval    = db.cfg.restart_interval,
			key_only            = db.cfg.key_only,
			filter_prefix_len   = db.cfg.filter_prefix_len,
			filter_bits_per_key = db.cfg.filter_bits_per_key,
		},
		db.allocator,
	) or_return
	ing.active = true

	sync.mutex_lock(&db.mu)
	db.active_ingests[bucket] = ing
	sync.mutex_unlock(&db.mu)
	return ing, nil
}

ingest_add :: proc(ing: ^Ingest, key, value: []byte) -> Error {
	if !ing.active {
		return Usage_Error.Ingest_Misuse
	}
	b := bucket_of(key, ing.db.cfg.bucket_bits) or_return
	if b != ing.bucket {
		return Usage_Error.Wrong_Bucket
	}
	if ing.db.cfg.key_only && len(value) > 0 {
		return Usage_Error.Ingest_Misuse
	}
	return run_writer_add(&ing.rw, key, value)
}

// ingest_finish completes the run file. The run becomes visible to readers
// only at the next db_commit.
ingest_finish :: proc(ing: ^Ingest) -> (run_id: u64, err: Error) {
	if !ing.active {
		return 0, Usage_Error.Ingest_Misuse
	}
	db := ing.db
	run_id = ing.run_id

	defer if err != nil {
		ingest_teardown(ing)
	}

	res := run_writer_finish(&ing.rw) or_return

	min_key := make([]byte, len(ing.rw.min_key), db.allocator)
	copy(min_key, ing.rw.min_key[:])
	max_key := make([]byte, len(ing.rw.max_key), db.allocator)
	copy(max_key, ing.rw.max_key[:])

	sync.mutex_lock(&db.mu)
	append(
		&db.pending_runs,
		Manifest_Run {
			run_id      = ing.run_id,
			bucket      = ing.bucket,
			level       = 0,
			entry_count = res.entry_count,
			file_size   = res.file_size,
			min_key     = min_key,
			max_key     = max_key,
		},
	)
	sync.mutex_unlock(&db.mu)

	ingest_teardown(ing)
	return run_id, nil
}

// ingest_abort discards the partial run file.
ingest_abort :: proc(ing: ^Ingest) {
	if !ing.active {
		return
	}
	run_writer_abort(&ing.rw)
	// run_writer_abort already destroyed the writer; skip the double
	// destroy in teardown.
	ing.active = false
	db := ing.db
	sync.mutex_lock(&db.mu)
	delete_key(&db.active_ingests, ing.bucket)
	sync.mutex_unlock(&db.mu)
	delete(ing.path, db.allocator)
	free(ing, db.allocator)
}

@(private = "file")
ingest_teardown :: proc(ing: ^Ingest) {
	db := ing.db
	run_writer_destroy(&ing.rw)
	sync.mutex_lock(&db.mu)
	delete_key(&db.active_ingests, ing.bucket)
	sync.mutex_unlock(&db.mu)
	delete(ing.path, db.allocator)
	free(ing, db.allocator)
}
