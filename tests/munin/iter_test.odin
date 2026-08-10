package munin_tests

import "core:bytes"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:testing"

import munin "../../munin"

// In-memory sorted source implementing Iter_Source, standing in for
// Hugin's recent tier.
Mem_Source :: struct {
	keys:   [][]byte, // sorted
	values: [][]byte,
	pos:    int,
}

@(private = "file")
mem_seek :: proc(user: rawptr, key: []byte) {
	s := cast(^Mem_Source)user
	s.pos = 0
	for s.pos < len(s.keys) && bytes.compare(s.keys[s.pos], key) < 0 {
		s.pos += 1
	}
}

@(private = "file")
mem_next :: proc(user: rawptr) {
	s := cast(^Mem_Source)user
	s.pos += 1
}

@(private = "file")
mem_valid :: proc(user: rawptr) -> bool {
	s := cast(^Mem_Source)user
	return s.pos < len(s.keys)
}

@(private = "file")
mem_key :: proc(user: rawptr) -> []byte {
	s := cast(^Mem_Source)user
	return s.keys[s.pos]
}

@(private = "file")
mem_value :: proc(user: rawptr) -> []byte {
	s := cast(^Mem_Source)user
	return s.values[s.pos]
}

@(private = "file")
mem_source_of :: proc(s: ^Mem_Source) -> munin.Iter_Source {
	return munin.Iter_Source {
		user  = s,
		seek  = mem_seek,
		next  = mem_next,
		valid = mem_valid,
		key   = mem_key,
		value = mem_value,
	}
}

// Build N runs from a shuffled split of a sorted unique key universe, merge
// them, and compare against the sorted reference.
@(test)
test_iter_merge_property :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	UNIVERSE :: 6000
	RUNS :: 5

	universe := gen_run_keys_unique(UNIVERSE)
	defer {
		for k in universe {delete(k)}
		delete(universe)
	}

	// Assign each key to one of RUNS sources (one stays in memory).
	assignment := make([]int, UNIVERSE)
	defer delete(assignment)
	for &a in assignment {a = rand.int_max(RUNS + 1)}
	// Guarantee every source is non-empty.
	for i in 0 ..< RUNS + 1 {assignment[i] = i}

	runs: [RUNS]^munin.Run
	for ri in 0 ..< RUNS {
		path := fmt.aprintf("%s/%08x.run", dir, ri + 1)
		defer delete(path)
		w: munin.Run_Writer
		testing.expect_value(t, munin.run_writer_begin(&w, path, {block_size = 512}), nil)
		for k, i in universe {
			if assignment[i] != ri {continue}
			testing.expect_value(t, munin.run_writer_add(&w, k, k), nil)
		}
		_, ferr := munin.run_writer_finish(&w)
		testing.expect_value(t, ferr, nil)
		munin.run_writer_destroy(&w)
		r, oerr := munin.run_open(path, u64(ri + 1))
		testing.expect_value(t, oerr, nil)
		runs[ri] = r
	}
	defer for r in runs {
		if r != nil {munin.run_close(r)}
	}

	mem: Mem_Source
	mem_keys := make([dynamic][]byte)
	defer delete(mem_keys)
	for k, i in universe {
		if assignment[i] == RUNS {
			append(&mem_keys, k)
		}
	}
	mem.keys = mem_keys[:]
	mem.values = mem_keys[:]

	it: munin.Iter
	munin.iter_init(&it)
	defer munin.iter_close(&it)
	for r in runs {
		if r != nil {munin.iter_add_run(&it, r)}
	}
	munin.iter_add_source(&it, mem_source_of(&mem))

	// Every key was assigned to exactly one source, so the merged scan must
	// equal the full sorted universe.
	included := universe

	testing.expect_value(t, munin.iter_seek(&it, []byte{}), nil)
	for k, i in included {
		testing.expectf(t, munin.iter_valid(&it), "merge died at %d (err=%v)", i, it.err)
		if !munin.iter_valid(&it) {return}
		testing.expectf(
			t,
			bytes.compare(munin.iter_key(&it), k) == 0,
			"merge[%d]: got % x want % x",
			i,
			munin.iter_key(&it),
			k,
		)
		testing.expect_value(t, munin.iter_next(&it), nil)
	}
	testing.expect(t, !munin.iter_valid(&it), "merge should be exhausted")

	// Random seeks land on the right key.
	for _ in 0 ..< 500 {
		i := rand.int_max(len(included))
		testing.expect_value(t, munin.iter_seek(&it, included[i]), nil)
		testing.expect(t, munin.iter_valid(&it), "seek invalid")
		testing.expect(t, bytes.compare(munin.iter_key(&it), included[i]) == 0, "seek wrong key")
	}
}

@(test)
test_iter_duplicate_key_detected :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "munin_test_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	// Two runs sharing one key.
	shared := []byte{5, 5, 5, 5}
	paths: [2]string
	runs: [2]^munin.Run
	for ri in 0 ..< 2 {
		paths[ri] = fmt.aprintf("%s/%08x.run", dir, ri + 1)
		w: munin.Run_Writer
		testing.expect_value(t, munin.run_writer_begin(&w, paths[ri], {}), nil)
		defer munin.run_writer_destroy(&w)
		testing.expect_value(t, munin.run_writer_add(&w, []byte{byte(ri), 0}, nil), nil)
		testing.expect_value(t, munin.run_writer_add(&w, shared, nil), nil)
		_, ferr := munin.run_writer_finish(&w)
		testing.expect_value(t, ferr, nil)
		r, oerr := munin.run_open(paths[ri], u64(ri + 1))
		testing.expect_value(t, oerr, nil)
		runs[ri] = r
	}
	defer for r in runs {munin.run_close(r)}
	defer for p in paths {delete(p)}

	it: munin.Iter
	munin.iter_init(&it)
	defer munin.iter_close(&it)
	munin.iter_add_run(&it, runs[0])
	munin.iter_add_run(&it, runs[1])

	testing.expect_value(t, munin.iter_seek(&it, []byte{}), nil)
	// Walk until the duplicate surfaces.
	err: munin.Error
	for munin.iter_valid(&it) {
		err = munin.iter_next(&it)
		if err != nil {break}
	}
	testing.expect_value(t, err, munin.Error(munin.Usage_Error.Duplicate_Key))
}

// Unique sorted fixed-width keys.
@(private = "file")
gen_run_keys_unique :: proc(n: int) -> [][]byte {
	seen := make(map[u32]struct {})
	defer delete(seen)
	vals := make([]u32, n)
	defer delete(vals)
	count := 0
	for count < n {
		v := rand.uint32()
		if v in seen {continue}
		seen[v] = {}
		vals[count] = v
		count += 1
	}
	slice.sort(vals)
	out := make([][]byte, n)
	for v, i in vals {
		k := make([]byte, 4)
		k[0] = byte(v >> 24)
		k[1] = byte(v >> 16)
		k[2] = byte(v >> 8)
		k[3] = byte(v)
		out[i] = k
	}
	return out
}
