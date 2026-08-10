package hugin

// LSD radix sort over fixed-width rows. Rows are raw bytes, row_size each;
// ordering key is the first key_len bytes, unsigned lexicographic. Stable,
// no comparisons, two-buffer scatter.
//
// A pass whose byte is identical across all rows is skipped (heights and
// direction bytes are heavily skewed; scripthash bytes never skip).

// radix_sort_rows sorts rows in place. scratch must be the same length as
// rows. Both lengths must be a multiple of row_size.
radix_sort_rows :: proc(rows: []byte, row_size: int, key_len: int, scratch: []byte) {
	assert(len(rows) == len(scratch))
	assert(row_size > 0 && key_len > 0 && key_len <= row_size)
	assert(len(rows) % row_size == 0)
	n := len(rows) / row_size
	if n <= 1 {
		return
	}

	src := rows
	dst := scratch

	for b := key_len - 1; b >= 0; b -= 1 {
		count: [256]int
		for i in 0 ..< n {
			count[src[i * row_size + b]] += 1
		}
		if count[src[b]] == n {
			// Every row has the same byte here; the pass is a no-op.
			continue
		}
		// Prefix sums -> starting offsets.
		total := 0
		for &c in count {
			c, total = total, total + c
		}
		#no_bounds_check for i in 0 ..< n {
			v := src[i * row_size + b]
			j := count[v]
			count[v] = j + 1
			copy(dst[j * row_size:(j + 1) * row_size], src[i * row_size:(i + 1) * row_size])
		}
		src, dst = dst, src
	}

	if raw_data(src) != raw_data(rows) {
		copy(rows, src)
	}
}
