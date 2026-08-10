# Indexing Thunder — a feasibility note

Notes on what it would take for hrafnar to index
[thunder-rust](https://github.com/LayerTwo-Labs/thunder-rust), a BIP300/301
sidechain by LayerTwo-Labs. **Nothing here is committed work.** This exists so the
question can be answered later without re-deriving it, and so the shape of the
decision is visible before anyone starts.

Written against thunder-rust `v0.17.2` (master, August 2026). It is under active
development; verify anything below before relying on it.

---

## The short version

The *storage engine, query layer, servers, and daemon transfer almost entirely.*
The *entire ingest path does not* — Thunder keeps no `blk*.dat` files, uses a
different serialization, and has no script system. Expect to write a new block
source and decoder, delete more code than you write, and inherit a maintenance
burden against a moving upstream.

It is not hard. It is *coupled* — that is the real cost.

---

## What Thunder is, mechanically

- **UTXO model**, like Bitcoin. Transactions carry `inputs: Vec<(OutPoint, Hash)>`
  and `outputs: Vec<Output>`.
- **`Output { address: Address, content: Content }`** — and `Address` is a bare
  `[u8; 20]`, displayed as base58, with an `s{sidechain}_{base58}_{checksum}`
  form used for deposits.
- **No script system.** Outputs are keyed by address directly. There is no
  scriptPubKey, no classification, no P2PKH/P2SH/segwit/taproot distinction.
- **Borsh serialization**, not Bitcoin's consensus encoding.
- **Utreexo** accumulator proofs on inputs; ed25519 signatures.
- **Storage is `heed`** (an LMDB wrapper): an archive/state database, not flat
  append-only files.
- The chain is *small* relative to Bitcoin — the property that shapes every
  performance judgement below.

## What transfers unchanged

| | why |
|---|---|
| `munin/` — the whole storage engine | opaque byte keys; it has never known what Bitcoin is |
| Three-phase bulk build | partition → sort → ingest is model-agnostic |
| Query layer (balance, history, UTXOs, outpoint) | Thunder is UTXO with addresses — the same shape |
| Recent tier, reorg handling, promotion | block-height semantics, not Bitcoin semantics |
| Electrum + esplora servers, daemon threading, load tester | protocol and process concerns, chain-agnostic |

## What has to be rewritten

| | why |
|---|---|
| `blkfile.odin` | there are no `blk*.dat` files to mmap or frame by magic |
| `tx.odin` | borsh, not Bitcoin consensus encoding |
| `header.odin` | different header/chain structure |
| `script.odin` | **deleted, not rewritten** — an address *is* the key |
| Row schemas | 20-byte address instead of a 32-byte scripthash; no `io`-class distinctions to preserve |

Note the asymmetry: the parts that transfer are the parts that were hard to get
right (crash safety, concurrency, sorting, reorgs). The parts to rewrite are the
parts that are mostly straightforward decoding.

---

## The one real decision: where blocks come from

**Option A — read their LMDB archive directly.**
Fast, and philosophically consistent with how hrafnar reads Bitcoin. But:

- it introduces hrafnar's **first external dependency** (liblmdb), against a
  project that currently has none;
- it couples us to a **private on-disk schema** in a fast-moving repository. When
  they refactor their archive, we break — and the failure mode is a silent
  mis-parse, not a clean error;
- reading a database another process holds open needs care (LMDB readers are
  fine concurrently, but their transaction lifetimes are ours to respect).

**Option B — fetch blocks over their JSON-RPC.** *(recommended starting point)*

- no dependency, and a public interface that changes more slowly than internals;
- their chain is small enough that the throughput ceiling almost certainly does
  not matter. Hrafnar's ingest machinery is built for 1.4 billion transactions in
  ten minutes; Thunder does not need any of that;
- slower per block, and the node must be running — acceptable for a sidechain
  indexer.

**Recommendation:** define a `Block_Source` interface (enumerate, fetch by height,
tip) and implement Option B first. Bitcoin's blk-file reader becomes the other
implementation. If RPC ever becomes the bottleneck, the LMDB reader slots in
behind the same interface rather than forcing a rewrite.

---

## Consequences worth deciding deliberately

**1. This is Munin's second consumer.** `CLAUDE.md` states the trigger to split
`munin/` into its own repository is exactly that, and that the split stays cheap
only while the layering rule holds. Adding Thunder support means answering
"is Munin a standalone storage engine now?" — better on purpose than by drift.

**2. Where does Thunder live?** Not inside `hugin/` — that package is Bitcoin's
and the layering rule says so. Either a sibling package (`thor/`?) over Munin, or
hugin grows a chain abstraction. The sibling is cleaner and duplicates some
pipeline code; the abstraction is DRYer and risks making hugin worse at its one
job. Prefer the sibling until duplication actually hurts.

**3. The Electrum protocol does not fit.** Electrum is defined in terms of
*scripthashes* — `sha256(scriptPubKey)`, reversed. Thunder has no scripts, so any
Electrum support means inventing a convention (hash the 20-byte address to 32
bytes?) that no existing wallet implements. **The esplora HTTP API is the far
better fit**: it is address-oriented already, its schema tolerates extra fields,
and clients are more forgiving. If Thunder support happens, serve esplora and
skip Electrum.

**4. Upstream churn is the actual cost.** A borsh decoder mirroring another
project's Rust structs is a maintenance commitment. Every `types/` change is a
potential silent breakage. Mitigations: decode defensively and error loudly
rather than guessing; pin a tested upstream version in the README; add a
round-trip test against fixtures captured from a real node.

---

## Rough shape of the work

1. `Block_Source` interface; move Bitcoin's blk reader behind it.
2. Borsh decoder for Thunder's `Block`, `Transaction`, `Output`, `OutPoint`,
   `Address` — with fixtures from a live node as tests.
3. RPC block source (their JSON-RPC; hrafnar already has an HTTP/JSON-RPC client
   in `hugin/rpc.odin` to model it on).
4. Row schemas keyed by 20-byte address; drop scripthash derivation.
5. Reuse the build pipeline, recent tier, catch-up, and query layer.
6. esplora server over the shared handler; address parsing/formatting for base58
   and the `s{n}_` deposit form.

Effort is measured in focused sessions, not weeks — the expensive parts are
already built and proven. The question is not "can this be done" but "is tracking
a moving upstream worth it."

---

## When to revisit

Do it if Thunder gets users who need address history, if hrafnar is already being
maintained anyway, and if you are willing to pin and follow an upstream version.
Skip it if the answer to "who queries this index?" is nobody yet — Thunder's own
node already answers wallet questions for its own wallet, and an indexer only
earns its keep when a *third party* needs to ask about addresses it does not own.
