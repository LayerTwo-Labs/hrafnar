# Munin — Development Specification

Storage engine. Sorted opaque byte keys, optional opaque values, immutable runs, merge-free
bulk ingest, prefix-oriented reads.

Shared conventions — Odin style, logging, error handling, durability ordering, and the layering
rule that keeps Bitcoin out of this package — are in the root `CLAUDE.md`. This document covers
the on-disk format, the API, and the build order.

All integers on disk are **little-endian** unless a field is explicitly marked big-endian.
Varints are LEB128 unsigned (`uvarint`).

## 0. What Munin is optimised for

Written once in bulk, read many times, appended to rarely.

- Ingest is **merge-free**. Callers hand Munin sorted, disjoint key ranges (buckets), and Munin
  writes them straight out as finished immutable runs. There is no external merge sort pass in
  the write path.
- Reads are dominated by **prefix seek then scan forward**.
- There is no MVCC, no sequence numbers, no transactions, no snapshots. Rows are unique by
  construction and never overwritten.

---

## 1. Concepts

**Key.** Opaque `[]byte`. Ordered by unsigned lexicographic comparison (`bytes.compare`).

**Bucket.** A static partition of the keyspace. A database is configured at creation with
`bucket_bits` (default 12 → 4096 buckets). A key's bucket is the top `bucket_bits` bits of the
key, read big-endian from byte 0. Buckets are disjoint and ordered: bucket *i* contains all
keys whose prefix falls in its range, and every key in bucket *i* sorts before every key in
bucket *i+1*.

This is the property that makes ingest merge-free. If the caller feeds sorted rows into the
correct bucket, then concatenating buckets in order yields a globally sorted index without ever
running a merge pass over the whole dataset.

Keys shorter than `bucket_bits/8` bytes are rejected with `Usage_Error`. The caller's key
schema must guarantee a minimum length.

**Run.** One immutable file containing a sorted, disjoint set of keys, all within one bucket.
A bucket holds one or more runs. In a bulk-built database each bucket holds exactly one run and
no compaction is ever needed.

**Level.** Runs within a bucket carry a level number. Level 0 runs may overlap each other;
level ≥ 1 runs within a bucket are disjoint. Phase 1 only ever produces level 0, one run per
bucket. Levels exist in the manifest from day one so that phase 2 does not require a format
change.

---

## 2. Run file format

File extension `.run`. Filename is `{run_id:08x}.run` in the database directory.

```
+-------------------------+
| data block 0            |
| data block 1            |
| ...                     |
| data block N-1          |
+-------------------------+
| filter block            |   optional
+-------------------------+
| index block             |
+-------------------------+
| footer (64 bytes)       |
+-------------------------+
```

### 2.1 Block trailer

Every block — data, filter, and index — is followed by a 5-byte trailer:

| offset | size | field                                            |
|--------|------|--------------------------------------------------|
| 0      | 1    | compression type: `0` none, `1` zstd, `2` lz4    |
| 1      | 4    | CRC32C of the block payload **and** the type byte |

Block offsets and lengths recorded elsewhere refer to the payload only, excluding the trailer.
A reader always reads `length + 5` bytes.

**On compression:** implement type `0` first and measure before adding anything else. Keys in
the target workload are largely hash bytes, which are incompressible by definition; the win is
confined to the low-entropy suffix, and every compressed block costs a decompress on each cache
miss. Do not bind zstd until a measurement justifies it.

### 2.2 Data block

Default target size 4096 bytes; a block is closed once adding another entry would exceed it. A
single entry larger than the target gets its own oversized block.

Entries use prefix compression against the preceding key, reset every `restart_interval`
entries (default 16).

Entry encoding:

| field          | encoding | notes                                        |
|----------------|----------|----------------------------------------------|
| `shared_len`   | uvarint  | bytes shared with previous key; `0` at a restart |
| `unshared_len` | uvarint  | remaining key bytes stored inline             |
| `value_len`    | uvarint  | **omitted entirely if the run is key-only**   |
| key suffix     | raw      | `unshared_len` bytes                          |
| value          | raw      | `value_len` bytes; omitted if key-only        |

Block payload trailer, after the last entry:

| field           | encoding        |
|-----------------|-----------------|
| restart offsets | `u32` × R, byte offsets from block start |
| `restart_count` | `u32` R         |

Reading `restart_count` from the last 4 bytes of the payload gives R, and thus where the entry
region ends.

Seeking within a block: binary search the restart array comparing full keys at restart points
(a restart entry has `shared_len == 0`, so its key is complete), then scan forward from the
chosen restart, reconstructing keys.

**Key-only runs.** Set by a footer flag. Omitting `value_len` saves one byte per entry, which
on a billion-row index is a gigabyte. Hugin's history keyspace is not key-only (it carries an
8-byte amount) but its spend keyspace may be.

### 2.3 Index block

One entry per data block, sorted by key. Same encoding as a data block, where:

- key = a **separator**: the shortest byte string that is ≥ the block's last key and < the next
  block's first key. Computing the shortest separator rather than storing the full last key
  materially shrinks the index for long keys with common prefixes.
- value = `block_offset` uvarint, `block_length` uvarint.

The whole index block is read and held in memory for the lifetime of an open run.

### 2.4 Filter block

One bloom filter per run, built over a **key prefix**, not the whole key.

This is the single most important read optimisation and the easiest to get wrong. The workload
is `seek(prefix)` then scan — a full-key filter cannot answer "does this run contain anything
starting with P" and is therefore useless for a range scan. Filter the prefix.

| offset | size | field                                          |
|--------|------|------------------------------------------------|
| 0      | 4    | `prefix_len` — bytes of key hashed (`0` = whole key) |
| 4      | 4    | `num_probes`                                   |
| 8      | 4    | `num_bits`                                     |
| 12     | ...  | bit array, `ceil(num_bits/8)` bytes            |

Hash: XXH64 of the prefix, split into two 32-bit halves for double hashing
(`h_i = h1 + i*h2`). Default 10 bits per key → ~1% false positive rate at 7 probes; expose
`bits_per_key` in the config.

`prefix_len` is set per keyspace by the caller at database creation and stored in the manifest.
For Hugin's history keyspace it is 32 (the full scripthash), so a scan for one address touches
only the runs that can contain it.

### 2.5 Footer

Fixed 64 bytes at end of file. Read by seeking to `file_size - 64`.

| offset | size | field                                                       |
|--------|------|-------------------------------------------------------------|
| 0      | 8    | magic `0x4D554E494E52554E` ("MUNINRUN" big-endian read)      |
| 8      | 4    | `format_version` (currently `1`)                             |
| 12     | 4    | `flags` — bit 0 key-only, bit 1 has-filter, bits 2+ reserved |
| 16     | 8    | `index_offset`                                               |
| 24     | 8    | `index_length`                                               |
| 32     | 8    | `filter_offset` (0 if absent)                                |
| 40     | 8    | `filter_length` (0 if absent)                                |
| 48     | 8    | `entry_count`                                                |
| 56     | 4    | CRC32C of footer bytes 0..55                                 |
| 60     | 4    | reserved, must be zero                                       |

A footer with the wrong magic, a failed checksum, or a `format_version` greater than the
reader's is a hard `Corruption` error. Never attempt a best-effort read of an unknown version.

---

## 3. Manifest

One file, `MANIFEST`, in the database directory.

```
header:
  magic u64 0x4D554E494E4D414E   ("MUNINMAN")
  format_version u32
  bucket_bits u32
  key_only u8, has_filter u8, prefix_len u16
  bits_per_key u32
  run_count u32
  next_run_id u64
  crc32c u32                     (over header bytes preceding this field)

then run_count records of:
  run_id u64
  bucket u32
  level u32
  entry_count u64
  file_size u64
  min_key_len u16, max_key_len u16
  min_key bytes, max_key bytes
  crc32c u32                     (over this record)
```

### 3.1 Update protocol

Non-negotiable ordering:

1. Write the complete new manifest to `MANIFEST.tmp`.
2. `fsync` `MANIFEST.tmp`.
3. `rename` `MANIFEST.tmp` → `MANIFEST`.
4. `fsync` the containing **directory**.

Step 4 is the one people skip. Without it the rename may not be durable and a crash can leave
a database whose manifest points at a previous generation while newly written run files are
already on disk. Those orphan runs are then invisible — recoverable, but only by a scan.

Rewriting the whole manifest on every update is fine at this scale: 4096 buckets with one run
each is a few hundred kilobytes, and updates happen at most once per block. Do not build an
incremental edit log until profiling says otherwise.

### 3.2 Recovery

On open: read `MANIFEST`, verify checksums, `stat` every referenced run file and confirm the
size matches. Any `.run` file present in the directory but absent from the manifest is an
orphan from an interrupted write — log it at warn level and delete it. Any run file referenced
but missing or the wrong size is `Corruption`.

If `MANIFEST` is missing but `MANIFEST.tmp` exists, the crash happened before the rename: the
tmp file is a complete but uncommitted generation. Discard it. Never promote it — that would
adopt a state the caller was never told had committed.

---

## 4. Public API

Phase 1 surface. Keep it this small.

```odin
package munin

Config :: struct {
    bucket_bits:     u32,     // default 12
    block_size:      int,     // default 4096
    restart_interval: int,    // default 16
    key_only:        bool,
    filter_prefix_len: int,   // 0 disables the filter
    filter_bits_per_key: int, // default 10
    cache_bytes:     int,     // default 256 << 20
}

Db :: struct { /* opaque */ }

db_create :: proc(dir: string, cfg: Config, allocator := context.allocator) -> (db: ^Db, err: Error)
db_open   :: proc(dir: string, allocator := context.allocator) -> (db: ^Db, err: Error)
db_close  :: proc(db: ^Db)

// --- bulk ingest -----------------------------------------------------------
// The caller supplies keys already sorted and already routed to the right
// bucket. Munin verifies both and returns Usage_Error on violation.

Ingest :: struct { /* opaque */ }

ingest_begin  :: proc(db: ^Db, bucket: u32) -> (ing: ^Ingest, err: Error)
ingest_add    :: proc(ing: ^Ingest, key, value: []byte) -> Error
ingest_finish :: proc(ing: ^Ingest) -> (run_id: u64, err: Error)
ingest_abort  :: proc(ing: ^Ingest)

// Multiple Ingest handles for *different* buckets may be live on different
// threads simultaneously. Two handles for the same bucket is Usage_Error.
// Nothing is visible to readers until db_commit.

db_commit :: proc(db: ^Db) -> Error   // rewrites the manifest, fsyncs, publishes

// --- read ------------------------------------------------------------------

db_get :: proc(db: ^Db, key: []byte, allocator := context.allocator) -> (value: []byte, found: bool, err: Error)

Iter :: struct { /* opaque */ }

iter_make  :: proc(db: ^Db, allocator := context.allocator) -> ^Iter
iter_seek  :: proc(it: ^Iter, key: []byte) -> Error   // first key >= key
iter_next  :: proc(it: ^Iter) -> Error
iter_valid :: proc(it: ^Iter) -> bool
iter_key   :: proc(it: ^Iter) -> []byte   // borrowed, invalid after iter_next
iter_value :: proc(it: ^Iter) -> []byte   // borrowed, invalid after iter_next
iter_close :: proc(it: ^Iter)

// --- external iterators ----------------------------------------------------
// Munin owns merging, not the caller's semantics. A caller with its own
// in-memory sorted data (Hugin's recent tier) supplies it as an iterator
// source and Munin folds it into the k-way merge.

Iter_Source :: struct {
    user:  rawptr,
    seek:  proc(user: rawptr, key: []byte),
    next:  proc(user: rawptr),
    valid: proc(user: rawptr) -> bool,
    key:   proc(user: rawptr) -> []byte,
    value: proc(user: rawptr) -> []byte,
}

iter_add_source :: proc(it: ^Iter, src: Iter_Source)
```

### 4.1 Iterator semantics

- Forward only in phase 1. Do not implement `iter_prev` until something demands it; reverse
  iteration over a merging heap is where LSM implementations get ugly, and the target workload
  scans one direction.
- `iter_key` and `iter_value` return slices **borrowed** from the block cache, valid only until
  the next `iter_next`/`iter_seek`/`iter_close`. Callers who need to retain them must copy.
  Document this at every call site; it is the most likely source of a use-after-free.
- Keys are unique across the whole database by construction. If the merge encounters two equal
  keys from different sources, that is a caller bug — return `Usage_Error` rather than silently
  picking one. Silently picking is how a wrong balance becomes undebuggable.
- Iterators pin the runs they reference. `db_commit` must not delete a file an open iterator
  holds; refcount runs and defer deletion of obsolete files until the count drops to zero.

### 4.2 Block cache

Sharded by `hash(run_id, block_offset) % shard_count`, 16 shards, each an independent LRU under
its own mutex. A single global lock becomes the bottleneck immediately with parallel readers.
Cache stores decompressed block payloads keyed by `(run_id, block_offset)`.

---

## 5. Phase 2 — mutation

Do not build any of this until Hugin actually needs incremental catch-up.

- `Mem_Table`: in-memory sorted table. A sorted vector with a merge-on-flush buffer is enough
  at the target write rate (thousands of rows per ten minutes); a skiplist is unnecessary
  complexity here.
- `db_put` / write-ahead log with per-record framing and CRC.
- `db_flush`: memtable → level 0 runs, partitioned by bucket.
- Compaction within a bucket: merge level 0 runs into level 1. Because keys are unique and
  never overwritten, this is a plain k-way merge — no tombstone handling, no version dropping.

The trigger to start phase 2 is Hugin's promotion path, where rows aging past the reorg horizon
move from the recent tier into the main body. Nothing before that needs it.

---

## 6. Build order

Each step is independently testable with synthetic data. Do not skip ahead.

1. **`varint.odin`, `crc.odin`.** Round-trip property tests. Verify CRC32C against known
   vectors before trusting it anywhere else.
2. **`block.odin`.** Encode a block from a sorted key list, decode it, assert round-trip.
   Property test: random keys with heavy shared prefixes, random restart intervals.
3. **`run_write.odin` + `run_read.odin`.** Write a run, reopen, seek to every key, seek to keys
   between existing keys, seek before the first and after the last. This milestone is where the
   format either works or does not.
4. **`filter.odin`.** Measure the actual false positive rate against the predicted rate on a
   million random prefixes. If they diverge, the hashing is wrong.
5. **`cache.odin`.** Correctness first, then confirm the sharding actually removes contention
   under a multithreaded read benchmark.
6. **`iter.odin`.** Merging iterator across N runs. Property test against a sorted reference of
   the union of all inputs.
7. **`manifest.odin` + `ingest.odin` + `db_*`.** The full bulk path. Fault-injection tests:
   kill between the tmp write and the rename, between the rename and the directory fsync, and
   mid-run-file-write. Assert the reopened database is either the old generation or the new
   one, never a mixture.
8. Only now hand it to Hugin.
