# Hrafnar

Two Odin packages in one repository:

- **`munin/`** — an embedded, bulk-load-oriented sorted-key storage engine. Opaque byte keys,
  immutable runs, merge-free ingest. Knows nothing about Bitcoin.
- **`hugin/`** — a Bitcoin block indexer built on Munin. Reads `blk*.dat` from a Bitcoin Core
  data directory and answers address balance and history queries.

Named for Odin's ravens: *Huginn* (thought) goes out and looks at the world, *Muninn* (memory)
holds what it found.

**The design goal for Hugin is sync speed.** Target: a full index of the chain in well under an
hour on a 16-core machine with NVMe. Where a design decision trades clarity for sync time, sync
time usually wins — but never at the cost of correctness (see below).

---

## The layering rule

`hugin` imports `munin`. `munin` must never import `hugin`, and must never learn what Bitcoin is.

Odin enforces the direction for free — a directory is a package and circular imports don't
compile — but it can't stop Munin from growing a `bitcoin.odin` of its own. That part is on us.

The test: if a type, procedure, constant, or comment in `munin/` contains `scripthash`, `txid`,
`outpoint`, `block`, `height`, or `satoshi`, the layering has leaked and the change is wrong.
Prefix bloom filters belong in Munin — any prefix-scan workload wants those. Reorg handling does
not.

The one subtle case: the **recent tier** (the last ~100 blocks, held uncompacted so reorgs are
cheap) lives in Hugin. Per-block framing, block hashes, and truncation at a fork point are
Bitcoin semantics. Munin exposes a generic `Iter_Source` hook and Hugin plugs the tier into it.

Splitting `munin/` into its own repository later is a `git subtree split` away, and stays cheap
exactly as long as the rule above holds. The trigger to split is a second consumer of the
engine. There isn't one yet.

---

## Repository layout

```
hrafnar/
  CLAUDE.md                 this file — shared conventions
  munin/
    DEVELOPMENT.md          on-disk format, API, build order
    munin.odin              Db lifecycle, public API
    run_write.odin          sorted run writer
    run_read.odin           run reader, single-run iterator
    block.odin              data block encode/decode, prefix compression
    filter.odin             bloom filter build and query
    index.odin              index block representation and search
    iter.odin               merging iterator (k-way heap)
    memtable.odin           in-memory sorted table (phase 2)
    manifest.odin           manifest read/write, atomic rename
    cache.odin              sharded block cache
    ingest.odin             bucket ingest path
    varint.odin
    crc.odin                CRC32C
  hugin/
    DEVELOPMENT.md          row schemas, build pipeline, reorg design
    hugin.odin              package entry, config
    blkfile.odin            blk*.dat discovery, mmap, block framing
    header.odin             header parse, DAG, most-work chain selection
    headers_store.odin      headers.dat flat record file
    tx.odin                 transaction byte-walker
    script.odin             scriptPubKey classification, scripthash derivation
    bucket.odin             partitioned row spill buffers
    sort.odin               LSD radix sort over fixed-width rows
    build.odin              the three-phase bulk pipeline
    join.odin               sort-merge join for spend resolution
    recent.odin             reorg-horizon tier and its append log
    catchup.odin            incremental indexing, reorg detection and unwind
    query.odin              balance, history, tx lookup
  cmd/
    hugin/                  CLI
  tests/
    munin/                  synthetic data only, never touches a chain
    hugin/
```

`tests/munin/` must never require a Bitcoin data directory. Everything in the engine is testable
with generated keys, and it stays that way.

---

## Odin conventions

Target Odin `dev-2026-08` or newer (hard minimum: ARM CRC32C intrinsics and the current `default_temp_allocator_init` signature both landed there). Note `core:os` is the redesigned package: file handles are
`^os.File`, errors are `os.Error` (check `err != nil`, not `ERROR_NONE`), and allocating
procedures take an explicit allocator.

**Allocators.** Every procedure that allocates takes an explicit allocator parameter defaulting
to `context.allocator`. Long-lived structures (`Db`, index handles) store the allocator they
were created with. Per-operation scratch goes through `context.temp_allocator` with an explicit
`free_all` at a defined boundary, or a caller-supplied arena. No hidden global state.

**Errors.** A union of enums per subsystem, not one flat enum:

```odin
Error :: union {
    IO_Error,        // from core:os
    Corruption,      // bad magic, checksum mismatch, truncated block
    Usage_Error,     // keys out of order, iterator misuse, bad config
}
```

Use `or_return` throughout; all multi-return procedures have named returns.

**No panics on bad input data.** A corrupt file on disk and a malformed block are expected
conditions, not bugs. Return an error. `panic` is reserved for violated internal invariants.

**Naming.** `snake_case` procedures prefixed with the type they act on — `run_open`, `iter_next`,
`block_decode`. Types are `Ada_Case`.

---

## Logging

`core:log` throughout. `context.logger` is set once in `main` and flows through the context.

1. **Threads do not inherit the context.** `thread.Thread` has an `init_context` field; set it
   before `thread.start`, and likewise for `thread.Pool`. Miss this and worker threads log into
   the void with no error to tell you.
2. **`log.debugf` is a procedure call, not a macro.** Arguments are evaluated and formatted even
   when the level filter would discard the line. Anything on a per-key, per-row, or
   per-transaction path must be wrapped in `when ODIN_DEBUG { ... }` so it compiles out
   entirely. Runtime level filtering is for per-file and coarser events only.
3. **Log at file and phase granularity, with a worker ID.** "wrote run 0412, 1.2M entries, 48MB"
   is useful; per-entry is not. Progress lines during a sync should carry height, rate, and
   elapsed — the run is long enough that the operator needs to know it's alive.
4. Console logger with `.Terminal_Color`, file logger without, combined via
   `log.create_multi_logger`. A one-hour sync needs a file to read afterwards.

Default options: `{.Level, .Time, .Short_File_Path, .Line}`.

---

## Correctness posture

The index takes tens of minutes to rebuild and is trusted for balances. Silent corruption is the
worst possible failure mode, far worse than being slow. Three rules carry most of the weight:

**Every block on disk carries a CRC32C, verified on read, in release builds too.** Format magic
and version are checked on open; a file from a future format version is a hard error, never a
best-effort read.

**Durability ordering is write-tmp → fsync file → rename → fsync directory.** In that order,
every time. The directory fsync is the step people skip, and skipping it can leave a manifest
pointing at a previous generation while new files sit on disk, invisible.

**Nothing crosses into Munin's immutable main body until it is below Hugin's reorg horizon.** A
spend row written into an immutable run for a transaction that later gets orphaned is permanent,
undetectable corruption of every balance that touches it. No exceptions.

Run a tracking allocator in tests. Bounded, predictable memory is the engine's whole value
proposition; a leak is a correctness bug, not a nuisance.

---

## Build and test

The user-facing program is `hrafnar` (cmd/hrafnar); hugin and munin are internal packages.

```
odin build cmd/hrafnar -o:speed -out:bin/hrafnar
odin build cmd/hrafnar -o:speed -debug -out:bin/hrafnar-debug   # keep symbols for profiling

odin test tests/munin
odin test tests/hugin
odin test tests/munin -define:ODIN_TEST_THREADS=8
```

```
./bin/hrafnar index   --datadir ~/.bitcoin/blocks --index ./index
./bin/hrafnar catchup --datadir ~/.bitcoin/blocks --index ./index
./bin/hrafnar daemon  [--poll SECONDS]           # catch-up loop + query socket
./bin/hrafnar balance <address>
./bin/hrafnar history <address> [--from HEIGHT] [--limit N]
./bin/hrafnar tx <txid> [--raw]
./bin/hrafnar outpoint <txid>:<vout>
```

`--datadir`/`--index` (and network, workers, bucket_bits, horizon) can also come from
`hrafnar.config`, an INI file searched at `--config PATH`, then `./hrafnar.config`, then
`~/.hrafnar/hrafnar.config`. Flags override the file. See `hrafnar.config.example`.

The daemon listens on `<index>/hrafnar.sock` (one request line per connection; protocol
in `hugin/server.odin`). Query commands use the socket when a daemon is serving the
index and open the index directly otherwise — same code path either way.

---

## Phasing

**Munin phase 1** — run format, block cache, filters, merging iterator, bucket ingest, manifest.
Static index, no mutation. Fully testable and fully useful alone.

**Hugin bulk build** — sits on Munin phase 1. This is the sync-speed milestone.

**Munin phase 2** — memtable, write-ahead log, flush, leveled compaction. Do not start it early.
The trigger is Hugin's promotion path, where rows age past the reorg horizon into the main body.
Nothing before that needs it, and it's far easier to get right on a proven file format and
iterator.

**Hugin catch-up** — incremental indexing and reorg handling, on top of Munin phase 2.

Per-package specifics are in `munin/DEVELOPMENT.md` and `hugin/DEVELOPMENT.md`.

---

## Out of scope

Named so they stay out: the Electrum protocol server, mempool tracking, status hashes,
subscriptions and notification fan-out, fee histograms, TLS and connection management. Each is
tractable on top of a stable index; each would double the project if started now.

Also out, on the Munin side: column families, merge operators, transactions, snapshots, custom
comparators, remote storage backends, and any tuning knob without a benchmark showing it matters.
Munin has exactly one caller. Generalise when a second one appears with a real conflicting need.
