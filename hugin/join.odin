package hugin

// Phase 2, per join bucket: the sort-merge join for spend resolution, plus
// two jobs that fall out of it for free once both sides are sorted here:
//
//   - every funding-side row becomes a history FUNDING row (funding rows
//     are not scattered separately in phase 1 — this halves an entire
//     keyspace of spill), and
//   - the sorted spend-side rows ARE the spends keyspace rows, in ingest
//     order, so they go straight into the spends database with no third
//     copy on disk.
//
// An unmatched spend row is an input referencing an unknown output —
// impossible on a valid chain. That fails the build loudly.

import "core:log"

import munin "../munin"

// join_bucket runs the join for one bucket. History rows (funding and
// spend) go out through the caller's worker scatter; sorted spend rows are
// ingested into db_spends.
join_bucket :: proc(
	joinf: ^Scatter,
	joins: ^Scatter,
	bucket: int,
	out: ^Worker_Scatter,
	bucket_bits: u32,
	db_spends: ^munin.Db,
	compact: bool,
	allocator := context.allocator,
) -> (
	funding_rows: int,
	spend_rows: int,
	err: Error,
) {
	f_data := scatter_read_bucket(joinf, bucket, allocator) or_return
	defer delete(f_data, allocator)
	s_data := scatter_read_bucket(joins, bucket, allocator) or_return
	defer delete(s_data, allocator)

	// Both sides are in memory now; free their disk immediately so this
	// phase's own output reuses the space.
	scatter_delete_bucket(joinf, bucket)
	scatter_delete_bucket(joins, bucket)

	if len(f_data) % JOINF_ROW_SIZE != 0 || len(s_data) % JOINS_ROW_SIZE != 0 {
		return 0, 0, Corruption.Bad_Record
	}
	nf := len(f_data) / JOINF_ROW_SIZE
	ns := len(s_data) / JOINS_ROW_SIZE
	if nf == 0 && ns == 0 {
		return 0, 0, nil
	}
	if nf == 0 {
		// Spends with no funding side at all in this bucket.
		log_unknown_outpoint(s_data[:JOIN_KEY_LEN])
		return 0, 0, Corruption.Unknown_Outpoint
	}

	scratch_f := make([]byte, len(f_data), allocator)
	defer delete(scratch_f, allocator)
	radix_sort_rows(f_data, JOINF_ROW_SIZE, JOIN_KEY_LEN, scratch_f)

	scratch_s := make([]byte, len(s_data), allocator)
	defer delete(scratch_s, allocator)
	radix_sort_rows(s_data, JOINS_ROW_SIZE, JOIN_KEY_LEN, scratch_s)

	// --- history funding rows, one per funding-side row -------------------
	row: [HISTORY_ROW_SIZE]byte
	for fi in 0 ..< nf {
		frow := f_data[fi * JOINF_ROW_SIZE:]
		sh: [32]u8
		copy(sh[:], frow[36:68])
		history_row_encode(
			row[:],
			sh,
			get_u32be(frow[76:80]), // height
			get_u32be(frow[80:84]), // txnum
			DIRECTION_FUNDING,
			get_u32be(frow[32:36]), // vout, from the outpoint key
			get_u64le(frow[68:76]), // amount
		)
		worker_scatter_add(out, key_bucket(row[:], bucket_bits), row[:]) or_return
		funding_rows += 1
	}

	// --- merge join: spend side against funding side ----------------------
	// Double-spend detection rides along here: rows are sorted, so an
	// outpoint spent twice is two adjacent equal keys. Checking during
	// this pass costs nothing; a separate pass over billions of rows is
	// an extra traversal of the whole spend side.
	fi := 0
	for si in 0 ..< ns {
		srow := s_data[si * JOINS_ROW_SIZE:]
		s_out := srow[:JOIN_KEY_LEN]

		if si > 0 && outpoint_compare(s_data[(si - 1) * JOINS_ROW_SIZE:][:JOIN_KEY_LEN], s_out) == 0 {
			// The same outpoint spent twice: a valid chain cannot.
			log_unknown_outpoint(s_out)
			return funding_rows, spend_rows, Corruption.Bad_Record
		}

		// Advance the funding cursor to the first row >= this outpoint.
		for fi < nf {
			frow := f_data[fi * JOINF_ROW_SIZE:]
			c := outpoint_compare(frow[:JOIN_KEY_LEN], s_out)
			if c < 0 {
				fi += 1
				continue
			}
			break
		}
		if fi >= nf {
			log_unknown_outpoint(s_out)
			return funding_rows, spend_rows, Corruption.Unknown_Outpoint
		}
		frow := f_data[fi * JOINF_ROW_SIZE:]
		if outpoint_compare(frow[:JOIN_KEY_LEN], s_out) != 0 {
			log_unknown_outpoint(s_out)
			return funding_rows, spend_rows, Corruption.Unknown_Outpoint
		}

		// BIP-30 note: duplicate funding rows for one outpoint (the twin
		// coinbases) differ only in height/txnum; scripthash and amount —
		// the fields the spend row takes — are identical, so matching the
		// first is correct.

		sh: [32]u8
		copy(sh[:], frow[36:68])
		amount := get_u64le(frow[68:76])
		height := get_u32be(srow[36:])
		txnum := get_u32be(srow[40:])
		vin := get_u32be(srow[44:])

		history_row_encode(row[:], sh, height, txnum, DIRECTION_SPEND, vin, amount)
		worker_scatter_add(out, key_bucket(row[:], bucket_bits), row[:]) or_return
		spend_rows += 1
	}

	// --- spends keyspace: the sorted spend rows, ingested directly --------
	if ns > 0 {
		// (Double spends were already rejected during the merge above.)
		if compact {
			cerr := compact_ingest(db_spends, u32(bucket), s_data[:ns * JOINS_ROW_SIZE], .Spends)
			if cerr != nil {
				return funding_rows, spend_rows, cerr
			}
		} else {
			ing := munin.ingest_begin(db_spends, u32(bucket)) or_return
			for si in 0 ..< ns {
				srow := s_data[si * JOINS_ROW_SIZE:(si + 1) * JOINS_ROW_SIZE]
				munin.ingest_add(ing, srow[:JOIN_KEY_LEN], srow[JOIN_KEY_LEN:]) or_return
			}
			_, ferr := munin.ingest_finish(ing)
			if ferr != nil {
				return funding_rows, spend_rows, ferr
			}
		}
	}
	return funding_rows, spend_rows, nil
}

// The merge join calls this billions of times, and its two hottest uses
// compare keys that are EQUAL or share long prefixes (verifying a match,
// and checking adjacent sorted rows) — the worst case for a byte-at-a-time
// loop. Keys are 32-byte txid + 4-byte big-endian vout, so comparing
// big-endian integer chunks gives an identical ordering in a fifth of the
// operations.
outpoint_compare :: proc "contextless" (a, b: []byte) -> int {
	#no_bounds_check {
		for off := 0; off + 8 <= 32; off += 8 {
			x := get_u64be(a[off:])
			y := get_u64be(b[off:])
			if x != y {
				return -1 if x < y else 1
			}
		}
		x := get_u32be(a[32:])
		y := get_u32be(b[32:])
		if x != y {
			return -1 if x < y else 1
		}
	}
	return 0
}

@(private = "file")
log_unknown_outpoint :: proc(outpoint: []byte) {
	log.errorf(
		"hugin: spend of unknown outpoint %02x...:%d — input references an output that does not exist; the build is wrong, refusing to continue",
		outpoint[:8],
		get_u32be(outpoint[32:]),
	)
}
