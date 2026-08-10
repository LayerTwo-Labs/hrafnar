#!/usr/bin/env bun
// hrafnar load test: concurrent legit + hostile traffic against both the
// esplora HTTP API and the Electrum TCP server, then a health check.
//
//   bun contrib/loadtest.ts --host 127.0.0.1 --seconds 30 --clients 16
//   bun contrib/loadtest.ts --host 1.2.3.4 --seconds 60 --clients 32 --whales
//   bun contrib/loadtest.ts --host 127.0.0.1 --seconds 60 --wallets 8
//
// --wallets N runs N simulated BDK wallet syncs (full gap-limit scans over
// both protocols) alongside the raw traffic, and reports whole-sync
// latency — the number a user actually feels.
//
// Legit traffic uses cheap, real queries. Hostile traffic is the stuff a
// bored stranger sends: malformed JSON, bad hex, unknown routes, wrong
// methods, oversized bodies, truncated requests, binary garbage. Nothing
// here should ever take the daemon down — that is the point of the run.

const args = new Map<string, string>()
for (let i = 2; i < Bun.argv.length; i++) {
  const a = Bun.argv[i]
  if (a.startsWith("--")) {
    const key = a.slice(2)
    const next = Bun.argv[i + 1]
    if (next && !next.startsWith("--")) { args.set(key, next); i++ } else { args.set(key, "true") }
  }
}
const HOST = args.get("host") ?? "127.0.0.1"
const HTTP_PORT = Number(args.get("esplora") ?? 3000)
const TCP_PORT = Number(args.get("electrum") ?? 50001)
const SECONDS = Number(args.get("seconds") ?? 20)
const CLIENTS = Number(args.get("clients") ?? 12)
const WHALES = args.has("whales")
const WALLETS = Number(args.get("wallets") ?? 0)   // simulated BDK wallet syncs
const GAP = Number(args.get("gap") ?? 25)         // addresses per scan batch

// A cheap, real address (few entries) and a deep one (thousands+).
const ADDR = args.get("addr") ?? "1M1Jvab4Yvi6xoi2QDFf3Md5t36RUQkTZ6"
const WHALE = "bc1qwzrryqr3ja8w7hnja2spmkgfdcgvqwp5swz4af4ngsjecfz0w0pqud7k38"

const MAX_SAMPLES = 200_000 // reservoir cap: percentiles stay honest, memory bounded

type Stat = { n: number; err: number; ms: number[]; max: number; codes: Map<string, number> }
const mk = (): Stat => ({ n: 0, err: 0, ms: [], max: 0, codes: new Map() })
const stats = { http_ok: mk(), http_bad: mk(), tcp_ok: mk(), tcp_bad: mk(), wallet_e: mk(), wallet_x: mk() }
const bump = (s: Stat, code: string, ms: number, err = false) => {
  s.n++; if (err) s.err++
  if (ms > s.max) s.max = ms
  if (s.ms.length < MAX_SAMPLES) {
    s.ms.push(ms)
  } else {
    // reservoir sampling keeps the distribution unbiased
    const j = Math.floor(Math.random() * s.n)
    if (j < MAX_SAMPLES) s.ms[j] = ms
  }
  s.codes.set(code, (s.codes.get(code) ?? 0) + 1)
}

const pick = <T,>(xs: T[]): T => xs[Math.floor(Math.random() * xs.length)]
const randHex = (n: number) => Array.from({ length: n }, () => "0123456789abcdef"[Math.floor(Math.random() * 16)]).join("")

let tip = 0
try {
  tip = Number(await (await fetch(`http://${HOST}:${HTTP_PORT}/blocks/tip/height`)).text())
} catch { console.error(`cannot reach esplora at ${HOST}:${HTTP_PORT}`); process.exit(1) }
console.log(`target ${HOST}  esplora:${HTTP_PORT}  electrum:${TCP_PORT}  tip ${tip}`)
console.log(`${CLIENTS} clients x ${SECONDS}s, legit + hostile mix${WHALES ? " (whale queries ON)" : ""}\n`)

// ---------------------------------------------------------------- esplora
const httpLegit = () => {
  const h = tip - Math.floor(Math.random() * 500)
  return pick([
    `/blocks/tip/height`, `/blocks/tip/hash`, `/blocks`,
    `/block-height/${h}`,
    `/address/${ADDR}`, `/address/${ADDR}/txs`, `/address/${ADDR}/utxo`,
    `/mempool`, `/fee-estimates`,
    ...(WHALES ? [`/address/${WHALE}`, `/address/${WHALE}/txs`] : []),
  ])
}
const httpHostile = () => pick([
  `/`, `/nope`, `/tx/`, `/tx/zzzz`, `/tx/${randHex(64)}`,             // valid-shaped, absent
  `/address/notanaddress`, `/address/${ADDR}/txs/chain/garbage`,
  `/block/${randHex(64)}`, `/block/${randHex(64)}/txs/7`,             // bad page offset
  `/block-height/999999999`, `/block-height/-1`, `/blocks/abc`,
  `/scripthash/${randHex(63)}`, `/scripthash/${randHex(64)}`,
  `/address/${"A".repeat(5000)}`,                                     // absurd path
  `/tx/${randHex(64)}/outspend/99999`,
])

async function httpClient(deadline: number) {
  while (Date.now() < deadline) {
    const hostile = Math.random() < 0.35
    const path = hostile ? httpHostile() : httpLegit()
    const t0 = performance.now()
    try {
      const r = await fetch(`http://${HOST}:${HTTP_PORT}${path}`, { signal: AbortSignal.timeout(20_000) })
      await r.text()
      bump(hostile ? stats.http_bad : stats.http_ok, String(r.status), performance.now() - t0)
    } catch (e) {
      bump(hostile ? stats.http_bad : stats.http_ok, "NETERR", performance.now() - t0, true)
    }
  }
}

// --------------------------------------------------------------- electrum
const tcpLegit = (id: number) => {
  const h = tip - Math.floor(Math.random() * 500)
  return pick([
    `{"id":${id},"method":"server.ping"}`,
    `{"id":${id},"method":"server.version","params":["load","1.4"]}`,
    `{"id":${id},"method":"blockchain.headers.subscribe"}`,
    `{"id":${id},"method":"blockchain.block.header","params":[${h}]}`,
    `{"id":${id},"method":"mempool.get_fee_histogram"}`,
    `{"id":${id},"method":"blockchain.relayfee"}`,
    `[{"id":${id},"method":"server.ping"},{"id":${id + 1},"method":"blockchain.headers.subscribe"}]`, // batch
  ])
}
const tcpHostile = (id: number) => pick([
  `{`, `}`, `[`, `not json at all`, ``,
  `{"id":${id}}`,                                              // no method
  `{"id":${id},"method":"no.such.method"}`,
  `{"id":${id},"method":"blockchain.transaction.get","params":["zzzz"]}`,
  `{"id":${id},"method":"blockchain.scripthash.get_balance","params":["${randHex(63)}"]}`,
  `{"id":${id},"method":"blockchain.transaction.broadcast","params":["0100"]}`, // bitcoind rejects
  `{"id":${id},"method":"blockchain.block.header","params":[-5]}`,
  `{"id":${id},"method":"blockchain.scripthash.get_history","params":[]}`,
  `\x00\x01\x02\x03binary garbage`,
  `{"id":${id},"method":"server.ping","params":[${"1,".repeat(2000)}1]}`,       // fat params
])

type LineSock = {
  buf: string
  waiters: ((line: string) => void)[]
}

// Bun socket handlers are fixed at connect time, so responses are routed
// through a per-connection queue: each newline-terminated reply resolves
// the oldest pending request.
async function openLineSocket() {
  const state: LineSock = { buf: "", waiters: [] }
  const sock = await Bun.connect<LineSock>({
    hostname: HOST,
    port: TCP_PORT,
    data: state,
    socket: {
      data(s, chunk) {
        const st = s.data
        st.buf += chunk.toString()
        let nl: number
        while ((nl = st.buf.indexOf("\n")) >= 0) {
          const line = st.buf.slice(0, nl)
          st.buf = st.buf.slice(nl + 1)
          st.waiters.shift()?.(line)
        }
      },
      error(s) { while (s.data.waiters.length) s.data.waiters.shift()?.("SOCKERR") },
      close(s) { while (s.data.waiters.length) s.data.waiters.shift()?.("CLOSED") },
    },
  })
  const request = (line: string, timeoutMs = 20_000) =>
    new Promise<string>((resolve) => {
      const timer = setTimeout(() => resolve("TIMEOUT"), timeoutMs)
      state.waiters.push((l) => { clearTimeout(timer); resolve(l) })
      try { sock.write(line + "\n") } catch { clearTimeout(timer); resolve("WRITEERR") }
    })
  return { sock, request }
}

async function tcpClient(deadline: number, seed: number) {
  let id = seed * 100000
  while (Date.now() < deadline) {
    let conn: Awaited<ReturnType<typeof openLineSocket>>
    try {
      conn = await openLineSocket()
    } catch {
      bump(stats.tcp_ok, "CONNERR", 0, true)
      await Bun.sleep(50)
      continue
    }
    for (let k = 0; k < 25 && Date.now() < deadline; k++) {
      const hostile = Math.random() < 0.35
      const line = hostile ? tcpHostile(id++) : tcpLegit(id++)
      const t0 = performance.now()
      const reply = await conn.request(line)
      const ms = performance.now() - t0
      const bad = reply === "TIMEOUT" || reply === "SOCKERR" || reply === "WRITEERR"
      const code = bad ? reply : reply.includes('"error"') ? "rpc-error" : "ok"
      // A hostile line may legitimately make the server hang up.
      bump(hostile ? stats.tcp_bad : stats.tcp_ok, code === "CLOSED" ? "closed" : code, ms, !hostile && bad)
      if (reply === "CLOSED" || bad) break
    }
    try { conn.sock.end() } catch {}
  }
}

// ------------------------------------------------- simulated BDK wallets
//
// What a real wallet does on sync, in order. Electrum (bdk_electrum):
// version handshake, headers.subscribe for the tip, a BATCH of
// scripthash.get_history across the gap limit, then a BATCH of
// transaction.get for every txid discovered, then listunspent. Esplora
// (bdk_esplora): tip, then /scripthash/<h>/txs per address, then /tx/<id>
// for each discovered transaction. Most gap addresses are empty — that is
// realistic; the interesting cost is the few that are not.

// The real address under test, in both wire conventions, plus empty
// lookalikes for the rest of the gap.
const REAL_SH_FWD = "553767ec6581e627415915022b14a673cd7def409c18b81f75cc629d676e70b8"
const REAL_SH_REV = "b8706e679d62cc751fb8189c40ef7dcd73a6142b0215594127e68165ec673755"

async function walletElectrum(deadline: number) {
  while (Date.now() < deadline) {
    const t0 = performance.now()
    let ok = true
    try {
      const conn = await openLineSocket()
      const step = async (line: string) => {
        const r = await conn.request(line, 30_000)
        if (r === "TIMEOUT" || r === "CLOSED" || r === "SOCKERR") throw new Error(r)
        return r
      }
      await step(`{"id":1,"method":"server.version","params":["bdk-sim","1.4"]}`)
      await step(`{"id":2,"method":"blockchain.headers.subscribe"}`)

      // gap-limit scan as ONE batch, like batch_script_get_history
      const shs = [REAL_SH_REV, ...Array.from({ length: GAP - 1 }, () => randHex(64))]
      const batch = "[" + shs.map((h, i) =>
        `{"id":${100 + i},"method":"blockchain.scripthash.get_history","params":["${h}"]}`).join(",") + "]"
      const hist = JSON.parse(await step(batch))
      const txids: string[] = []
      for (const r of hist) for (const e of (r.result ?? [])) txids.push(e.tx_hash)

      // fetch every discovered transaction, batched
      if (txids.length) {
        const tb = "[" + txids.slice(0, 50).map((t, i) =>
          `{"id":${500 + i},"method":"blockchain.transaction.get","params":["${t}"]}`).join(",") + "]"
        const got = JSON.parse(await step(tb))
        // A wallet aborts its sync if any transaction is missing — the
        // pending-tx bug lived exactly here.
        for (const g of got) if (g.error) throw new Error("tx fetch: " + JSON.stringify(g.error).slice(0, 60))
      }
      await step(`{"id":900,"method":"blockchain.scripthash.listunspent","params":["${REAL_SH_REV}"]}`)
      await step(`{"id":901,"method":"blockchain.scripthash.subscribe","params":["${REAL_SH_REV}"]}`)
      conn.sock.end()
    } catch (e) {
      ok = false
      bump(stats.wallet_e, String(e).slice(0, 40), performance.now() - t0, true)
    }
    if (ok) bump(stats.wallet_e, "sync", performance.now() - t0)
    await Bun.sleep(200)
  }
}

async function walletEsplora(deadline: number) {
  while (Date.now() < deadline) {
    const t0 = performance.now()
    let ok = true
    try {
      const get = async (p: string) => {
        const r = await fetch(`http://${HOST}:${HTTP_PORT}${p}`, { signal: AbortSignal.timeout(30_000) })
        const body = await r.text()
        if (r.status >= 500) throw new Error(`HTTP ${r.status}`)
        return { status: r.status, body }
      }
      await get(`/blocks/tip/height`)
      await get(`/blocks/tip/hash`)

      const shs = [REAL_SH_FWD, ...Array.from({ length: GAP - 1 }, () => randHex(64))]
      const txids: string[] = []
      for (const h of shs) {
        const r = await get(`/scripthash/${h}/txs`)
        if (r.status === 200) {
          for (const t of JSON.parse(r.body)) txids.push(t.txid)
        }
      }
      // wallets re-fetch transactions they do not have cached
      for (const t of txids.slice(0, 25)) {
        const r = await get(`/tx/${t}`)
        if (r.status !== 200) throw new Error(`tx ${r.status}`)
      }
      await get(`/scripthash/${REAL_SH_FWD}/utxo`)
    } catch (e) {
      ok = false
      bump(stats.wallet_x, String(e).slice(0, 40), performance.now() - t0, true)
    }
    if (ok) bump(stats.wallet_x, "sync", performance.now() - t0)
    await Bun.sleep(200)
  }
}

// ------------------------------------------------------------------- run
const deadline = Date.now() + SECONDS * 1000
const workers: Promise<void>[] = []
for (let i = 0; i < CLIENTS; i++) {
  workers.push(i % 2 === 0 ? httpClient(deadline) : tcpClient(deadline, i))
}
for (let i = 0; i < WALLETS; i++) {
  workers.push(i % 2 === 0 ? walletElectrum(deadline) : walletEsplora(deadline))
}
const started = Date.now()
await Promise.all(workers)
const elapsed = (Date.now() - started) / 1000

const report = (name: string, s: Stat) => {
  if (!s.n) return
  const sorted = s.ms.slice().sort((a, b) => a - b)
  const at = (p: number) => sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] : 0
  const codes = [...s.codes.entries()].sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k}:${v}`).join(" ")
  console.log(
    `${name.padEnd(16)} ${String(s.n).padStart(7)} reqs  ${(s.n / elapsed).toFixed(0).padStart(5)}/s  ` +
    `p50 ${at(0.5).toFixed(1).padStart(6)}ms  p99 ${at(0.99).toFixed(0).padStart(6)}ms  ` +
    `max ${s.max.toFixed(0).padStart(6)}ms  [${codes}]`,
  )
}
console.log(`--- ${elapsed.toFixed(1)}s ---`)
report("esplora legit", stats.http_ok)
report("esplora hostile", stats.http_bad)
report("electrum legit", stats.tcp_ok)
report("electrum hostile", stats.tcp_bad)
report("wallet:electrum", stats.wallet_e)
report("wallet:esplora", stats.wallet_x)

// ---------------------------------------------------------------- health
console.log("\n--- health check after load ---")
let healthy = true
try {
  const h = await (await fetch(`http://${HOST}:${HTTP_PORT}/blocks/tip/height`, { signal: AbortSignal.timeout(10_000) })).text()
  console.log(`esplora  tip ${h.trim()}  OK`)
} catch (e) { healthy = false; console.log(`esplora  UNREACHABLE — the daemon did not survive`) }
try {
  const conn = await openLineSocket()
  const reply = await conn.request(`{"id":1,"method":"server.version","params":["health","1.4"]}`, 10_000)
  conn.sock.end()
  const ok = reply.includes("result")
  console.log(ok ? `electrum ${reply.trim().slice(0, 70)}  OK` : `electrum BAD REPLY: ${reply}`)
  if (!ok) healthy = false
} catch { healthy = false; console.log(`electrum UNREACHABLE — the daemon did not survive`) }

const netErrs = stats.http_ok.err + stats.tcp_ok.err + stats.wallet_e.err + stats.wallet_x.err
if (netErrs > 0) console.log(`\nWARNING: ${netErrs} legit requests or wallet syncs failed`)
console.log(healthy && netErrs === 0 ? "\nPASS" : "\nFAIL")
process.exit(healthy && netErrs === 0 ? 0 : 1)
