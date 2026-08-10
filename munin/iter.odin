package munin

// Merging iterator: a k-way min-heap over run iterators and external
// sources. Forward only. Keys are unique across the database by
// construction; two equal keys from different sources is a caller bug and
// surfaces as Usage_Error, never a silent pick.

import "base:runtime"
import "core:bytes"

// Iter_Source lets a caller with its own sorted data (Hugin's recent tier)
// plug into the merge. All procs must be non-nil.
Iter_Source :: struct {
	user:  rawptr,
	seek:  proc(user: rawptr, key: []byte),
	next:  proc(user: rawptr),
	valid: proc(user: rawptr) -> bool,
	key:   proc(user: rawptr) -> []byte,
	value: proc(user: rawptr) -> []byte,
}

@(private = "file")
Iter_Backend :: struct {
	run_it: ^Run_Iter, // nil for an external source
	ext:    Iter_Source,
}

Iter :: struct {
	backends:  [dynamic]Iter_Backend,
	heap:      [dynamic]int, // backend indices, min-heap by current key
	cur:       int, // backend index of the current entry, -1 when invalid
	cur_key:   [dynamic]byte, // copy of current key, for duplicate detection
	valid:     bool,
	err:       Error,
	db:        ^Db, // set when made through db_iter_make; used for unpinning
	allocator: runtime.Allocator,
}

iter_init :: proc(it: ^Iter, allocator := context.allocator) {
	it.backends = make([dynamic]Iter_Backend, allocator)
	it.heap = make([dynamic]int, allocator)
	it.cur_key = make([dynamic]byte, allocator)
	it.cur = -1
	it.valid = false
	it.err = nil
	it.db = nil
	it.allocator = allocator
}

// iter_add_run adds a run to the merge. The caller is responsible for
// keeping the run open for the iterator's lifetime (db_iter_make pins).
iter_add_run :: proc(it: ^Iter, r: ^Run) {
	rit := new(Run_Iter, it.allocator)
	run_iter_init(rit, r, it.allocator)
	append(&it.backends, Iter_Backend{run_it = rit})
}

iter_add_source :: proc(it: ^Iter, src: Iter_Source) {
	append(&it.backends, Iter_Backend{ext = src})
}

@(private = "file")
iter_destroy_backends :: proc(it: ^Iter) {
	for &b in it.backends {
		if b.run_it != nil {
			run_iter_destroy(b.run_it)
			free(b.run_it, it.allocator)
		}
	}
}

// iter_close releases everything. Safe on a zero-initialized iterator.
iter_close :: proc(it: ^Iter) {
	if it.db != nil {
		db_iter_closed(it.db, it)
		it.db = nil
	}
	iter_destroy_backends(it)
	delete(it.backends)
	delete(it.heap)
	delete(it.cur_key)
}

// ---------------------------------------------------------------------------
// Backend dispatch

@(private = "file")
backend_seek :: proc(b: ^Iter_Backend, key: []byte) -> Error {
	if b.run_it != nil {
		run_iter_seek(b.run_it, key)
		return b.run_it.err
	}
	b.ext.seek(b.ext.user, key)
	return nil
}

@(private = "file")
backend_next :: proc(b: ^Iter_Backend) -> Error {
	if b.run_it != nil {
		run_iter_next(b.run_it)
		return b.run_it.err
	}
	b.ext.next(b.ext.user)
	return nil
}

@(private = "file")
backend_valid :: proc(b: ^Iter_Backend) -> bool {
	if b.run_it != nil {
		return run_iter_valid(b.run_it)
	}
	return b.ext.valid(b.ext.user)
}

@(private = "file")
backend_key :: proc(b: ^Iter_Backend) -> []byte {
	if b.run_it != nil {
		return run_iter_key(b.run_it)
	}
	return b.ext.key(b.ext.user)
}

@(private = "file")
backend_value :: proc(b: ^Iter_Backend) -> []byte {
	if b.run_it != nil {
		return run_iter_value(b.run_it)
	}
	return b.ext.value(b.ext.user)
}

// ---------------------------------------------------------------------------
// Heap

@(private = "file")
heap_less :: proc(it: ^Iter, a, b: int) -> bool {
	c := bytes.compare(backend_key(&it.backends[a]), backend_key(&it.backends[b]))
	if c != 0 {return c < 0}
	return a < b
}

@(private = "file")
heap_sift_up :: proc(it: ^Iter, i: int) {
	i := i
	for i > 0 {
		parent := (i - 1) / 2
		if !heap_less(it, it.heap[i], it.heap[parent]) {break}
		it.heap[i], it.heap[parent] = it.heap[parent], it.heap[i]
		i = parent
	}
}

@(private = "file")
heap_sift_down :: proc(it: ^Iter, i: int) {
	i := i
	n := len(it.heap)
	for {
		smallest := i
		l := 2 * i + 1
		r := 2 * i + 2
		if l < n && heap_less(it, it.heap[l], it.heap[smallest]) {smallest = l}
		if r < n && heap_less(it, it.heap[r], it.heap[smallest]) {smallest = r}
		if smallest == i {break}
		it.heap[i], it.heap[smallest] = it.heap[smallest], it.heap[i]
		i = smallest
	}
}

// iter_settle establishes the current entry from the heap top, checking for
// cross-source duplicates against the key just consumed.
@(private = "file")
iter_settle :: proc(it: ^Iter, check_dup: bool) {
	if len(it.heap) == 0 {
		it.cur = -1
		it.valid = false
		return
	}
	it.cur = it.heap[0]
	key := backend_key(&it.backends[it.cur])
	if check_dup && bytes.compare(key, it.cur_key[:]) == 0 {
		it.cur = -1
		it.valid = false
		it.err = Usage_Error.Duplicate_Key
		return
	}
	resize(&it.cur_key, len(key))
	copy(it.cur_key[:], key)
	it.valid = true
}

// ---------------------------------------------------------------------------
// Public surface

// iter_seek positions on the first key >= key across all sources.
iter_seek :: proc(it: ^Iter, key: []byte) -> Error {
	it.err = nil
	it.valid = false
	clear(&it.heap)
	for &b, i in it.backends {
		backend_seek(&b, key) or_return
		if backend_valid(&b) {
			append(&it.heap, i)
		}
	}
	// Heapify.
	for i := len(it.heap) / 2 - 1; i >= 0; i -= 1 {
		heap_sift_down(it, i)
	}
	iter_settle(it, false)
	return it.err
}

iter_next :: proc(it: ^Iter) -> Error {
	if !it.valid {
		return Usage_Error.Iterator_Misuse
	}
	b := &it.backends[it.cur]
	backend_next(b) or_return
	if backend_valid(b) {
		heap_sift_down(it, 0)
	} else {
		// Drop the exhausted source: move the last heap slot to the root.
		last := len(it.heap) - 1
		it.heap[0] = it.heap[last]
		resize(&it.heap, last)
		if last > 0 {
			heap_sift_down(it, 0)
		}
	}
	iter_settle(it, true)
	return it.err
}

iter_valid :: proc(it: ^Iter) -> bool {
	return it.valid
}

// Borrowed from the winning source; invalid after the next
// iter_next/iter_seek/iter_close. Copy to retain.
iter_key :: proc(it: ^Iter) -> []byte {
	return backend_key(&it.backends[it.cur])
}

iter_value :: proc(it: ^Iter) -> []byte {
	return backend_value(&it.backends[it.cur])
}
