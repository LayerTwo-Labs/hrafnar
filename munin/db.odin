package munin

// Db lifecycle: create, open (with recovery), commit, point get, iterators.

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"

Db :: struct {
	dir:            string, // owned
	cfg:            Config,
	manifest:       Manifest,
	runs:           map[u64]^Run, // open runs by id
	bucket_runs:    map[u32][dynamic]^Run, // open runs grouped by bucket
	cache:          Cache,
	mu:             sync.Mutex, // guards manifest, runs, ingests, pending
	active_ingests: map[u32]^Ingest,
	pending_runs:   [dynamic]Manifest_Run, // finished ingests awaiting commit
	obsolete:       [dynamic]^Run, // dropped from manifest, pinned by iterators
	allocator:      runtime.Allocator,
}

@(private)
run_path :: proc(dir: string, run_id: u64) -> string {
	return fmt.tprintf("%s/%08x.run", dir, run_id)
}

@(private)
os_remove_best_effort :: proc(path: string) {
	if rerr := os.remove(path); rerr != nil {
		log.warnf("munin: could not delete %s: %v", path, rerr)
	}
}

// ensure_dir is make_directory_all treating an existing path as success
// (os.make_directory_all returns .Exist for one, unlike most mkdir -p
// analogues).
@(private)
ensure_dir :: proc(dir: string) -> Error {
	merr := os.make_directory_all(dir)
	if merr != nil {
		if ge, is_ge := merr.(os.General_Error); is_ge && ge == .Exist {
			return nil
		}
		return merr
	}
	return nil
}

db_create :: proc(
	dir: string,
	cfg: Config,
	allocator := context.allocator,
) -> (
	db: ^Db,
	err: Error,
) {
	cfg := config_fill_defaults(cfg)
	config_validate(cfg) or_return

	ensure_dir(dir) or_return

	manifest_path := fmt.tprintf("%s/%s", dir, MANIFEST_NAME)
	if _, serr := os.stat(manifest_path, context.temp_allocator); serr == nil {
		return nil, os.Error(os.General_Error.Exist)
	}

	db = db_alloc(dir, cfg, allocator) or_return
	manifest_init(&db.manifest, cfg, allocator)

	werr := manifest_write(dir, &db.manifest)
	if werr != nil {
		db_free(db)
		return nil, werr
	}
	return db, nil
}

db_open :: proc(dir: string, allocator := context.allocator) -> (db: ^Db, err: Error) {
	m, merr := manifest_read(dir, allocator)
	if merr != nil {
		// A tmp manifest without a real one is a crash before the rename
		// committed: a complete but unpublished generation. Never promote
		// it; the caller was never told it committed.
		if os_is_not_exist(merr) {
			tmp := fmt.tprintf("%s/%s", dir, MANIFEST_TMP_NAME)
			if _, terr := os.stat(tmp, context.temp_allocator); terr == nil {
				log.warnf("munin: discarding uncommitted %s", tmp)
				os.remove(tmp)
			}
		}
		return nil, merr
	}

	cfg := config_fill_defaults(
		Config {
			bucket_bits         = m.bucket_bits,
			key_only            = m.key_only,
			filter_prefix_len   = int(m.prefix_len) if m.has_filter else 0,
			filter_bits_per_key = int(m.bits_per_key),
		},
	)

	aerr: Error
	db, aerr = db_alloc(dir, cfg, allocator)
	if aerr != nil {
		manifest_destroy(&m, allocator)
		return nil, aerr
	}
	db.manifest = m
	// The named return db must keep pointing at the allocation for this
	// cleanup to work, so error paths below set err and return rather than
	// returning a nil db directly.
	defer if err != nil {
		db_free(db)
		db = nil
	}

	// Leftover tmp manifest from a crash after a successful generation was
	// already committed: stale, discard.
	tmp := fmt.tprintf("%s/%s", dir, MANIFEST_TMP_NAME)
	if _, terr := os.stat(tmp, context.temp_allocator); terr == nil {
		log.warnf("munin: discarding stale %s", tmp)
		os.remove(tmp)
	}

	// Register every referenced run WITHOUT touching its file: opening and
	// verifying thousands of runs here costs tens of seconds on slow
	// disks, and queries reach a handful. The manifest's size claim is
	// enforced on each run's first use.
	for &mr in db.manifest.runs {
		path := fmt.tprintf("%s/%08x.run", dir, mr.run_id)
		r := run_make_lazy(path, mr.run_id, mr.file_size, &db.cache, allocator) or_return
		db_track_run(db, mr.bucket, r)
	}

	// Any .run file not in the manifest is an orphan from an interrupted
	// write: log and delete.
	db_delete_orphans(db) or_return
	return db, nil
}

db_close :: proc(db: ^Db) {
	if db == nil {return}
	db_free(db)
}

// db_commit publishes all finished ingests: rewrites the manifest with the
// full durability protocol, then opens the new runs for reading.
db_commit :: proc(db: ^Db) -> (err: Error) {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)

	if len(db.pending_runs) == 0 {
		return nil
	}

	old_count := len(db.manifest.runs)
	append(&db.manifest.runs, ..db.pending_runs[:])
	clear(&db.pending_runs)

	werr := manifest_write(db.dir, &db.manifest)
	if werr != nil {
		// Roll the in-memory manifest back; the files stay on disk as
		// orphans for the next open to clean.
		for &mr in db.manifest.runs[old_count:] {
			delete(mr.min_key, db.allocator)
			delete(mr.max_key, db.allocator)
		}
		resize(&db.manifest.runs, old_count)
		return werr
	}

	for &mr in db.manifest.runs[old_count:] {
		path := fmt.tprintf("%s/%08x.run", db.dir, mr.run_id)
		r := run_make_lazy(path, mr.run_id, mr.file_size, &db.cache, db.allocator) or_return
		db_track_run(db, mr.bucket, r)
	}
	return nil
}

// db_get returns a copy of the value for key, allocated from the given
// allocator.
db_get :: proc(
	db: ^Db,
	key: []byte,
	allocator := context.allocator,
) -> (
	value: []byte,
	found: bool,
	err: Error,
) {
	bucket := bucket_of(key, db.cfg.bucket_bits) or_return

	// Snapshot and pin under the lock so compaction cannot delete a run
	// out from under the read.
	sync.mutex_lock(&db.mu)
	candidates := make([dynamic]^Run, context.temp_allocator)
	// Indexing the map inside the for-header iterates the entry by
	// reference and crashes on a missing bucket; fetch with comma-ok.
	if runs, has := db.bucket_runs[bucket]; has {
		for r in runs {
			r.refs += 1
			append(&candidates, r)
		}
	}
	sync.mutex_unlock(&db.mu)
	defer {
		sync.mutex_lock(&db.mu)
		for r in candidates {
			r.refs -= 1
		}
		db_sweep_obsolete(db)
		sync.mutex_unlock(&db.mu)
	}

	for r in candidates {
		if !run_filter_check(r, key) {
			continue
		}
		it: Run_Iter
		run_iter_init(&it, r, context.temp_allocator)
		defer run_iter_destroy(&it)
		run_iter_seek(&it, key)
		if it.err != nil {
			return nil, false, it.err
		}
		if run_iter_valid(&it) && string(run_iter_key(&it)) == string(key) {
			v := run_iter_value(&it)
			value = make([]byte, len(v), allocator)
			copy(value, v)
			return value, true, nil
		}
	}
	return nil, false, nil
}

// iter_make returns a merging iterator over every run in the database.
// Additional sources (a caller's in-memory tier) attach via
// iter_add_source before the first seek.
iter_make :: proc(db: ^Db, allocator := context.allocator) -> ^Iter {
	it := new(Iter, allocator)
	iter_init(it, allocator)
	it.db = db

	sync.mutex_lock(&db.mu)
	for _, r in db.runs {
		r.refs += 1
		iter_add_run(it, r)
	}
	sync.mutex_unlock(&db.mu)
	return it
}

// iter_make_bucket returns a merging iterator over a single bucket's runs
// — the right tool whenever the key prefix determines the bucket, which
// turns a merge over thousands of runs into one over a handful.
iter_make_bucket :: proc(db: ^Db, bucket: u32, allocator := context.allocator) -> ^Iter {
	it := new(Iter, allocator)
	iter_init(it, allocator)
	it.db = db

	sync.mutex_lock(&db.mu)
	if runs, has := db.bucket_runs[bucket]; has {
		for r in runs {
			r.refs += 1
			iter_add_run(it, r)
		}
	}
	sync.mutex_unlock(&db.mu)
	return it
}

// db_iter_closed unpins the iterator's runs, deleting any retired run
// whose last pin this was. Called from iter_close.
db_iter_closed :: proc(db: ^Db, it: ^Iter) {
	sync.mutex_lock(&db.mu)
	for &b in it.backends {
		if b.run_it != nil {
			b.run_it.run.refs -= 1
		}
	}
	db_sweep_obsolete(db)
	sync.mutex_unlock(&db.mu)
}

// db_sweep_obsolete deletes retired runs whose pin count reached zero.
// Caller holds db.mu.
@(private)
db_sweep_obsolete :: proc(db: ^Db) {
	i := 0
	for i < len(db.obsolete) {
		r := db.obsolete[i]
		if r.refs == 0 {
			db_delete_run_now(db, r)
			db.obsolete[i] = db.obsolete[len(db.obsolete) - 1]
			resize(&db.obsolete, len(db.obsolete) - 1)
			continue
		}
		i += 1
	}
}

// ---------------------------------------------------------------------------

@(private = "file")
db_alloc :: proc(
	dir: string,
	cfg: Config,
	allocator: runtime.Allocator,
) -> (
	db: ^Db,
	err: Error,
) {
	db = new(Db, allocator)
	perr: runtime.Allocator_Error
	db.dir, perr = clone_string(dir, allocator)
	if perr != nil {
		free(db, allocator)
		return nil, os.Error(perr)
	}
	db.cfg = cfg
	db.runs = make(map[u64]^Run, allocator)
	db.bucket_runs = make(map[u32][dynamic]^Run, allocator)
	db.active_ingests = make(map[u32]^Ingest, allocator)
	db.pending_runs = make([dynamic]Manifest_Run, allocator)
	db.obsolete = make([dynamic]^Run, allocator)
	cache_init(&db.cache, cfg.cache_bytes, allocator)
	db.allocator = allocator
	return db, nil
}

@(private = "file")
db_free :: proc(db: ^Db) {
	for _, r in db.runs {
		run_close(r)
	}
	delete(db.runs)
	for r in db.obsolete {
		run_close(r)
	}
	delete(db.obsolete)
	for _, &lst in db.bucket_runs {
		delete(lst)
	}
	delete(db.bucket_runs)
	delete(db.active_ingests)
	for &mr in db.pending_runs {
		delete(mr.min_key, db.allocator)
		delete(mr.max_key, db.allocator)
	}
	delete(db.pending_runs)
	manifest_destroy(&db.manifest, db.allocator)
	cache_destroy(&db.cache)
	delete(db.dir, db.allocator)
	free(db, db.allocator)
}

@(private = "file")
db_track_run :: proc(db: ^Db, bucket: u32, r: ^Run) {
	db.runs[r.run_id] = r
	lst, ok := &db.bucket_runs[bucket]
	if !ok {
		db.bucket_runs[bucket] = make([dynamic]^Run, db.allocator)
		lst = &db.bucket_runs[bucket]
	}
	append(lst, r)
}

@(private = "file")
db_delete_orphans :: proc(db: ^Db) -> (err: Error) {
	entries, rerr := os.read_directory_by_path(db.dir, -1, context.temp_allocator)
	if rerr != nil {
		return rerr
	}
	for e in entries {
		name := e.name
		if !strings.has_suffix(name, ".run") {
			continue
		}
		id, ok := strconv.parse_u64_of_base(strings.trim_suffix(name, ".run"), 16)
		known := false
		if ok {
			_, known = db.runs[id]
		}
		if !known {
			log.warnf("munin: deleting orphan run file %s", name)
			os.remove(fmt.tprintf("%s/%s", db.dir, name))
		}
	}
	return nil
}

@(private = "file")
os_is_not_exist :: proc(err: Error) -> bool {
	oe, ok := err.(os.Error)
	if !ok {return false}
	ge, gok := oe.(os.General_Error)
	return gok && ge == .Not_Exist
}
