<p align="center">
  <img src="hrafnar_icon.png" alt="Hrafnar" width="200">
</p>

<h1 align="center">Hrafnar</h1>

A fast, standalone Bitcoin address indexer in [Odin](https://odin-lang.org), named for
Odin's ravens (*hrafnar*), serving three interfaces from one binary: a **CLI**, an
**Electrum server** for wallets, and an **esplora-compatible HTTP API** for apps and
explorers. It builds its index by reading `blk*.dat` straight from a Bitcoin Core data
directory — no `txindex`, no RPC round-trips, no third-party dependencies — and answers
balance, history, UTXO, transaction, and spent-outpoint queries. Bitcoin Core's
JSON-RPC is used for exactly two optional things: tracking the mempool (so balances
include unconfirmed activity) and relaying broadcasts and fee estimates. Internally: **`hugin/`**
(*thought*) is the indexer, **`munin/`** (*memory*) is the embedded sorted-key storage
engine underneath.

Sync speed is the design goal — a full index of the chain in about an hour on a modern
multicore machine with NVMe — never at the cost of correctness: everything on disk is
checksummed, every store is crash-safe, and nothing becomes immutable until it is past
the reorg horizon.

## Building from source

The only requirement is the [Odin compiler](https://odin-lang.org/docs/install/),
**`dev-2026-08` or newer**. That is a hard minimum, not a preference: the hardware
CRC32C path uses ARM intrinsics added in `dev-2026-08`, and the temporary-allocator
API changed in the same release, so older compilers fail to build rather than
silently degrade. There is nothing else to install — no package manager, no build
system. The repository plus Odin's core library are the entire dependency graph.

**macOS:**

```sh
brew install odin
odin version          # must report dev-2026-08 or newer
```

**Linux (amd64 or arm64)** — Odin ships official tarballs per release:

```sh
ODIN_VERSION=dev-2026-08
ARCH=amd64                                  # or arm64
curl -fsSL -o odin.tar.gz \
  "https://github.com/odin-lang/Odin/releases/download/$ODIN_VERSION/odin-linux-$ARCH-$ODIN_VERSION.tar.gz"
mkdir -p ~/odin && tar -xzf odin.tar.gz -C ~/odin

# The archive extracts to a directory named after the nightly date, not the
# tag, so resolve it rather than hardcoding it. Odin finds its core/ and base/
# collections relative to the binary, so add that directory to PATH.
export PATH="$(dirname "$(find ~/odin -name odin -type f | head -1)"):$PATH"
odin version
```

Add that `export PATH=...` line to your shell profile to make it stick.

**Then build hrafnar:**

```sh
git clone https://github.com/LayerTwo-Labs/hrafnar
cd hrafnar
mkdir -p bin                                        # odin will not create it
odin build cmd/hrafnar -o:speed -out:bin/hrafnar
./bin/hrafnar version
```

`mkdir -p bin` matters: Odin does not create the output directory and reports the
failure as `LLVM Error: No such file or directory`, which points nowhere near the
cause.

Run the suite if you want to confirm the build (a few seconds, no Bitcoin data
required — every test builds its own synthetic chain):

```sh
odin test tests/munin && odin test tests/hugin
```

For profiling or a debugger, keep the symbols:

```sh
odin build cmd/hrafnar -o:speed -debug -out:bin/hrafnar-debug
```

## Pre-built binaries

Every tagged release publishes a tarball for **linux-amd64**, **linux-arm64**, and
**macos-arm64**, each containing a single `hrafnar` binary — no interpreter, no shared libraries
beyond the system libc — plus this README, the licence, and the example config.

Grab one from the [latest release](../../releases/latest), or with the GitHub CLI:

```sh
gh release download --repo LayerTwo-Labs/hrafnar --pattern '*linux-amd64.tar.gz'
tar -xzf hrafnar-*-linux-amd64.tar.gz
cd hrafnar-*-linux-amd64
./hrafnar version
```

CPU features are detected at runtime — SHA-256 extensions, hardware CRC32C, SIMD —
so one binary per platform runs correctly on every CPU of that architecture and
still uses the fast paths where they exist.

## Install system-wide

Whichever way you got the binary — `bin/hrafnar` from a source build, or `./hrafnar`
from a release tarball — put it on `PATH`:

```sh
sudo install -m 755 bin/hrafnar /usr/local/bin/hrafnar     # source build
sudo install -m 755 ./hrafnar   /usr/local/bin/hrafnar     # release tarball
```

Then `hrafnar daemon` / `hrafnar balance …` work from anywhere. The config is found
automatically at `~/.hrafnar/hrafnar.config`; for a system-wide one, put it at
`/etc/hrafnar.config` and pass `--config /etc/hrafnar.config`:

```sh
sudo cp hrafnar.config.example /etc/hrafnar.config
sudo $EDITOR /etc/hrafnar.config          # set datadir and index
```

## Quick start

> **Wait until Bitcoin Core is fully synced before you start.** hrafnar indexes the
> blocks that are on disk, and it has no way to know the network's real tip — so
> against a node that is still catching up it will happily build an index of a
> partial chain and then answer with *incomplete* balances and histories. Those look
> like real answers, which is worse than an error. Check first:
>
> ```sh
> bitcoin-cli getblockchaininfo | grep -E 'blocks|headers|initialblockdownload'
> ```
>
> Start hrafnar once `initialblockdownload` is `false` and `blocks` has caught up to
> `headers`. The same applies to a node restored from an **assumeutxo** snapshot: it
> serves the tip immediately but backfills historical blocks in the background, so
> `blk*.dat` stays incomplete until that finishes.
>
> Nothing is lost if you jump the gun — the daemon keeps following the chain and will
> converge — but you will have spent the bulk build on a partial chain and served
> wrong numbers in the meantime.

Commands below assume `hrafnar` is on your `PATH`. If you have not installed it,
run it in place instead — `./bin/hrafnar` from a source build, `./hrafnar` from a
release tarball.

```sh
# 1. Point hrafnar at your node's blocks and pick an index location.
#    This path is searched automatically, so no --config flag is ever needed.
mkdir -p ~/.hrafnar
cat > ~/.hrafnar/hrafnar.config <<EOF
[hugin]
datadir = /home/you/.bitcoin/blocks
index   = /home/you/.hrafnar/mainnet
EOF

# 2. Run it
hrafnar daemon
```

That's the whole setup. On a fresh index directory the daemon **runs the initial bulk
build itself** (an hour-ish for the full chain — progress lines throughout), then starts
serving queries and follows the chain, picking up new blocks within its poll interval.

## The daemon

```sh
hrafnar daemon               # detaches, returns your prompt, runs until stopped
hrafnar stop                 # stops it (via <index>/hrafnar.pid)
hrafnar logs                 # follow the daemon log, colorized (Ctrl-C to exit)
hrafnar daemon --foreground  # stay attached instead (systemd, or watching live)
hrafnar daemon --poll 10     # catch-up every 10s (default 30 — no flag needed)
```

The daemon runs indefinitely and keeps balances as fresh as the chain: it watches the
newest blk file (one stat per second), so a new block is indexed within a second or two
of bitcoind writing it — the poll interval is only a fallback safety net. Indexing and
mempool syncing happen on their own threads, so neither interrupts serving. Stop it
with `hrafnar stop` from any shell, `kill <pid>`, or `Ctrl-C` if attached — all
safe at any moment, including mid-build: every store is crash-safe.

Everything is logged to `<index>/hrafnar.log` in both modes — plain text, clean for
vi/grep. `hrafnar logs` tails it with colorized level tags (a built-in `tail -f`);
detached, the log is the only output. On startup a log past 50 MB rotates
to `hrafnar.log.1`, so the pair stays bounded. For a daemon that runs for months without
a restart, classic logrotate works too — use `copytruncate` so the open file handle
stays valid:

```
# /etc/logrotate.d/hrafnar
/home/you/.hrafnar/mainnet/hrafnar.log {
    size 50M
    rotate 2
    copytruncate
    compress
    missingok
}
```

Crashes go to `<index>/hrafnar.err` — that file holds *only* a dying process's output,
so if it is non-empty, something died and its last words are in there. Normal operation
never writes to it.

Queries are served on a Unix socket at `<index>/hrafnar.sock`. One daemon per index —
a second invocation refuses and exits, even while the initial build is still running.

On each new block the daemon rescans the tail of the blk files (incremental — seconds), indexes
new blocks into the recent tier, unwinds shallow reorgs automatically, and promotes
blocks aging past the horizon into the immutable main body. A reorg deeper than the
horizon (default 100 blocks) makes it refuse loudly rather than ever serve a wrong
balance.

While the initial bulk build runs, queries answer with its progress instead
of hanging — `hrafnar tip` will say e.g. `index building: phase 2: 1042/4096
buckets`. The Electrum and esplora ports open only once the index is complete.

## Run as a systemd service

Use `--foreground` under systemd — the service manager does the daemonizing:

```ini
# /etc/systemd/system/hrafnar.service
[Unit]
Description=Hrafnar Bitcoin indexer, Electrum and esplora server
After=network.target bitcoind.service
Wants=bitcoind.service

[Service]
Type=simple
User=you
ExecStart=/usr/local/bin/hrafnar daemon --foreground --config /etc/hrafnar.config
Restart=on-failure
RestartSec=30
# The initial bulk build runs inside the service on first start; watch it
# with: journalctl -u hrafnar -f   (or tail the hrafnar.log in the index dir)

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now hrafnar
journalctl -u hrafnar -f
```

One caveat: if the daemon ever exits with a too-deep-reorg error (deliberately fatal —
the index must be rebuilt), `Restart=on-failure` will retry and fail every 30s until you
intervene; the journal will say exactly why.

## Query

Works while the daemon runs (served over its socket) or with no daemon at all (opens the
index directly) — same output either way.

```sh
hrafnar balance  bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4
hrafnar balance  1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa          # base58 too
hrafnar balance  <64-hex-char scripthash>                    # or raw scripthash

hrafnar history  <address> [--from 800000] [--limit 50]  # txid, direction, amount
hrafnar utxos    <address>       # unspent outputs + total
hrafnar tx       <txid>          # height, size
hrafnar tx       <txid> --raw    # full transaction hex
hrafnar outpoint <txid>:<vout>   # spent by whom, or unspent
hrafnar header   <height>        # hash, prev, merkle, bits, raw hex
hrafnar merkle   <txid>          # merkle inclusion proof (height, pos, branch)
hrafnar feehist                  # mempool fee histogram (needs the daemon)
hrafnar tip                      # the index's current tip height + hash
```

Every query takes `--json` for machine-readable output (same data, one JSON object) —
handy for scripts and `jq`.

Addresses cover P2PKH, P2SH, P2WPKH, P2WSH, and P2TR. Balances and amounts come straight
from the index (no verification round-trips); raw transactions are served from the
mmapped `blk*.dat` files. Queries include blocks inside the reorg horizon.

**Unconfirmed transactions:** the daemon tracks bitcoind's mempool over JSON-RPC
(cookie-authenticated automatically, or set `rpc_user`/`rpc_pass`; see Configuration).
When an address has pending activity, `balance` shows confirmed / pending / total lines,
`history` appends `mempool` entries, and `utxos` flags outputs with a pending spend.
Mempool data is served by the daemon; without one running, queries show confirmed data
only.

## Electrum server

**On by default**: the daemon speaks Electrum protocol 1.4 on `127.0.0.1:50001` —
point Sparrow, Electrum, or a BDK application at it (choose "no SSL"/tcp). Change
the address with `electrum_bind` in `hrafnar.config` (bind `0.0.0.0:50001` to serve
beyond localhost), or turn it off with `electrum = off`. Supported:
balances, history, UTXOs, transactions, merkle proofs, fee histogram, fee
estimation and broadcast (the last two via bitcoind's RPC), and live push
notifications: subscribed wallets are told about new blocks and address
activity (confirmed and mempool) within seconds, no polling needed.

Requests from different clients run concurrently on a worker pool — one
client's slow query never blocks another's — and scripthash queries on
extremely deep addresses (exchange-scale, beyond `electrum_max_history`,
default 5000 rows) are refused cheaply to keep the server responsive for
everyone. Balance queries are never capped.

hrafnar itself never speaks TLS. Wallets that allow plain `tcp://` (BDK
apps, Sparrow, Electrum) connect directly. Wallets that require SSL
(e.g. Bitkey) need a TLS front: stunnel or nginx's stream module
terminating TLS on 50002 and forwarding to 127.0.0.1:50001 — keep
`electrum_bind` on 127.0.0.1 in that setup.

## Esplora HTTP API

Enable in `hrafnar.config` for a Blockstream-esplora-compatible REST API — the
one `bdk_esplora` clients and explorer frontends speak:

```ini
esplora = on
esplora_bind = 127.0.0.1:3000
```

`GET /address/<addr>`, `/address/<addr>/txs` (paginated, 25 per page),
`/tx/<txid>` (fully decoded, input prevouts and fee resolved), `/tx/<txid>/outspends`,
`/block/<hash>/txs`, `/blocks`, `/mempool`, `/fee-estimates`, `POST /tx` broadcast, and
the rest of the core esplora surface. Values are integer satoshis; CORS is open, so
browser apps can call it directly. All of it is served from the same index — no extra
disk — with requests from different clients running concurrently on the worker pool.
Pagination bounds every request, so even exchange-scale addresses serve page by page.

`POST /tx` broadcasts a raw transaction through bitcoind and relays its *actual*
rejection reason on failure (fee too low, missing inputs, and so on) rather than a
generic error.

Same TLS stance as the Electrum port: front with nginx to expose it publicly (its
response cache is a natural fit for explorer traffic).

Unlike the Electrum server, the esplora API is **off by default** — turn it on when you
want it.

## When something goes wrong

**Balances or histories look too low, or the tip is behind the network.** Almost always
this means hrafnar was pointed at a node that was not fully synced — it indexes the
blocks on disk and cannot tell how many are missing. Compare the two tips:

```sh
hrafnar tip                                        # what hrafnar has indexed
bitcoin-cli getblockchaininfo | grep -E 'blocks|headers|initialblockdownload'
```

If Core is still catching up, let it finish; the daemon will follow along and converge
on its own. If Core is fully synced and hrafnar is still behind by more than a block or
two, that is a real problem — check the log. A node restored from an **assumeutxo**
snapshot behaves the same way: it reports the tip immediately while backfilling
historical blocks in the background, so the index is incomplete until that finishes.

The daemon writes two files, and which one has content tells you what happened:

| symptom | what it means | where to look |
|---|---|---|
| `hrafnar.err` has a stack trace | the process **panicked** | the trace names the file and line |
| `hrafnar.err` is **empty** and the daemon is gone | it was **killed**, not crashed — it never got to write anything | `dmesg`, below |
| log ends mid-operation, no shutdown line | same: killed | `dmesg`, below |
| log ends with `daemon shutting down` | clean stop | nothing wrong |

On the next start, hrafnar detects an unclean exit itself and says so:

```
WARN hrafnar: the previous run (pid 1187461, started) did not shut down cleanly —
     it was killed, not stopped. If memory is the suspect, check:
     dmesg -T | grep -i 'killed process'
```

**Was it the OOM killer?** It cannot leave a note in our logs — `SIGKILL` cannot be
caught — so the kernel's log is the only record:

```sh
sudo dmesg -T | grep -iE "out of memory|killed process"
sudo journalctl -k --since "3 days ago" | grep -i "killed process"
```

A hit looks like `Out of memory: Killed process 1187461 (hrafnar) … anon-rss:24469912kB`,
and that `anon-rss` figure is how much it was using when it died. Catch-up progress
lines carry the live figure (`rss 412 MB`) so growth is visible before it becomes fatal.

**Other things worth checking:**

```sh
hrafnar tip                                   # is the index current, and serving?
bitcoin-cli getmempoolinfo                    # our mempool count should match "size"
grep -E "phase|complete" <index>/hrafnar.log  # build progress and timings
grep -iE "warn|error" <index>/hrafnar.log     # everything the daemon complained about
df -h <index>                                 # a full disk mid-build looks like a hang
```

**Interpreting common messages:**

- `catch-up failed (will retry)` — transient; it retries next cycle. Persistent means
  the datadir moved or the node is gone.
- `mempool sync failing (is bitcoind's RPC reachable?)` — the node is down, busy, or the
  cookie rotated. Confirmed data keeps serving throughout.
- `reorg to height N is below the immutable main body` — **fatal by design**. Rebuild.
- `history too large` — an address exceeded `electrum_max_history`; raise it if you
  meant to query it.
- `index building: phase 2: …` from a query — the initial build is still running.

**Rebuilding.** There is no resume: interrupting a bulk build means it restarts from
phase 0 next time. Interrupting is always *safe* (every store is crash-safe), just not
cheap. Delete the index directory and start the daemon to rebuild from scratch.

## Load testing

`contrib/loadtest.ts` drives both protocols concurrently with a mix of legitimate and
deliberately hostile traffic — malformed JSON, bad hex, unknown routes, absurd
parameters, binary garbage, invalid broadcasts — then health-checks the daemon and exits
non-zero if anything degraded:

```sh
bun contrib/loadtest.ts --host 127.0.0.1 --seconds 60 --clients 32
bun contrib/loadtest.ts --host 127.0.0.1 --seconds 60 --clients 16 --wallets 8
bun contrib/loadtest.ts --host 127.0.0.1 --seconds 60 --clients 32 --whales
```

`--wallets N` is the interesting one: it simulates N BDK wallet syncs on both protocols
— handshake, tip subscribe, a batched gap-limit history scan, a batched fetch of every
discovered transaction, then UTXOs — and reports whole-sync latency, the number a user
actually feels. A wallet sync that errors anywhere fails the run.

`--whales` adds deep-address queries (exchange-scale histories), the most expensive
thing the server can be asked to do. Run it from the same machine for true throughput
numbers; from elsewhere, latency is dominated by the network round trip.

Reading the output: if throughput stays flat while latency rises in proportion to the
client count, the query worker pool is saturated — raise `query_workers`. If both stay
put as clients climb, you have headroom.

## Configuration

`hrafnar.config` (INI style) is searched at `--config PATH`, then `./hrafnar.config`,
then `~/.hrafnar/hrafnar.config`; command-line flags override the file. Annotated
example: [`hrafnar.config.example`](hrafnar.config.example).

```ini
[hugin]
datadir = /home/you/.bitcoin/blocks   ; where to find nodes .dat files
index   = /home/you/.hrafnar/mainnet  ; where to store hrafnars index files
network = mainnet                     ; mainnet|testnet3|signet|regtest|ecash|ecash-signet|ecash-regtest
;work = /mnt/scratch/work             ; build scratch on another disk (see Disk space)
;workers = 12                         ; build threads (default: core count)
;bucket_bits = 12                     ; keyspace partitions (default 4096)
;horizon = 100                        ; reorg horizon in blocks
;compact = on                         ; ~3x smaller index, slower address queries
;rpc = 127.0.0.1:8332                 ; bitcoind RPC for mempool tracking
;rpc_cookie = ~/.bitcoin/.cookie      ; default: derived from datadir
;rpc_user = u                         ; alternative to the cookie
;rpc_pass = p
;mempool = on                         ; off to disable unconfirmed tracking
;electrum = off                       ; Electrum serving is ON by default; off disables
;electrum_bind = 127.0.0.1:50001
;electrum_banner = my hrafnar server
;electrum_max_history = 5000
;esplora = on                         ; esplora-compatible HTTP API (default off)
;esplora_bind = 127.0.0.1:3000
;query_workers = 8                    ; query threads (default: half the cores, min 4)
```

**Disk space:** the initial build spills sort scratch — up to ~0.75x the datadir size at
peak, freed as the build progresses — and the final index is ~0.7x the datadir. Budget
**~1.5x your datadir** free on one volume, or point `work` at a second disk to split it.
The build logs an estimate up front. Bitcoin Core v28+ XOR-obfuscated datadirs are
handled transparently.

**Compact mode** (`compact = on`, chosen at build time): stores 8-byte key prefixes and
verifies every query against the actual chain data, electrs-style. The index shrinks to
roughly 0.3x the datadir (~210 GB for mainnet, vs ~495 exact); build scratch is
unchanged. Address queries pay additional block reads, and deep-address scans get
noticeably slower. The default exact index is the right choice unless disk is tight.

**One-shot commands:** `hrafnar index` runs just the bulk build (no serving);
`hrafnar catchup` runs one catch-up cycle — useful from cron instead of a daemon.

## Running against ecash / drynet4

[`ecash-com/bitcoin`](https://github.com/ecash-com/bitcoin) is a Bitcoin Core fork
(the ECX full node) running the `drynet4` network. It keeps Bitcoin's address formats
and script rules, so hrafnar indexes it with no special handling — but **every port is
shifted +200 from Bitcoin's** (RPC 8532, P2P 8533) and the network magic differs, so
`network` has to be set.

```ini
[hugin]
datadir  = /home/you/.drynet4/blocks     ; the node's blocks/ directory
index    = /home/you/.hrafnar/drynet4
network  = ecash                         ; magic ec a5 d4 04, ECX units

; Mempool: the RPC port defaults to 8532 for this network, and the auth cookie is
; found automatically at <datadir>/../.cookie — so neither usually needs setting.
;rpc        = 127.0.0.1:8532
;rpc_cookie = /home/you/.drynet4/.cookie ; the .cookie FILE, not its directory

; Serve wallets and apps
electrum      = on
electrum_bind = 0.0.0.0:50001
esplora       = on
esplora_bind  = 0.0.0.0:3000
```

Bind to `127.0.0.1` instead if you are not exposing the ports, and put stunnel or nginx
in front if you are — there is no TLS in-process (see [Electrum server](#electrum-server)).

**These networks respin, and each run changes the network magic.** `network = ecash`
carries drynet4's (`eca5d404`); for any other run set `magic` alongside it rather than
waiting for a hrafnar release:

```ini
network = ecash
magic   = eca5a104        ; alphanet (drynet4 is eca5d404)
```

Only the magic differs between runs — ports, address formats and units are unchanged,
so everything else still comes from `network`. A wrong value surfaces immediately as
`Bad_Magic` on the first blk file rather than as bad data.

Two things that bite:

- **Wrong RPC port** shows up as a repeating `mempool sync failing (is bitcoind's RPC
  reachable?): Rpc_Unavailable`. That reads like an auth problem and sends you off
  checking cookies, but it usually means something is pointing at 8332. Confirm with
  `bitcoin-cli -rpcport=8532 getmempoolinfo`.
- **The node must be built with ZMQ** (`-DWITH_ZMQ=ON`) if you also intend to run the
  BIP300/301 enforcer alongside it. hrafnar itself does not need ZMQ.

**You do not need the enforcer to run hrafnar.** `bip300301_enforcer` holds the
BIP300/301 sidechain rules and is what a sidechain talks to; indexing, wallets and
explorers only need the node. Note that `OP_DRIVECHAIN` outputs (a repurposed
`OP_NOP5`) have no address representation, so they index by scripthash like any other
output but report no address — which is correct, not a gap.

## How it works

The bulk build is a three-phase, merge-free parallel pipeline: workers parse blocks
zero-copy from mmapped `blk*.dat` files and scatter fixed-width rows into 4096 keyspace
buckets; spends are resolved with a per-bucket sort-merge join (no UTXO set in memory);
each bucket is radix-sorted and ingested into Munin as one immutable run — a globally
sorted index with no merge pass over the full dataset. Live operation keeps the last
`horizon` blocks in a per-block-framed recent tier, so a reorg is a cheap
truncate-and-reindex.

The daemon separates work that must never block serving. Chain indexing and mempool
syncing each run on their own thread; queries execute on a worker pool (`query_workers`,
default half the cores); and the I/O thread does nothing but read requests, write
responses, and push notifications. Index generations are reference-counted, so a request
that started before a new block finishes against the index it began with, and the swap is
atomic. A fault inside a request handler aborts *that request* — the client gets an
error and the daemon keeps serving.

### Hot paths

Three inner loops run over every byte the engine touches, so each uses the widest
instruction the CPU actually has, chosen at runtime — one binary still serves every CPU,
falling back to portable code where an instruction is missing:

| | how | measured |
|---|---|---|
| blk-file de-obfuscation | 32-byte SIMD vectors (`core:simd`) | 1.4 → **50 GB/s** (36x) |
| CRC32C | SSE4.2 / ARMv8 CRC instruction | 1.8 → **7.9 GB/s** (4.4x) |
| SHA-256 | SHA extensions (`core:crypto`) | hardware where present |

Bitcoin Core v28+ XORs every byte of its blk files, so **every** block read pays
de-obfuscation — and a decoded transaction pays it again per input while resolving
prevouts. That is why this shows up in *serving*: on the same machine, making it 36x
cheaper took esplora wallet syncs from 193 ms to 61 ms, Electrum syncs from 39 ms to
13 ms, and throughput from 1,350 to 3,400 requests/second.

It does **not** speed up the bulk build, which is I/O-bound end to end (707 GB read,
~510 GB of scratch spilled, ~494 GB written) and already parallel across every core —
cheaper CPU work only makes the threads wait on disk sooner. Measured build time is
unchanged. (Plain, unobfuscated datadirs skip the copy entirely and read zero-copy from
the mmap, so none of this applies to them.)

The startup log names the path taken for each, so a slow machine is never a mystery:
`sha256 path: hardware (SHA extensions); crc32c path: hardware (CRC32C instruction)`.

Full design documentation: [`munin/DEVELOPMENT.md`](munin/DEVELOPMENT.md),
[`hugin/DEVELOPMENT.md`](hugin/DEVELOPMENT.md), [`CLAUDE.md`](CLAUDE.md).
Security reports: [`SECURITY.md`](SECURITY.md).

## Status

Running against mainnet and verified end to end by real wallets over both protocols:

- full-chain build in ~1h08m (12-core EPYC, NVMe), ~3-6x faster than comparable indexers
- balances and histories byte-exact against public explorers, including a
  95,000-BTC-throughput address and merkle proofs identical to mempool.space's
- BDK wallets sync, show balances and history, and broadcast over **both** the Electrum
  server and the esplora API; unconfirmed transactions appear within seconds on both
- under load on that machine: **3,400 esplora requests/second at a 1.6 ms median**
  while simultaneously rejecting 1,850 malformed requests/second, a full Electrum
  wallet sync in **13 ms** and an esplora one in **61 ms** — every request answered,
  nothing degraded
- new blocks and mempool churn no longer interrupt serving at all: those run on their
  own threads
- hot paths use SIMD and hardware instructions where they earn it: block
  de-obfuscation at ~50 GB/s (36x the scalar loop) and CRC32C on the CPU's own
  instruction (4.4x the table), both runtime-detected so one binary serves every CPU

Deliberately not included: TLS (front with stunnel/nginx), Electrum peer federation, and
any second consumer for Munin — the storage engine generalises when something real needs
it to.

---

## License

MIT. Copyright (c) 2026 LayerTwo Labs. See [LICENSE](LICENSE).
