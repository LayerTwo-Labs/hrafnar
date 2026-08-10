package hugin_tests

// Radix sort and scatter tests on synthetic rows.

import "core:bytes"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:testing"
import "core:thread"

import hugin "../../hugin"

// Rows shaped like history rows: 45-byte key + 8-byte value.
ROW_SIZE :: 53
KEY_LEN :: 45

@(private = "file")
gen_rows :: proc(n: int, skew: bool) -> []byte {
	rows := make([]byte, n * ROW_SIZE)
	for i in 0 ..< n {
		r := rows[i * ROW_SIZE:]
		if skew {
			// Skewed shape: shared scripthash prefix, low heights — the
			// pattern that makes byte-skipping worthwhile.
			for j in 0 ..< 8 {r[j] = 0xAB}
			for j in 8 ..< 32 {r[j] = byte(rand.int_max(4))}
			r[32] = 0
			r[33] = 0
			r[34] = byte(rand.int_max(16))
			r[35] = byte(rand.int_max(256))
		} else {
			for j in 0 ..< KEY_LEN {r[j] = byte(rand.int_max(256))}
		}
		for j in KEY_LEN ..< ROW_SIZE {r[j] = byte(rand.int_max(256))}
	}
	return rows
}

@(private = "file")
expect_sorted_equal :: proc(t: ^testing.T, got: []byte, reference: []byte) {
	n := len(reference) / ROW_SIZE
	// Reference: stable comparison sort over row slices.
	rows_ref := make([][]byte, n)
	defer delete(rows_ref)
	for i in 0 ..< n {
		rows_ref[i] = reference[i * ROW_SIZE:(i + 1) * ROW_SIZE]
	}
	slice.stable_sort_by(rows_ref, proc(a, b: []byte) -> bool {
		return bytes.compare(a[:KEY_LEN], b[:KEY_LEN]) < 0
	})
	for i in 0 ..< n {
		have := got[i * ROW_SIZE:(i + 1) * ROW_SIZE]
		if bytes.compare(rows_ref[i], have) != 0 {
			testing.expectf(t, false, "row %d differs", i)
			return
		}
	}
}

@(test)
test_radix_sort_random :: proc(t: ^testing.T) {
	for n in ([]int{0, 1, 2, 100, 5000}) {
		rows := gen_rows(n, false)
		defer delete(rows)
		original := make([]byte, len(rows))
		defer delete(original)
		copy(original, rows)
		scratch := make([]byte, len(rows))
		defer delete(scratch)

		hugin.radix_sort_rows(rows, ROW_SIZE, KEY_LEN, scratch)
		expect_sorted_equal(t, rows, original)
	}
}

@(test)
test_radix_sort_skewed :: proc(t: ^testing.T) {
	rows := gen_rows(3000, true)
	defer delete(rows)
	original := make([]byte, len(rows))
	defer delete(original)
	copy(original, rows)
	scratch := make([]byte, len(rows))
	defer delete(scratch)

	hugin.radix_sort_rows(rows, ROW_SIZE, KEY_LEN, scratch)
	expect_sorted_equal(t, rows, original)
}

@(test)
test_radix_sort_stability_via_value :: proc(t: ^testing.T) {
	// All-equal keys: values must keep their input order (stability).
	n := 500
	rows := make([]byte, n * ROW_SIZE)
	defer delete(rows)
	for i in 0 ..< n {
		r := rows[i * ROW_SIZE:]
		for j in 0 ..< KEY_LEN {r[j] = 0x42}
		r[KEY_LEN] = byte(i)
		r[KEY_LEN + 1] = byte(i >> 8)
	}
	scratch := make([]byte, len(rows))
	defer delete(scratch)
	hugin.radix_sort_rows(rows, ROW_SIZE, KEY_LEN, scratch)
	for i in 0 ..< n {
		r := rows[i * ROW_SIZE:]
		got := int(r[KEY_LEN]) | int(r[KEY_LEN + 1]) << 8
		testing.expect_value(t, got, i)
	}
}

Scatter_Test_Worker :: struct {
	ws:     hugin.Worker_Scatter,
	base:   int,
	count:  int,
	failed: bool,
}

@(private = "file")
scatter_worker_proc :: proc(w: ^Scatter_Test_Worker) {
	row: [16]byte
	for i in 0 ..< w.count {
		v := u32(w.base + i)
		bucket := int(v) % 16
		row[0] = byte(v >> 24)
		row[1] = byte(v >> 16)
		row[2] = byte(v >> 8)
		row[3] = byte(v)
		for j in 4 ..< 16 {row[j] = byte(v * u32(j))}
		if hugin.worker_scatter_add(&w.ws, bucket, row[:]) != nil {
			w.failed = true
			return
		}
	}
	if hugin.worker_scatter_flush(&w.ws) != nil {
		w.failed = true
	}
}

@(test)
test_scatter_concurrent :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hugin_scatter_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}

	work := fmt.aprintf("%s/join", dir)
	defer delete(work)

	s: hugin.Scatter
	testing.expect_value(t, hugin.scatter_init(&s, work, 16), nil)
	defer hugin.scatter_destroy(&s)

	WORKERS :: 4
	PER_WORKER :: 10_000
	workers: [WORKERS]Scatter_Test_Worker
	threads: [WORKERS]^thread.Thread
	for i in 0 ..< WORKERS {
		// Tiny chunk size to force many concurrent spills.
		hugin.worker_scatter_init(&workers[i].ws, &s, 16, 1 << 10, 1 << 20)
		workers[i].base = i * PER_WORKER
		workers[i].count = PER_WORKER
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], scatter_worker_proc, context)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for &w in workers {
		testing.expect(t, !w.failed, "worker failed")
		hugin.worker_scatter_destroy(&w.ws)
	}

	// Read every bucket back; each value must appear exactly once and in
	// its correct bucket.
	seen := make([]bool, WORKERS * PER_WORKER)
	defer delete(seen)
	total := 0
	for bucket in 0 ..< 16 {
		data, rerr := hugin.scatter_read_bucket(&s, bucket)
		testing.expect_value(t, rerr, nil)
		defer delete(data)
		testing.expect_value(t, len(data) % 16, 0)
		n := len(data) / 16
		testing.expect_value(t, u64(n), s.rows[bucket])
		for i in 0 ..< n {
			r := data[i * 16:]
			v := u32(r[0]) << 24 | u32(r[1]) << 16 | u32(r[2]) << 8 | u32(r[3])
			testing.expect_value(t, int(v) % 16, bucket)
			testing.expect(t, !seen[v], "duplicate row")
			seen[v] = true
			for j in 4 ..< 16 {
				testing.expect_value(t, r[j], byte(v * u32(j)))
			}
			total += 1
		}
	}
	testing.expect_value(t, total, WORKERS * PER_WORKER)
}
