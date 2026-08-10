package munin_tests

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"

import munin "../../munin"

// Iterating through a tiny cache (constant eviction) must return exactly
// the same data as iterating with no cache.
@(test)
test_cache_eviction_correctness :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	keys := gen_cache_keys(4000)
	defer {
		for k in keys {delete(k)}
		delete(keys)
	}

	path := fmt.aprintf("%s/00000001.run", dir)
	defer delete(path)
	w: munin.Run_Writer
	testing.expect_value(t, munin.run_writer_begin(&w, path, {block_size = 256}), nil)
	defer munin.run_writer_destroy(&w)
	for k in keys {
		testing.expect_value(t, munin.run_writer_add(&w, k, k), nil)
	}
	_, ferr := munin.run_writer_finish(&w)
	testing.expect_value(t, ferr, nil)

	cache: munin.Cache
	// ~4 blocks worth: forces constant eviction.
	munin.cache_init(&cache, 1024)
	defer munin.cache_destroy(&cache)

	r, oerr := munin.run_open(path, 1, &cache)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer munin.run_close(r)

	for round in 0 ..< 3 {
		it: munin.Run_Iter
		munin.run_iter_init(&it, r)
		defer munin.run_iter_destroy(&it)
		munin.run_iter_seek_first(&it)
		for k, i in keys {
			testing.expectf(t, munin.run_iter_valid(&it), "round %d died at %d (err=%v)", round, i, it.err)
			if !munin.run_iter_valid(&it) {return}
			testing.expectf(t, bytes.compare(munin.run_iter_key(&it), k) == 0, "round %d scan[%d] wrong key", round, i)
			testing.expectf(t, bytes.compare(munin.run_iter_value(&it), k) == 0, "round %d scan[%d] wrong value", round, i)
			munin.run_iter_next(&it)
		}
		testing.expect(t, !munin.run_iter_valid(&it))
	}
}

Cache_Worker :: struct {
	t:       ^testing.T,
	run:     ^munin.Run,
	keys:    [][]byte,
	rounds:  int,
	failures: ^int, // atomic
}

@(private = "file")
cache_worker_proc :: proc(w: ^Cache_Worker) {
	for _ in 0 ..< w.rounds {
		it: munin.Run_Iter
		munin.run_iter_init(&it, w.run)
		defer munin.run_iter_destroy(&it)

		// Interleave scans and seeks to stress hit/miss/evict paths.
		munin.run_iter_seek_first(&it)
		for k in w.keys {
			if !munin.run_iter_valid(&it) ||
			   bytes.compare(munin.run_iter_key(&it), k) != 0 ||
			   bytes.compare(munin.run_iter_value(&it), k) != 0 {
				sync.atomic_add(w.failures, 1)
				return
			}
			munin.run_iter_next(&it)
		}
		for i := len(w.keys) - 1; i >= 0; i -= 7 {
			munin.run_iter_seek(&it, w.keys[i])
			if !munin.run_iter_valid(&it) || bytes.compare(munin.run_iter_key(&it), w.keys[i]) != 0 {
				sync.atomic_add(w.failures, 1)
				return
			}
		}
	}
}

@(test)
test_cache_concurrent_readers :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	keys := gen_cache_keys(2000)
	defer {
		for k in keys {delete(k)}
		delete(keys)
	}

	path := fmt.aprintf("%s/00000002.run", dir)
	defer delete(path)
	w: munin.Run_Writer
	testing.expect_value(t, munin.run_writer_begin(&w, path, {block_size = 256}), nil)
	defer munin.run_writer_destroy(&w)
	for k in keys {
		testing.expect_value(t, munin.run_writer_add(&w, k, k), nil)
	}
	_, ferr := munin.run_writer_finish(&w)
	testing.expect_value(t, ferr, nil)

	cache: munin.Cache
	munin.cache_init(&cache, 8 * 1024) // small: heavy eviction under contention
	defer munin.cache_destroy(&cache)

	r, oerr := munin.run_open(path, 2, &cache)
	testing.expect_value(t, oerr, nil)
	if oerr != nil {return}
	defer munin.run_close(r)

	WORKERS :: 8
	failures: int
	workers: [WORKERS]Cache_Worker
	threads: [WORKERS]^thread.Thread
	for i in 0 ..< WORKERS {
		workers[i] = Cache_Worker {
			t        = t,
			run      = r,
			keys     = keys,
			rounds   = 5,
			failures = &failures,
		}
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], cache_worker_proc, context)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, failures, 0)
	log.infof("concurrent cache test done, %d workers", WORKERS)
}

@(private = "file")
gen_cache_keys :: proc(n: int) -> [][]byte {
	out := make([][]byte, n)
	for i in 0 ..< n {
		k := make([]byte, 10)
		k[0] = byte(i >> 24)
		k[1] = byte(i >> 16)
		k[2] = byte(i >> 8)
		k[3] = byte(i)
		for j in 4 ..< 10 {k[j] = byte(i * (j + 3))}
		out[i] = k
	}
	return out
}
