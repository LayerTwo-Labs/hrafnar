# Hugin — Development Specification

Bitcoin block indexer over Munin. Reads `blk*.dat` directly, builds an address index in a
merge-free parallel pipeline, answers balance and history queries, handles reorgs.

Shared conventions — Odin style, logging, error handling, durability ordering, the layering rule
— are in the root `CLAUDE.md`. This document covers the `.dat` reader, the row schemas, the
build pipeline, and the reorg design.

All Bitcoin-internal values keep their native encoding (little-endian, hashes stored in internal
byte order). Index key fields are **big-endian** so that lexicographic byte order matches
numeric order.

## 0. Performance rules

These are where the sync time comes from. Violating one is a design regression, not a missed
micro-optimisation.

1. **mmap the `.dat` files; never copy block bytes.** Rows reference slices into the mapping.
2. **Never build a transaction struct.** Walk the bytes, emit rows, retain nothing. A general
   `Transaction` type with allocated input and output slices costs more than the parse does.
3. **Arena per worker, reset per block.** Zero allocation in the hot loop.
4. **Partition rows into buckets at emission time; never run a global merge sort.** The largest
   single win in the design — it turns a multi-pass external sort over ~200GB of rows into one
   scatter-write plus in-memory per-bucket sorts.
5. **Radix sort, not comparison sort.** Rows are fixed-width byte keys.
6. **Overlap I/O with compute.** While a worker parses file N, reads for N+1 should be in flight.
7. **Check for SHA-NI at startup and log which path was taken.** Without it, double-SHA256 for
   txids is 3–5× slower and becomes a visible fraction of total runtime.

## 0.1 Edge cases that silently produce wrong answers

- **BIP-30.** Heights 91722 and 91880 contain coinbase transactions with txids identical to
  those at 91812 and 91842. A txid → location index must decide and document which wins.
- **Huge blocks.** Blocks with tens of thousands of outputs exist; anything with a fixed
  per-block buffer breaks on them.
- **Non-standard scriptPubKeys** classify to no address type. Index them by scripthash anyway —
  scripthash is defined over raw script bytes and needs no recognisable address.
- **Large `OP_RETURN` outputs** are unspendable but still real outputs.
- **The live tail.** The highest-numbered `blk` file may be growing under an active Core; pruned
  nodes have gaps in the numbering. Handle both rather than assuming a clean set.

---

## 1. Reading `blk*.dat`

### 1.1 File format

A `blk*.dat` file is a bare concatenation of:

| field       | size | notes                                     |
|-------------|------|-------------------------------------------|
| magic       | 4    | mainnet `F9BEB4D9`; testnet/signet differ  |
| block size  | 4    | u32 LE, byte length of the block that follows |
| block bytes | var  | header (80 bytes) + varint tx count + txs  |

Framing rules that matter:

- Records are **not** in chain order. They are in the order Core received them, and orphaned
  blocks are interleaved with main-chain blocks.
- Trailing zero bytes after the last record are normal. A zero magic means end of useful data
  in that file, not corruption.
- The highest-numbered file may be growing while Hugin reads it. Capture `stat` size once at
  open and never read past it.
- Pruned data directories have gaps in the numbering. Enumerate what exists rather than
  counting from zero.

### 1.2 Access

`mmap` each file read-only, `madvise(SEQUENTIAL)`. Every row Hugin emits references a slice into
the mapping; block bytes are never copied. Mappings stay live for the duration of a phase.

---

## 2. Phase 0 — header chain reconstruction

Single pass over every `blk*.dat`, parsing **only** the 80-byte headers and the record framing.
This is I/O-bound and fast: it touches ~80 bytes plus a seek per block.

For each record, record:

```odin
Header_Entry :: struct {
    hash:      [32]u8,
    prev:      [32]u8,
    raw:       [80]u8,
    file_no:   u16,
    offset:    u32,   // byte offset of the block payload within the file
    length:    u32,
}
```

Then:

1. Build a map `hash → Header_Entry`.
2. Compute cumulative work for every entry by walking back to genesis, memoising. Work per
   header is `2^256 / (target + 1)` derived from the compact `nBits` field; accumulate as `u128`
   (chain work is far below `2^128` and will remain so).
3. Select the tip with the greatest cumulative work.
4. Walk back from that tip to genesis via `prev`, producing the ordered main chain. Everything
   not on that path is an orphan and is never indexed.

This is chain **selection**, not reorg handling. During a bulk build there is no reorg — the
files already contain the answer.

### 2.1 `headers.dat`

Persist the selected chain as a flat array of fixed 128-byte records, indexed directly by
height. No Munin involvement; this store needs random update by height and is small
(~110MB at present heights).

| offset | size | field                        |
|--------|------|------------------------------|
| 0      | 32   | block hash                   |
| 32     | 80   | raw header                   |
| 112    | 2    | `file_no`                    |
| 114    | 4    | `offset`                     |
| 118    | 4    | `length`                     |
| 122    | 4    | `tx_count`                   |
| 126    | 2    | reserved                     |

A separate 32-byte `CHECKPOINT` file holds `(height u32, block_hash [32]u8, crc32c u32)`,
written with the same tmp-fsync-rename-fsync-dir protocol Munin uses for its manifest.

---

## 3. Row schemas

Three Munin databases in separate directories. Not column families — separate instances, with
independent key widths, filter configs, and recovery. Roughly a tenth of the code.

### 3.1 `history/` — the main index

Answers "everything that ever touched this address."

**Key, 45 bytes fixed:**

| offset | size | field       | encoding                          |
|--------|------|-------------|-----------------------------------|
| 0      | 32   | scripthash  | SHA256 of the raw scriptPubKey    |
| 32     | 4    | height      | u32 **big-endian**                |
| 36     | 4    | txnum       | u32 BE, index of tx within block  |
| 40     | 1    | direction   | `0` = funding (output), `1` = spend (input) |
| 41     | 4    | io_index    | u32 BE, vout or vin index         |

**Value, 8 bytes:** amount in satoshis, `u64` LE. Always positive; `direction` carries the sign.

Munin config: `filter_prefix_len = 32`, `key_only = false`, `bucket_bits = 12`.

Big-endian on height and txnum is what makes a prefix scan return history in chronological
order for free.

**Store the full 32-byte scripthash, not a truncated prefix.** electrs truncates to 8 bytes to
save space, which introduces collisions and forces a re-verification step against the actual
transaction on every lookup. Storing the full hash costs ~24 extra bytes per row and removes an
entire class of correctness bug plus a random read per result.

Balance is then `sum(funding) - sum(spends)` over the prefix scan. That is O(history length),
which is fine for the overwhelming majority of addresses; a materialised balance cache for
pathological addresses is a later optimisation, not a v1 requirement.

### 3.2 `txloc/` — transaction locator

**Key, 32 bytes:** txid.
**Value, 14 bytes:** `file_no` u16, `offset` u32 (into the file), `length` u32, `height` u32.

Lets a query return raw transaction bytes straight from the mmapped `.dat` file with no Core
RPC. Config: `filter_prefix_len = 32`.

BIP-30 note: heights 91722 and 91880 contain coinbase transactions with txids identical to
those at 91812 and 91842. Decide explicitly — **later height wins**, matching the UTXO-set
semantics of the era — and cover it with a test.

### 3.3 `spends/` — outpoint to spender

**Key, 36 bytes:** txid (32) ‖ vout (u32 BE).
**Value, 12 bytes:** height (u32 BE) ‖ txnum (u32 BE) ‖ vin index (u32 BE).

Answers "is this output spent, and by what." The spender's txid is deliberately not
stored: `(height, txnum)` locates the spending transaction exactly, and the query layer
recovers the txid with a single block read from the mmapped `.dat` files. That trades one
read per `outpoint` query for 32 bytes on every one of ~3.3B spend rows (~90GB of scatter
and ~90GB of index), and stays exact — the key is still the full outpoint, so there is no
collision class. Config: `filter_prefix_len = 32` (filter on the funding txid, so all
outputs of one transaction are found together).

---

## 4. The build pipeline

Spend rows are the whole difficulty. An input references an outpoint, not an address — so
emitting a spend row for the correct scripthash requires knowing what script the referenced
output paid to. Three approaches:

- **Live UTXO map in memory.** Fastest, but ~180M entries at the tip, 8–12GB resident even with
  compact encoding. Fine on a large machine, painful otherwise.
- **Two full passes**, indexing outputs then re-scanning to resolve inputs. Simple, roughly
  doubles parse time.
- **Sort-merge join.** Emit both sides partitioned by outpoint, sort each partition, merge.
  Parallel, bounded memory, single parse pass.

Take the third. It costs one extra sorted scan over the funding set — far less than a second
parse of 750GB, and unlike the hash-map approach its memory ceiling is a configuration
parameter rather than a function of chain size.

### 4.1 Phase 1 — parse and scatter

Worker per `.dat` file, `thread.Pool` sized to core count. Each worker walks blocks in main-chain
order (from `headers.dat`), and for each transaction:

- Compute the txid (double-SHA256 over the non-witness serialisation). Emit a `txloc` row.
- For each output: classify the scriptPubKey, derive the scripthash, emit a
  **funding-side join row** `(outpoint, scripthash, amount, height, txnum)` into the join
  bucket for that outpoint. History funding rows are NOT scattered separately — phase 2
  derives them from these, which removes an entire keyspace of spill.
- For each input (skipping coinbase): emit a **spend-side join row**
  `(outpoint, height, txnum, vin_index)` into the join bucket for that outpoint. No
  separate `spends` scatter either: after the phase-2 sort these rows ARE the spends
  keyspace, in ingest order.

Rows go into per-bucket append buffers. When a buffer fills (default 8MB), it spills to
`work/{keyspace}/{bucket:04x}.part`. Buffers are per-worker to avoid contention; spills append
to a shared per-bucket file under a per-bucket mutex.

Bucket for history rows = top 12 bits of the scripthash. Bucket for join rows = top 12 bits of
the outpoint's txid. Both are uniformly distributed, so partitions come out evenly sized with no
sampling or rebalancing.

### 4.2 Phase 2 — join

Per join bucket, in parallel:

1. Load the bucket's spilled rows (~50MB at 4096 buckets), then delete the spill files —
   the rows are in memory, and freeing the space as phases consume it is what keeps peak
   disk usage down.
2. Radix sort funding rows and spend rows separately by outpoint.
3. Every funding row yields a **history funding row** (scripthash, height, txnum, vout,
   amount), scattered into history buckets by scripthash.
4. Merge-join on outpoint. Each matched pair yields a **history spend row**:
   `(scripthash from the funding side, height/txnum/vin_index from the spend side, amount from
   the funding side)`, scattered likewise.
5. The sorted spend rows are ingested directly into the `spends/` database — they are
   byte-identical to spends keyspace rows and already in key order.

An unmatched spend row means an input referencing an unknown output — impossible on a valid
chain. Log it at error level with the outpoint and fail the build. Do not skip it silently.

### 4.3 Phase 3 — sort and ingest

Per history bucket, in parallel:

1. Load all rows for the bucket (from phase 1 funding scatter and phase 2 spend scatter).
2. LSD radix sort over the fixed 45-byte key.
3. `munin.ingest_begin(db, bucket)`, add every row in order, `ingest_finish`.

Then one `munin.db_commit`. Because buckets are disjoint and each is written as a single run,
the resulting index is globally sorted with **no merge pass over the full dataset**. Delete
`work/`.

### 4.4 Sizing

At present chain size expect roughly 3.5B funding rows and 3.3B spend rows in the history
keyspace, at 53 bytes each — call it 180–200GB of index rows before compression. With 4096
buckets that is ~45MB per bucket, comfortably in memory for an in-place sort. Raise
`bucket_bits` to 13 or 14 on memory-constrained machines; the only cost is more open file
handles during scatter.

Expected wall clock on 16 cores / NVMe / 64GB: 30–50 minutes. On a SATA SSD with 16GB, expect
4+ hours regardless of code quality — the disk and the spill pressure dominate.

---

## 5. Reorg handling

Bulk builds never see a reorg. Incremental catch-up does, and the design is a horizon split.

### 5.1 Horizon split

- **Main body.** Blocks at or below `tip - HORIZON` (default `HORIZON = 100`). Immutable Munin
  runs. Append-only forever, never rewritten.
- **Recent tier.** The last `HORIZON` blocks. Held in memory as sorted rows, backed by
  `recent.log`, an append-only file framed **per block**.

A reorg is then: truncate `recent.log` at the fork point, discard in-memory rows above it,
re-index the new blocks. No tombstones, no MVCC, no sequence numbers. A hundred blocks is tens
of megabytes; rebuilding takes seconds.

Reads merge the main body and the recent tier through `munin.iter_add_source`.

`recent.log` record framing:

| field       | size | notes                       |
|-------------|------|-----------------------------|
| magic       | 4    | `0x48554752` ("HUGR")       |
| height      | 4    | u32 LE                      |
| block_hash  | 32   |                             |
| row_count   | 4    | u32 LE                      |
| payload_len | 4    | u32 LE                      |
| payload     | var  | concatenated rows           |
| crc32c      | 4    | over the whole record       |

One record per block, fsynced after write. Recovery replays from the start, stopping at the
first record that fails its CRC or whose framing is short — a torn tail from a crash mid-append.

### 5.2 Promotion

When a block ages past the horizon, its rows move from the recent tier into the main body. That
is a bucket-partitioned append into Munin, which is exactly what phase 2 of Munin's plan exists
to support. Until Munin phase 2 lands, promotion can batch: accumulate several hundred blocks
and rewrite the affected buckets. Slower, but correct, and it unblocks catch-up without waiting
on compaction.

### 5.3 Detection and unwind

On each catch-up cycle:

1. Re-scan the tail of the `.dat` files for new records and update the header DAG.
2. Recompute the most-work tip. If it differs from the stored tip, walk back through `prev`
   links from both tips until they meet — that is the fork height.
3. If `fork_height > tip - HORIZON`: truncate the recent tier, re-index forward. Normal path.
4. If `fork_height <= tip - HORIZON`: the reorg is deeper than the horizon. **Refuse to serve
   queries, log at fatal level, and require an explicit rebuild from the fork height.** No
   reorg remotely this deep has ever occurred, but "never observed" is not "impossible," and a
   loud failure is the only acceptable behaviour. What must never happen is falling through
   silently and serving wrong balances.

`HORIZON` is configurable so the failure threshold is an operator decision.

### 5.4 Startup check

Read `CHECKPOINT`. Verify the recorded `block_hash` is still on the most-work chain at the
recorded height. If it is not, a crash interrupted a reorg — treat it as a reorg from that
height and unwind before doing anything else. Height alone is insufficient; this is the whole
reason the checkpoint stores a hash.

---

## 6. Query layer

```
hugin balance <address|scripthash>
hugin history <address|scripthash> [--from HEIGHT] [--limit N]
hugin tx <txid> [--raw]
hugin outpoint <txid>:<vout>
```

`balance` seeks `scripthash` in the history keyspace and scans forward while the 32-byte prefix
matches, accumulating funding minus spends. `history` does the same and emits rows. Both merge
the recent tier, so unconfirmed-by-horizon blocks are included.

Address → scripthash derivation must handle P2PKH, P2SH, P2WPKH, P2WSH, and P2TR. Accepting a
raw scripthash directly is useful for debugging and for scripts that already have one.

---

## 7. Build order

Each milestone produces something runnable and verifiable. Milestones 1–3 need no Munin at all
and can proceed in parallel with Munin's own build.

1. **`blkfile.odin`** — enumerate, mmap, iterate records. Verify: total block count across all
   files matches Core's, including orphans.
2. **`header.odin` + `headers_store.odin`** — DAG, work accumulation, chain selection,
   `headers.dat`. Verify: the selected tip hash and height match Core's `getbestblockhash`. This
   is the first real correctness checkpoint and it is cheap to reach.
3. **`tx.odin` + `script.odin`** — byte-walker and classification. Verify: txids for a few
   thousand known transactions across all script types, plus witness and pre-segwit forms.
4. **`bucket.odin` + `sort.odin`** — scatter and radix sort, tested on synthetic rows.
5. **Phase 1 scatter over a truncated chain** (first 200k blocks). Small enough to iterate on,
   large enough to be real.
6. **Phase 2 join + phase 3 ingest** on the same truncated chain. First end-to-end index.
7. **Query layer + verification harness.** Diff against an existing indexer across the address
   corpus. Do not proceed until it matches byte for byte.
8. **Full chain build.** Profile. This is where the performance rules get validated or
   falsified.
9. **`recent.odin` + `catchup.odin`** — horizon tier, reorg detection, unwind. Test against
   synthetic forks before trusting it on the live chain.

The verification harness at step 7 is the gate. Everything before it is plumbing that might be
subtly wrong; everything after it is building on something known correct.

---
