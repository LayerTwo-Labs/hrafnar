package munin_tests

import "core:bytes"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:testing"

import munin "../../munin"

// bucket_bits = 8 in these tests, so bucket == key[0].
TEST_CFG :: munin.Config {
	bucket_bits         = 8,
	block_size          = 512,
	restart_interval    = 8,
	filter_prefix_len   = 4,
	filter_bits_per_key = 10,
	cache_bytes         = 1 << 20,
}

// Sorted unique keys spanning a handful of buckets.
gen_db_keys :: proc(n: int, buckets: []u8) -> [][]byte {
	seen := make(map[u64]struct {})
	defer delete(seen)
	vals := make([dynamic]u64)
	defer delete(vals)
	for len(vals) < n {
		b := buckets[rand.int_max(len(buckets))]
		v := u64(b) << 32 | u64(rand.uint32())
		if v in seen {continue}
		seen[v] = {}
		append(&vals, v)
	}
	slice.sort(vals[:])
	out := make([][]byte, n)
	for v, i in vals {
		k := make([]byte, 5)
		k[0] = byte(v >> 32)
		k[1] = byte(v >> 24)
		k[2] = byte(v >> 16)
		k[3] = byte(v >> 8)
		k[4] = byte(v)
		out[i] = k
	}
	return out
}

ingest_all :: proc(t: ^testing.T, db: ^munin.Db, keys: [][]byte) {
	// Group keys by bucket (keys are sorted, buckets are contiguous).
	i := 0
	for i < len(keys) {
		bucket := u32(keys[i][0])
		ing, err := munin.ingest_begin(db, bucket)
		testing.expect_value(t, err, nil)
		if err != nil {return}
		for i < len(keys) && u32(keys[i][0]) == bucket {
			testing.expect_value(t, munin.ingest_add(ing, keys[i], keys[i]), nil)
			i += 1
		}
		_, ferr := munin.ingest_finish(ing)
		testing.expect_value(t, ferr, nil)
	}
}

verify_db :: proc(t: ^testing.T, db: ^munin.Db, keys: [][]byte) {
	// Point lookups.
	for k in keys {
		v, found, err := munin.db_get(db, k)
		testing.expect_value(t, err, nil)
		testing.expectf(t, found, "key % x not found", k)
		if found {
			testing.expect(t, bytes.compare(v, k) == 0, "wrong value")
			delete(v)
		}
	}
	// A missing key.
	missing := []byte{0xEE, 0xEE, 0xEE, 0xEE, 0xEE}
	_, found, err := munin.db_get(db, missing)
	testing.expect_value(t, err, nil)
	testing.expect(t, !found, "phantom key")

	// Full merged iteration in order.
	it := munin.iter_make(db)
	defer {
		munin.iter_close(it)
		free(it)
	}
	testing.expect_value(t, munin.iter_seek(it, []byte{}), nil)
	for k, i in keys {
		testing.expectf(t, munin.iter_valid(it), "db scan died at %d (err=%v)", i, it.err)
		if !munin.iter_valid(it) {return}
		testing.expectf(t, bytes.compare(munin.iter_key(it), k) == 0, "db scan[%d] wrong key", i)
		testing.expect_value(t, munin.iter_next(it), nil)
	}
	testing.expect(t, !munin.iter_valid(it), "db scan should be exhausted")
}

@(test)
test_db_bulk_path :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_db_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	dbdir := fmt.aprintf("%s/db", dir)
	defer delete(dbdir)

	keys := gen_db_keys(3000, {3, 7, 42, 200})
	defer {
		for k in keys {delete(k)}
		delete(keys)
	}

	db, err := munin.db_create(dbdir, TEST_CFG)
	testing.expect_value(t, err, nil)
	if err != nil {return}

	ingest_all(t, db, keys)
	testing.expect_value(t, munin.db_commit(db), nil)
	verify_db(t, db, keys)
	munin.db_close(db)

	// Reopen from disk and verify again.
	db2, oerr := munin.db_open(dbdir)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	verify_db(t, db2, keys)
	munin.db_close(db2)
}

@(test)
test_db_ingest_contract :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_db_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	dbdir := fmt.aprintf("%s/db", dir)
	defer delete(dbdir)

	db, err := munin.db_create(dbdir, TEST_CFG)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	defer munin.db_close(db)

	ing, ierr := munin.ingest_begin(db, 9)
	testing.expect_value(t, ierr, nil)

	// Same bucket again: busy.
	_, berr := munin.ingest_begin(db, 9)
	testing.expect_value(t, berr, munin.Error(munin.Usage_Error.Bucket_Busy))

	// Key routed to the wrong bucket.
	wrong := []byte{10, 0, 0, 0, 0}
	testing.expect_value(t, munin.ingest_add(ing, wrong, nil), munin.Error(munin.Usage_Error.Wrong_Bucket))

	// Key too short for bucket_bits.
	_, sberr := munin.bucket_of([]byte{}, 8)
	testing.expect_value(t, sberr, munin.Error(munin.Usage_Error.Key_Too_Short))

	// Out-of-range bucket.
	_, oberr := munin.ingest_begin(db, 256)
	testing.expect_value(t, oberr, munin.Error(munin.Usage_Error.Wrong_Bucket))

	munin.ingest_abort(ing)

	// After abort the bucket frees up.
	ing2, ierr2 := munin.ingest_begin(db, 9)
	testing.expect_value(t, ierr2, nil)
	ok := []byte{9, 1, 2, 3, 4}
	testing.expect_value(t, munin.ingest_add(ing2, ok, ok), nil)
	_, ferr := munin.ingest_finish(ing2)
	testing.expect_value(t, ferr, nil)
	testing.expect_value(t, munin.db_commit(db), nil)

	v, found, gerr := munin.db_get(db, ok)
	testing.expect_value(t, gerr, nil)
	testing.expect(t, found, "committed key must be visible")
	if found {delete(v)}
}

// Crash between writing MANIFEST.tmp and the rename: the reopened database
// must be the old generation, the tmp discarded, and the new run files
// deleted as orphans.
@(test)
test_db_crash_before_rename :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_db_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	dbdir := fmt.aprintf("%s/db", dir)
	defer delete(dbdir)

	keys := gen_db_keys(500, {5})
	defer {
		for k in keys {delete(k)}
		delete(keys)
	}

	// Generation 1: committed.
	db, err := munin.db_create(dbdir, TEST_CFG)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	ingest_all(t, db, keys)
	testing.expect_value(t, munin.db_commit(db), nil)
	munin.db_close(db)

	// Simulate a crashed generation 2: copy MANIFEST to MANIFEST.tmp (a
	// stand-in for a newer uncommitted generation) and drop an orphan run
	// file that generation 2 would have written.
	man, rerr := os.read_entire_file(fmt.tprintf("%s/MANIFEST", dbdir), context.allocator)
	testing.expect_value(t, rerr, nil)
	defer delete(man)
	tmp_path := fmt.aprintf("%s/MANIFEST.tmp", dbdir)
	defer delete(tmp_path)
	testing.expect_value(t, os.write_entire_file(tmp_path, man), nil)

	orphan_path := fmt.aprintf("%s/deadbeef.run", dbdir)
	defer delete(orphan_path)
	testing.expect_value(t, os.write_entire_file(orphan_path, []byte{1, 2, 3, 4}), nil)

	db2, oerr := munin.db_open(dbdir)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	verify_db(t, db2, keys)
	munin.db_close(db2)

	// Both artifacts must be gone.
	_, terr := os.stat(tmp_path, context.temp_allocator)
	testing.expect(t, terr != nil, "MANIFEST.tmp must be discarded")
	_, oterr := os.stat(orphan_path, context.temp_allocator)
	testing.expect(t, oterr != nil, "orphan run must be deleted")
}

// A run file referenced by the manifest but truncated on disk is
// Corruption, never a silent partial read.
@(test)
test_db_truncated_run_detected :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_db_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	dbdir := fmt.aprintf("%s/db", dir)
	defer delete(dbdir)

	keys := gen_db_keys(500, {5})
	defer {
		for k in keys {delete(k)}
		delete(keys)
	}

	db, err := munin.db_create(dbdir, TEST_CFG)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	ingest_all(t, db, keys)
	testing.expect_value(t, munin.db_commit(db), nil)
	munin.db_close(db)

	// Truncate the run file. Runs open lazily, so db_open succeeds and the
	// damage surfaces — as Corruption, never silent data — on first use.
	run_path := fmt.aprintf("%s/00000001.run", dbdir)
	defer delete(run_path)
	data, rerr := os.read_entire_file(run_path, context.allocator)
	testing.expect_value(t, rerr, nil)
	defer delete(data)
	testing.expect_value(t, os.write_entire_file(run_path, data[:len(data) / 2]), nil)

	db2, oerr := munin.db_open(dbdir)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	_, _, gerr := munin.db_get(db2, keys[0])
	testing.expect_value(t, gerr, munin.Error(munin.Corruption.Size_Mismatch))
	munin.db_close(db2)

	// Delete it entirely: missing file, surfaced on first use.
	testing.expect_value(t, os.remove(run_path), nil)
	db3, oerr3 := munin.db_open(dbdir)
	testing.expect_value(t, oerr3, nil)
	if oerr3 != nil {return}
	_, _, gerr3 := munin.db_get(db3, keys[0])
	testing.expect(t, gerr3 != nil, "missing run must surface as an error on use")
	munin.db_close(db3)
}

// Multiple commits accumulate runs in the same bucket; reads merge them.
@(test)
test_db_multi_generation :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_db_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	dbdir := fmt.aprintf("%s/db", dir)
	defer delete(dbdir)

	all := gen_db_keys(2000, {11})
	defer {
		for k in all {delete(k)}
		delete(all)
	}
	// Interleaved split: even indices in gen 1, odd in gen 2.
	gen1 := make([dynamic][]byte)
	gen2 := make([dynamic][]byte)
	defer {delete(gen1); delete(gen2)}
	for k, i in all {
		if i % 2 == 0 {append(&gen1, k)} else {append(&gen2, k)}
	}

	db, err := munin.db_create(dbdir, TEST_CFG)
	testing.expect_value(t, err, nil)
	if err != nil {return}

	ingest_all(t, db, gen1[:])
	testing.expect_value(t, munin.db_commit(db), nil)
	ingest_all(t, db, gen2[:])
	testing.expect_value(t, munin.db_commit(db), nil)

	verify_db(t, db, all)
	munin.db_close(db)

	db2, oerr := munin.db_open(dbdir)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	verify_db(t, db2, all)
	munin.db_close(db2)
}
