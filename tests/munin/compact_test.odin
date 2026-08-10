package munin_tests

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import munin "../../munin"

@(private = "file")
count_run_files :: proc(dir: string) -> int {
	entries, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {return -1}
	n := 0
	for e in entries {
		if strings.has_suffix(e.name, ".run") {n += 1}
	}
	return n
}

@(test)
test_compact_bucket :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_compact_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	dbdir := fmt.aprintf("%s/db", dir)
	defer delete(dbdir)

	all := gen_db_keys(3000, {9})
	defer {
		for k in all {delete(k)}
		delete(all)
	}
	// Three generations, interleaved thirds.
	gens: [3][dynamic][]byte
	defer for &g in gens {delete(g)}
	for k, i in all {
		append(&gens[i % 3], k)
	}

	db, err := munin.db_create(dbdir, TEST_CFG)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	defer munin.db_close(db)

	for &g in gens {
		ingest_all(t, db, g[:])
		testing.expect_value(t, munin.db_commit(db), nil)
	}
	testing.expect_value(t, munin.db_bucket_run_count(db, 9), 3)
	testing.expect_value(t, count_run_files(dbdir), 3)

	// Open an iterator BEFORE compaction: it pins the old runs and must
	// keep reading correct data afterwards.
	pinned := munin.iter_make(db)
	testing.expect_value(t, munin.iter_seek(pinned, []byte{}), nil)
	// Consume a few entries now; the rest after compaction.
	for _ in 0 ..< 10 {
		testing.expect(t, munin.iter_valid(pinned))
		testing.expect_value(t, munin.iter_next(pinned), nil)
	}

	testing.expect_value(t, munin.db_compact_bucket(db, 9), nil)
	testing.expect_value(t, munin.db_bucket_run_count(db, 9), 1)

	// Old files must still exist while pinned (3 old + 1 new).
	testing.expect_value(t, count_run_files(dbdir), 4)

	// The pinned iterator keeps walking the old runs to the end.
	count := 10
	for munin.iter_valid(pinned) {
		count += 1
		testing.expect_value(t, munin.iter_next(pinned), nil)
	}
	testing.expect_value(t, count, len(all))
	munin.iter_close(pinned)
	free(pinned)

	// Releasing the iterator deletes the retired files.
	testing.expect_value(t, count_run_files(dbdir), 1)

	// Fresh reads see everything.
	verify_db(t, db, all)

	// Reopen from disk: manifest must reflect the compacted state.
	munin.db_close(db)
	db2, oerr := munin.db_open(dbdir)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	testing.expect_value(t, munin.db_bucket_run_count(db2, 9), 1)
	verify_db(t, db2, all)
	munin.db_close(db2)
	// Re-close guard for the deferred close above.
	db = nil
}

@(test)
test_compact_single_run_noop :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_compact_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	dbdir := fmt.aprintf("%s/db", dir)
	defer delete(dbdir)

	keys := gen_db_keys(200, {4})
	defer {
		for k in keys {delete(k)}
		delete(keys)
	}

	db, err := munin.db_create(dbdir, TEST_CFG)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	defer munin.db_close(db)

	ingest_all(t, db, keys)
	testing.expect_value(t, munin.db_commit(db), nil)
	testing.expect_value(t, munin.db_compact_bucket(db, 4), nil)
	testing.expect_value(t, munin.db_bucket_run_count(db, 4), 1)
	verify_db(t, db, keys)

	// Compacting an untouched bucket is also a no-op.
	testing.expect_value(t, munin.db_compact_bucket(db, 200), nil)
}
