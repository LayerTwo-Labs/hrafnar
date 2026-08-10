package hugin

// Partitioned row spill buffers for the scatter phase.
//
// Each keyspace gets a Scatter over n_buckets spill files
// (work/{keyspace}/{bucket:04x}.part). Workers buffer rows privately and
// append chunks to the shared per-bucket file under a per-bucket mutex.
// Files are opened per append and closed again: 4096 buckets x 3 keyspaces
// would otherwise blow through file descriptor limits.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sync"

Scatter :: struct {
	dir:       string, // owned
	n_buckets: int,
	locks:     []sync.Mutex, // one per bucket
	rows:      []u64, // rows appended per bucket (atomic)
	allocator: runtime.Allocator,
}

scatter_init :: proc(
	s: ^Scatter,
	dir: string,
	n_buckets: int,
	allocator := context.allocator,
) -> (
	err: Error,
) {
	ensure_dir(dir) or_return
	perr: runtime.Allocator_Error
	s.dir, perr = clone_string(dir, allocator)
	if perr != nil {
		return os.Error(perr)
	}
	s.n_buckets = n_buckets
	s.locks = make([]sync.Mutex, n_buckets, allocator)
	s.rows = make([]u64, n_buckets, allocator)
	s.allocator = allocator
	return nil
}

scatter_destroy :: proc(s: ^Scatter) {
	delete(s.locks, s.allocator)
	delete(s.rows, s.allocator)
	delete(s.dir, s.allocator)
}

@(private = "file")
scatter_path :: proc(s: ^Scatter, bucket: int) -> string {
	return fmt.tprintf("%s/%04x.part", s.dir, bucket)
}

// scatter_append appends a chunk of rows to a bucket's spill file.
scatter_append :: proc(s: ^Scatter, bucket: int, data: []byte, row_count: int) -> (err: Error) {
	if len(data) == 0 {
		return nil
	}
	sync.mutex_lock(&s.locks[bucket])
	defer sync.mutex_unlock(&s.locks[bucket])

	f := os.open(
		scatter_path(s, bucket),
		{.Write, .Create, .Append},
		os.Permissions_Read_All + {.Write_User},
	) or_return
	werr := write_full(f, data)
	cerr := os.close(f)
	if werr != nil {
		return werr
	}
	if cerr != nil {
		return cerr
	}
	sync.atomic_add(&s.rows[bucket], u64(row_count))
	return nil
}

// scatter_read_bucket loads a bucket's spilled rows. A bucket nothing was
// written to reads as empty.
scatter_read_bucket :: proc(
	s: ^Scatter,
	bucket: int,
	allocator := context.allocator,
) -> (
	data: []byte,
	err: Error,
) {
	path := scatter_path(s, bucket)
	if _, serr := os.stat(path, context.temp_allocator); serr != nil {
		return nil, nil
	}
	rdata, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return nil, rerr
	}
	return rdata, nil
}

// scatter_delete_bucket removes one bucket's spill file once its rows have
// been consumed, so peak disk usage falls as the build progresses instead
// of persisting to the end.
scatter_delete_bucket :: proc(s: ^Scatter, bucket: int) {
	os.remove(scatter_path(s, bucket))
}

// scatter_remove_all deletes the keyspace's work directory.
scatter_remove_all :: proc(s: ^Scatter) {
	os.remove_all(s.dir)
}

// ---------------------------------------------------------------------------
// Per-worker buffered writer.

Worker_Scatter :: struct {
	s:        ^Scatter,
	row_size: int,
	bufs:     [][dynamic]byte,
	pending:  []int, // row count per buffer
	buffered: int, // total bytes buffered across buckets
	chunk:    int, // per-bucket spill threshold
	budget:   int, // total-buffered threshold: spill everything
	allocator: runtime.Allocator,
}

worker_scatter_init :: proc(
	w: ^Worker_Scatter,
	s: ^Scatter,
	row_size: int,
	chunk := 256 << 10,
	budget := 64 << 20,
	allocator := context.allocator,
) {
	w.s = s
	w.row_size = row_size
	w.bufs = make([][dynamic]byte, s.n_buckets, allocator)
	w.pending = make([]int, s.n_buckets, allocator)
	w.buffered = 0
	w.chunk = chunk
	w.budget = budget
	w.allocator = allocator
}

worker_scatter_destroy :: proc(w: ^Worker_Scatter) {
	for &b in w.bufs {
		delete(b)
	}
	delete(w.bufs, w.allocator)
	delete(w.pending, w.allocator)
}

// worker_scatter_add buffers one row, spilling the bucket when its buffer
// crosses the chunk size and everything when the worker's total crosses
// the budget.
worker_scatter_add :: proc(w: ^Worker_Scatter, bucket: int, row: []byte) -> (err: Error) {
	assert(len(row) == w.row_size)
	if w.bufs[bucket] == nil {
		w.bufs[bucket] = make([dynamic]byte, w.allocator)
	}
	append(&w.bufs[bucket], ..row)
	w.pending[bucket] += 1
	w.buffered += len(row)

	if len(w.bufs[bucket]) >= w.chunk {
		worker_scatter_spill(w, bucket) or_return
	}
	if w.buffered >= w.budget {
		worker_scatter_flush(w) or_return
	}
	return nil
}

@(private = "file")
worker_scatter_spill :: proc(w: ^Worker_Scatter, bucket: int) -> (err: Error) {
	if w.pending[bucket] == 0 {
		return nil
	}
	scatter_append(w.s, bucket, w.bufs[bucket][:], w.pending[bucket]) or_return
	w.buffered -= len(w.bufs[bucket])
	clear(&w.bufs[bucket])
	w.pending[bucket] = 0
	return nil
}

// worker_scatter_flush spills every buffered row. Must be called before
// the worker exits.
worker_scatter_flush :: proc(w: ^Worker_Scatter) -> (err: Error) {
	for bucket in 0 ..< w.s.n_buckets {
		worker_scatter_spill(w, bucket) or_return
	}
	return nil
}

@(private)
clone_string :: proc(
	s: string,
	allocator: runtime.Allocator,
) -> (
	out: string,
	err: runtime.Allocator_Error,
) {
	b := make([]byte, len(s), allocator) or_return
	copy(b, s)
	return string(b), nil
}
