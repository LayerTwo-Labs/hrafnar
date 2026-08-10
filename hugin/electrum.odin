package hugin

// Electrum protocol 1.4 server. JSON-RPC 2.0 over TCP, newline-delimited,
// persistent connections, built on core:nbio so it shares the daemon's
// single thread — queries interleave with catch-up exactly like the Unix
// socket path, and nothing needs a lock.
//
// Phase 1: request/response only. subscribe methods answer with current
// values and do not push. That fully serves pull-based clients (BDK);
// notification push is phase 2.
//
// No TLS here, ever — front with stunnel or nginx (README shows how).

import "base:runtime"
import "core:bytes"
import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:net"
import "core:nbio"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

ELECTRUM_PROTOCOL :: "1.4"
ELECTRUM_MAX_BUFFER :: 8 << 20 // per-connection request buffer cap (broadcasts can be MBs)
ELECTRUM_MAX_CONNS :: 250
ELECTRUM_SEND_TIMEOUT :: 30 // seconds; a client that won't read gets dropped
ELECTRUM_IDLE_TIMEOUT :: 10 // minutes without a request (wallets ping every ~minute)

// E_Sub_Action defers subscription mutations to the loop thread: worker
// threads compute (including the status), the loop applies — the
// subscription table needs no locks.
E_Sub_Action_Kind :: enum {
	Scripthash_Sub,
	Scripthash_Unsub,
	Headers_Sub,
}

E_Sub_Action :: struct {
	kind:   E_Sub_Action_Kind,
	sh:     [32]u8,
	status: string, // owned by the handler's allocator; "" = null status
}

// electrum_apply_actions performs the deferred registrations against a
// connection. Loop thread (or single-threaded test) only.
electrum_apply_actions :: proc(srv: ^Electrum_Server, conn: ^E_Conn, actions: []E_Sub_Action) {
	for &a in actions {
		switch a.kind {
		case .Scripthash_Sub:
			e_register_sub(conn, a.sh, a.status)
		case .Scripthash_Unsub:
			e_unregister_sub(conn, a.sh)
		case .Headers_Sub:
			conn.want_headers = true
		}
	}
}

// Electrum_Ctx is what method handlers see. The daemon owns idx/mp/rc and
// REPLACES idx on refresh, so handlers must read through this struct on
// every call, never hold an ^Index across calls.
Electrum_Ctx :: struct {
	idx:     ^Index,
	mp:      ^Mempool, // nil: confirmed-only
	rc:      ^Rpc_Client, // nil: broadcast/estimatefee unavailable
	banner:      string,
	version:     string, // e.g. "hrafnar 0.6.0"
	max_history: int, // >0: refuse scripthash queries above this many history rows
	mp_locked:   bool, // this request holds the mempool read lock
}

// e_mp_suspend / e_mp_resume bracket a blocking call to bitcoind. Holding
// the mempool read lock across an RPC stalls the writer (the serve loop's
// mempool sync), and a stalled loop thread stops ALL I/O — responses stop
// being written and clients time out. Handlers that call out MUST drop it.
e_mp_suspend :: proc(ctx: ^Electrum_Ctx) {
	if ctx.mp != nil && ctx.mp_locked {
		sync.rw_mutex_shared_unlock(&ctx.mp.lock)
		ctx.mp_locked = false
	}
}

e_mp_resume :: proc(ctx: ^Electrum_Ctx) {
	if ctx.mp != nil && !ctx.mp_locked {
		sync.rw_mutex_shared_lock(&ctx.mp.lock)
		ctx.mp_locked = true
	}
}

Electrum_Server :: struct {
	ctx:          ^Electrum_Ctx,
	sock:         nbio.TCP_Socket,
	conns:        int,
	stopping:     bool,
	started:      bool, // sockets live (electrum_start ran); false in handler-only tests
	allocator:    runtime.Allocator,
	all_conns:    map[^E_Conn]struct {},
	subs:         map[[32]u8]map[^E_Conn]struct {}, // scripthash -> subscribers
	status_cache: map[[32]u8]string, // last status per subscribed scripthash (owned)
	pool:         ^E_Pool, // nil: requests handled inline (tests)
	esplora_sock: nbio.TCP_Socket,
	esplora_on:   bool,
	electrum_on:  bool,
	h_conns:      map[^H_Conn]struct {},
}

// electrum_server_init prepares subscription state without touching
// sockets — electrum_start builds on it; tests use it directly.
electrum_server_init :: proc(srv: ^Electrum_Server, ctx: ^Electrum_Ctx, allocator := context.allocator) {
	srv.ctx = ctx
	srv.allocator = allocator
	srv.all_conns = make(map[^E_Conn]struct {}, allocator)
	srv.subs = make(map[[32]u8]map[^E_Conn]struct {}, allocator)
	srv.status_cache = make(map[[32]u8]string, allocator)
	srv.h_conns = make(map[^H_Conn]struct {}, allocator)
}

// electrum_server_destroy frees every connection and the subscription
// state. With started sockets the daemon drains ticks first so nbio
// operations have completed.
electrum_server_destroy :: proc(srv: ^Electrum_Server) {
	for conn in srv.all_conns {
		delete(conn.inbuf)
		delete(conn.outq)
		delete(conn.inflight)
		delete(conn.subs)
		for line in conn.pending {
			delete(line, srv.allocator)
		}
		delete(conn.pending)
		free(conn, srv.allocator)
	}
	delete(srv.all_conns)
	for conn in srv.h_conns {
		delete(conn.inbuf)
		delete(conn.outq)
		delete(conn.inflight)
		free(conn, srv.allocator)
	}
	delete(srv.h_conns)
	for _, set in srv.subs {
		s := set
		delete(s)
	}
	delete(srv.subs)
	for _, status in srv.status_cache {
		delete(status, srv.allocator)
	}
	delete(srv.status_cache)
}

// electrum_start binds and begins accepting. The current thread must have
// an acquired nbio event loop; ticking it is the caller's job.
electrum_start :: proc(
	srv: ^Electrum_Server,
	ctx: ^Electrum_Ctx,
	bind: string,
	allocator := context.allocator,
) -> (
	err: Error,
) {
	electrum_server_init(srv, ctx, allocator)
	srv.started = true
	return electrum_listen(srv, bind)
}

// electrum_listen opens the Electrum TCP listener on an already
// initialized server (the daemon initializes once and then opens the
// listeners each protocol asks for).
electrum_listen :: proc(srv: ^Electrum_Server, bind: string) -> (err: Error) {
	ep, ok := net.parse_endpoint(bind)
	if !ok {
		log.errorf("hrafnar: cannot parse electrum_bind %q (want ip:port)", bind)
		return Usage_Error.Bad_Config
	}
	sock, lerr := nbio.listen_tcp(ep)
	if lerr != nil {
		log.errorf("hrafnar: electrum cannot listen on %s: %v", bind, lerr)
		return Usage_Error.Bad_Config
	}
	srv.sock = sock
	srv.electrum_on = true
	nbio.accept_poly(srv.sock, srv, e_on_accept)
	log.infof("hrafnar: electrum server listening on %s (protocol %s)", bind, ELECTRUM_PROTOCOL)
	return nil
}

electrum_stop :: proc(srv: ^Electrum_Server) {
	srv.stopping = true
	if srv.electrum_on {
		nbio.close(srv.sock)
	}
	if srv.esplora_on {
		nbio.close(srv.esplora_sock)
	}
}

// ---------------------------------------------------------------------------
// Connection lifecycle. Each connection keeps one recv armed; writes are
// queued and flushed one send op at a time. `ops` counts in-flight nbio
// operations holding this pointer: the struct is freed only when a dead
// connection's count reaches zero.

E_Conn :: struct {
	srv:          ^Electrum_Server,
	sock:         nbio.TCP_Socket,
	chunk:        [16384]byte,
	inbuf:        [dynamic]byte,
	outq:         [dynamic]byte,
	inflight:     [dynamic]byte,
	sending:      bool,
	dead:         bool,
	ops:          int,
	subs:         map[[32]u8]struct {}, // scripthashes this connection watches
	want_headers: bool,
	busy:         bool, // a worker holds this connection's current request
	pending:      [dynamic]string, // owned lines waiting their turn, in order
}

// electrum_conn_new allocates and registers a connection (shared by the
// accept path and handler-level tests).
electrum_conn_new :: proc(srv: ^Electrum_Server) -> ^E_Conn {
	conn := new(E_Conn, srv.allocator)
	conn.srv = srv
	conn.inbuf = make([dynamic]byte, srv.allocator)
	conn.outq = make([dynamic]byte, srv.allocator)
	conn.inflight = make([dynamic]byte, srv.allocator)
	conn.subs = make(map[[32]u8]struct {}, srv.allocator)
	conn.pending = make([dynamic]string, srv.allocator)
	srv.all_conns[conn] = {}
	return conn
}

@(private = "file")
e_on_accept :: proc(op: ^nbio.Operation, srv: ^Electrum_Server) {
	if op.accept.err != nil {
		// Keep accepting through transient failures (fd exhaustion etc.);
		// stop only when electrum_stop closed the listener.
		if !srv.stopping {
			nbio.accept_poly(srv.sock, srv, e_on_accept)
		}
		return
	}
	client := op.accept.client
	nbio.accept_poly(srv.sock, srv, e_on_accept)

	if srv.conns >= ELECTRUM_MAX_CONNS {
		nbio.close(client)
		return
	}
	srv.conns += 1
	conn := electrum_conn_new(srv)
	conn.sock = client
	e_arm_recv(conn)
}

@(private = "file")
e_arm_recv :: proc(conn: ^E_Conn) {
	conn.ops += 1
	nbio.recv_poly(conn.sock, {conn.chunk[:]}, conn, e_on_recv, timeout = ELECTRUM_IDLE_TIMEOUT * time.Minute)
}

@(private = "file")
e_on_recv :: proc(op: ^nbio.Operation, conn: ^E_Conn) {
	conn.ops -= 1
	if conn.dead {
		e_maybe_free(conn)
		return
	}
	n := op.recv.received
	if op.recv.err != nil || n == 0 {
		e_close(conn)
		return
	}
	append(&conn.inbuf, ..conn.chunk[:n])
	if len(conn.inbuf) > ELECTRUM_MAX_BUFFER {
		log.warnf("hrafnar: electrum connection exceeded %dMB buffer, dropping", ELECTRUM_MAX_BUFFER >> 20)
		e_close(conn)
		return
	}

	for {
		nl := bytes.index_byte(conn.inbuf[:], '\n')
		if nl < 0 {break}
		line := strings.trim_space(string(conn.inbuf[:nl]))
		if len(line) > 0 {
			if conn.srv.pool != nil {
				e_dispatch_line(conn, line)
			} else {
				// Inline fallback (no pool): apply actions immediately.
				acts := make([dynamic]E_Sub_Action, context.temp_allocator)
				resp := electrum_handle(conn.srv.ctx, line, context.temp_allocator, &acts)
				electrum_apply_actions(conn.srv, conn, acts[:])
				append(&conn.outq, resp)
			}
		}
		rest := len(conn.inbuf) - (nl + 1)
		copy(conn.inbuf[:rest], conn.inbuf[nl + 1:])
		resize(&conn.inbuf, rest)
	}
	e_flush(conn)
	e_arm_recv(conn)
}

@(private = "file")
e_flush :: proc(conn: ^E_Conn) {
	if !conn.srv.started {
		return // handler-level tests: output stays queued for inspection
	}
	if conn.sending || len(conn.outq) == 0 {
		return
	}
	conn.inflight, conn.outq = conn.outq, conn.inflight
	clear(&conn.outq)
	conn.sending = true
	conn.ops += 1
	nbio.send_poly(
		conn.sock,
		{conn.inflight[:]},
		conn,
		e_on_sent,
		timeout = ELECTRUM_SEND_TIMEOUT * 1e9,
	)
}

@(private = "file")
e_on_sent :: proc(op: ^nbio.Operation, conn: ^E_Conn) {
	conn.ops -= 1
	conn.sending = false
	if conn.dead {
		e_maybe_free(conn)
		return
	}
	if op.send.err != nil {
		e_close(conn)
		return
	}
	clear(&conn.inflight)
	e_flush(conn)
}

@(private = "file")
e_close :: proc(conn: ^E_Conn) {
	if conn.dead {return}
	conn.dead = true
	conn.srv.conns -= 1
	e_unregister_conn(conn)
	nbio.close(conn.sock)
	e_maybe_free(conn)
}

@(private = "file")
e_maybe_free :: proc(conn: ^E_Conn) {
	if conn.ops > 0 {return}
	delete(conn.inbuf)
	delete(conn.outq)
	delete(conn.inflight)
	delete(conn.subs)
	for line in conn.pending {
		delete(line, conn.srv.allocator)
	}
	delete(conn.pending)
	free(conn, conn.srv.allocator)
}

// ---------------------------------------------------------------------------
// Protocol handling: one raw line in, one response line (or batch) out.
// Pure request/response — separately testable without sockets.

// electrum_handle parses a JSON-RPC request line (single or batch) and
// returns the full response including the trailing newline.
electrum_handle :: proc(ctx: ^Electrum_Ctx, line: string, allocator := context.allocator, actions: ^[dynamic]E_Sub_Action = nil) -> string {
	v, jerr := json.parse_string(line, .JSON, false, context.temp_allocator)
	if jerr != nil {
		return e_clone(fmt.tprintf(`{{"jsonrpc":"2.0","error":{{"code":-32700,"message":"parse error"}},"id":null}}` + "\n"), allocator)
	}
	#partial switch t in v {
	case json.Object:
		b := strings.builder_make(context.temp_allocator)
		e_handle_one(ctx, t, &b, actions, allocator)
		strings.write_byte(&b, '\n')
		return e_clone(strings.to_string(b), allocator)
	case json.Array:
		if len(t) == 0 {
			return e_clone(fmt.tprintf(`{{"jsonrpc":"2.0","error":{{"code":-32600,"message":"empty batch"}},"id":null}}` + "\n"), allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for item, i in t {
			if i > 0 {strings.write_byte(&b, ',')}
			if obj, ook := item.(json.Object); ook {
				e_handle_one(ctx, obj, &b, actions, allocator)
			} else {
				strings.write_string(&b, `{"jsonrpc":"2.0","error":{"code":-32600,"message":"invalid request"},"id":null}`)
			}
		}
		strings.write_string(&b, "]\n")
		return e_clone(strings.to_string(b), allocator)
	}
	return e_clone(fmt.tprintf(`{{"jsonrpc":"2.0","error":{{"code":-32600,"message":"invalid request"}},"id":null}}` + "\n"), allocator)
}

@(private = "file")
e_handle_one :: proc(ctx: ^Electrum_Ctx, req: json.Object, b: ^strings.Builder, actions: ^[dynamic]E_Sub_Action, action_allocator: runtime.Allocator) {
	// The id is echoed verbatim: integer, string, or null.
	id := strings.builder_make(context.temp_allocator)
	if idv, has := req["id"]; has {
		#partial switch iv in idv {
		case json.Float:
			fmt.sbprintf(&id, "%d", i64(iv))
		case json.String:
			strings.write_byte(&id, '"')
			e_json_escape(&id, iv)
			strings.write_byte(&id, '"')
		case:
			strings.write_string(&id, "null")
		}
	} else {
		strings.write_string(&id, "null")
	}
	id_str := strings.to_string(id)

	method, mok := req["method"].(json.String)
	if !mok {
		fmt.sbprintf(b, `{{"jsonrpc":"2.0","error":{{"code":-32600,"message":"missing method"}},"id":%s}}`, id_str)
		return
	}
	params: json.Array
	if pv, has := req["params"]; has {
		params, _ = pv.(json.Array)
	}

	result, ecode, emsg := e_dispatch(ctx, method, params, actions, action_allocator)
	if ecode != 0 {
		fmt.sbprintf(b, `{{"jsonrpc":"2.0","error":{{"code":%d,"message":"`, ecode)
		e_json_escape(b, emsg)
		fmt.sbprintf(b, `"}},"id":%s}}`, id_str)
		return
	}
	fmt.sbprintf(b, `{{"jsonrpc":"2.0","result":%s,"id":%s}}`, result, id_str)
}

// e_dispatch runs one method. Returns the result JSON fragment
// (temp-allocated), or a nonzero code and message on error.
@(private = "file")
e_dispatch :: proc(
	ctx: ^Electrum_Ctx,
	method: string,
	params: json.Array,
	actions: ^[dynamic]E_Sub_Action,
	action_allocator: runtime.Allocator,
) -> (
	result: string,
	ecode: int,
	emsg: string,
) {
	idx := ctx.idx
	switch method {
	case "server.version":
		return fmt.tprintf(`["%s","%s"]`, ctx.version, ELECTRUM_PROTOCOL), 0, ""
	case "server.ping":
		return "null", 0, ""
	case "server.banner":
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '"')
		e_json_escape(&b, ctx.banner)
		strings.write_byte(&b, '"')
		return strings.to_string(b), 0, ""
	case "server.donation_address":
		return `""`, 0, ""
	case "server.peers.subscribe":
		return "[]", 0, ""
	case "server.features":
		if len(idx.chain) == 0 {
			return "", 1, "index empty"
		}
		hb: [64]byte
		return fmt.tprintf(
			`{{"hosts":{{}},"genesis_hash":"%s","hash_function":"sha256","server_version":"%s","protocol_min":"%s","protocol_max":"%s","pruning":null}}`,
			txid_to_hex(idx.chain[0].hash, hb[:]),
			ctx.version,
			ELECTRUM_PROTOCOL,
			ELECTRUM_PROTOCOL,
		), 0, ""

	case "blockchain.headers.subscribe":
		tip := index_tip_height(idx)
		if tip < 0 {
			return "", 1, "index empty"
		}
		if actions != nil {
			append(actions, E_Sub_Action{kind = .Headers_Sub})
		}
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"height":%d,"hex":"`, tip)
		e_hex(&b, idx.chain[tip].raw[:])
		strings.write_string(&b, `"}`)
		return strings.to_string(b), 0, ""

	case "blockchain.block.header":
		height, hok := e_uint_param(params, 0)
		if !hok {
			return "", -32602, "bad height"
		}
		if cp, has := e_uint_param(params, 1); has && cp != 0 {
			return "", 1, "cp_height is not supported"
		}
		hdr, found := query_header(idx, u32(height))
		if !found {
			return "", 1, "height beyond tip"
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '"')
		e_hex(&b, hdr.raw[:])
		strings.write_byte(&b, '"')
		return strings.to_string(b), 0, ""

	case "blockchain.block.headers":
		start, sok := e_uint_param(params, 0)
		count, cok := e_uint_param(params, 1)
		if !sok || !cok {
			return "", -32602, "bad params"
		}
		if cp, has := e_uint_param(params, 2); has && cp != 0 {
			return "", 1, "cp_height is not supported"
		}
		MAX_HEADERS :: 2016
		count = min(count, MAX_HEADERS)
		n := 0
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"count":`)
		hexb := strings.builder_make(context.temp_allocator)
		for h := start; h < start + count && h < len(idx.chain); h += 1 {
			e_hex(&hexb, idx.chain[h].raw[:])
			n += 1
		}
		fmt.sbprintf(&b, `%d,"hex":"%s","max":%d}}`, n, strings.to_string(hexb), MAX_HEADERS)
		return strings.to_string(b), 0, ""

	case "blockchain.scripthash.get_balance":
		sh, ok := e_hash_param(params, 0)
		if !ok {
			return "", -32602, "bad scripthash"
		}
		confirmed, berr := query_balance(idx, sh)
		if berr != nil {
			return "", 1, fmt.tprintf("%v", berr)
		}
		delta: i64
		if ctx.mp != nil {
			delta, _ = mempool_delta(ctx.mp, sh)
		}
		return fmt.tprintf(`{{"confirmed":%d,"unconfirmed":%d}}`, confirmed, delta), 0, ""

	case "blockchain.scripthash.get_history":
		sh, ok := e_hash_param(params, 0)
		if !ok {
			return "", -32602, "bad scripthash"
		}
		if gcode, gmsg := e_history_guard(ctx, sh); gcode != 0 {
			return "", gcode, gmsg
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		first := true
		if herr := e_confirmed_history(ctx, sh, &b, &first); herr != nil {
			return "", 1, fmt.tprintf("%v", herr)
		}
		e_mempool_history(ctx, sh, &b, &first)
		strings.write_byte(&b, ']')
		return strings.to_string(b), 0, ""

	case "blockchain.scripthash.get_mempool":
		sh, ok := e_hash_param(params, 0)
		if !ok {
			return "", -32602, "bad scripthash"
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		first := true
		e_mempool_history(ctx, sh, &b, &first)
		strings.write_byte(&b, ']')
		return strings.to_string(b), 0, ""

	case "blockchain.scripthash.listunspent":
		sh, ok := e_hash_param(params, 0)
		if !ok {
			return "", -32602, "bad scripthash"
		}
		if gcode, gmsg := e_history_guard(ctx, sh); gcode != 0 {
			return "", gcode, gmsg
		}
		utxos, uerr := query_utxos(idx, sh, context.temp_allocator)
		if uerr != nil {
			return "", 1, fmt.tprintf("%v", uerr)
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		first := true
		for u in utxos {
			if ctx.mp != nil {
				if _, spending := mempool_spender(ctx.mp, u.txid, u.vout); spending {
					continue
				}
			}
			hb: [64]byte
			fmt.sbprintf(
				&b,
				`%s{{"tx_hash":"%s","tx_pos":%d,"height":%d,"value":%d}}`,
				"" if first else ",",
				txid_to_hex(u.txid, hb[:]),
				u.vout,
				u.height,
				u.amount,
			)
			first = false
		}
		if ctx.mp != nil {
			for e in mempool_entries(ctx.mp, sh) {
				if e.direction != DIRECTION_FUNDING {continue}
				if _, spending := mempool_spender(ctx.mp, e.txid, e.io_index); spending {continue}
				hb: [64]byte
				fmt.sbprintf(
					&b,
					`%s{{"tx_hash":"%s","tx_pos":%d,"height":0,"value":%d}}`,
					"" if first else ",",
					txid_to_hex(e.txid, hb[:]),
					e.io_index,
					e.amount,
				)
				first = false
			}
		}
		strings.write_byte(&b, ']')
		return strings.to_string(b), 0, ""

	case "blockchain.scripthash.subscribe":
		sh, ok := e_hash_param(params, 0)
		if !ok {
			return "", -32602, "bad scripthash"
		}
		if gcode, gmsg := e_history_guard(ctx, sh); gcode != 0 {
			return "", gcode, gmsg
		}
		status, empty, serr := electrum_status(ctx, sh)
		if serr != nil {
			return "", 1, fmt.tprintf("%v", serr)
		}
		if actions != nil {
			st, _ := clone_string("" if empty else status, action_allocator)
			append(actions, E_Sub_Action{kind = .Scripthash_Sub, sh = sh, status = st})
		}
		if empty {
			return "null", 0, ""
		}
		return fmt.tprintf(`"%s"`, status), 0, ""

	case "blockchain.scripthash.unsubscribe":
		if sh, ok := e_hash_param(params, 0); ok && actions != nil {
			append(actions, E_Sub_Action{kind = .Scripthash_Unsub, sh = sh})
		}
		return "true", 0, ""

	case "blockchain.transaction.get":
		txid, ok := e_hash_param(params, 0)
		if !ok {
			return "", -32602, "bad txid"
		}
		if len(params) > 1 {
			if verbose, vok := params[1].(json.Boolean); vok && bool(verbose) {
				return "", 1, "verbose transactions are not supported"
			}
		}
		raw, _, found, terr := query_tx(idx, txid)
		if terr != nil {
			return "", 1, fmt.tprintf("%v", terr)
		}
		if !found && ctx.mp != nil {
			// A wallet asks for every txid its history returned, and that
			// history includes unconfirmed entries — so this MUST serve
			// the mempool too. Answering "not found" for a pending
			// transaction aborts the wallet's whole sync.
			if mtx, mok := ctx.mp.txs[txid]; mok {
				raw = mtx.raw
				found = true
			}
		}
		if !found {
			return "", 1, "transaction not found"
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '"')
		e_hex(&b, raw)
		strings.write_byte(&b, '"')
		return strings.to_string(b), 0, ""

	case "blockchain.transaction.get_merkle":
		txid, ok := e_hash_param(params, 0)
		if !ok {
			return "", -32602, "bad txid"
		}
		height, pos, branch, found, merr := query_merkle(idx, txid, context.temp_allocator)
		if merr != nil {
			return "", 1, fmt.tprintf("%v", merr)
		}
		if !found {
			return "", 1, "transaction not found"
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"merkle":[`)
		for node, i in branch {
			hb: [64]byte
			fmt.sbprintf(&b, `%s"%s"`, "," if i > 0 else "", txid_to_hex(node, hb[:]))
		}
		fmt.sbprintf(&b, `],"block_height":%d,"pos":%d}}`, height, pos)
		return strings.to_string(b), 0, ""

	case "blockchain.transaction.id_from_pos":
		height, hok := e_uint_param(params, 0)
		pos, pok := e_uint_param(params, 1)
		if !hok || !pok {
			return "", -32602, "bad params"
		}
		txid, terr := resolve_txid_at(idx, u32(height), u32(pos))
		if terr != nil {
			return "", 1, fmt.tprintf("%v", terr)
		}
		want_merkle := false
		if len(params) > 2 {
			if wm, wok := params[2].(json.Boolean); wok {
				want_merkle = bool(wm)
			}
		}
		hb: [64]byte
		if !want_merkle {
			return fmt.tprintf(`"%s"`, txid_to_hex(txid, hb[:])), 0, ""
		}
		_, _, branch, found, merr := query_merkle(idx, txid, context.temp_allocator)
		if merr != nil || !found {
			return "", 1, "merkle unavailable"
		}
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"tx_hash":"%s","merkle":[`, txid_to_hex(txid, hb[:]))
		for node, i in branch {
			nb: [64]byte
			fmt.sbprintf(&b, `%s"%s"`, "," if i > 0 else "", txid_to_hex(node, nb[:]))
		}
		strings.write_string(&b, "]}")
		return strings.to_string(b), 0, ""

	case "blockchain.transaction.broadcast":
		if ctx.rc == nil {
			return "", 1, "bitcoind RPC is not configured"
		}
		raw, rok := e_string_param(params, 0)
		if !rok || !e_is_hex(raw) {
			return "", -32602, "bad raw transaction"
		}
		e_mp_suspend(ctx)
		envelope, rerr := rpc_call(
			ctx.rc,
			"sendrawtransaction",
			fmt.tprintf(`["%s"]`, raw),
			context.temp_allocator,
			intercept_errors = false,
		)
		e_mp_resume(ctx)
		if rerr != nil {
			return "", 1, fmt.tprintf("broadcast failed: %v", rerr)
		}
		env, eok := envelope.(json.Object)
		if !eok {
			return "", 1, "malformed bitcoind response"
		}
		if errv, has := env["error"]; has {
			if errobj, ook := errv.(json.Object); ook {
				if msg, mok2 := errobj["message"].(json.String); mok2 {
					return "", 1, string(msg)
				}
			}
		}
		if txid, tok := env["result"].(json.String); tok {
			return fmt.tprintf(`"%s"`, txid), 0, ""
		}
		return "", 1, "malformed bitcoind response"

	case "blockchain.estimatefee":
		target, tok := e_uint_param(params, 0)
		if !tok {
			target = 6
		}
		if ctx.rc == nil {
			return "-1", 0, ""
		}
		e_mp_suspend(ctx)
		envelope, rerr := rpc_call(ctx.rc, "estimatesmartfee", fmt.tprintf("[%d]", target), context.temp_allocator)
		e_mp_resume(ctx)
		if rerr == nil {
			if env, eok := envelope.(json.Object); eok {
				if res, ook := env["result"].(json.Object); ook {
					if rate, fok := res["feerate"].(json.Float); fok {
						return fmt.tprintf("%.8f", rate), 0, ""
					}
				}
			}
		}
		return "-1", 0, ""

	case "blockchain.relayfee":
		if ctx.rc != nil {
			e_mp_suspend(ctx)
			envelope, rerr := rpc_call(ctx.rc, "getmempoolinfo", "", context.temp_allocator)
			e_mp_resume(ctx)
			if rerr == nil {
				if env, eok := envelope.(json.Object); eok {
					if res, ook := env["result"].(json.Object); ook {
						if rate, fok := res["mempoolminfee"].(json.Float); fok {
							return fmt.tprintf("%.8f", rate), 0, ""
						}
					}
				}
			}
		}
		return "0.00001000", 0, ""

	case "mempool.get_fee_histogram":
		if ctx.mp == nil {
			return "[]", 0, ""
		}
		bins := mempool_fee_histogram(ctx.mp, context.temp_allocator)
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for bin, i in bins {
			fmt.sbprintf(&b, "%s[%.2f,%d]", "," if i > 0 else "", bin.rate, bin.vsize)
		}
		strings.write_byte(&b, ']')
		return strings.to_string(b), 0, ""
	}
	return "", -32601, fmt.tprintf("unknown method %s", method)
}

// electrum_status computes the scripthash status: sha256 over
// "txid:height:" for the confirmed history in chronological order, then
// mempool entries (height -1 with unconfirmed parents, else 0). Empty
// history reports empty=true (the protocol's null).
electrum_status :: proc(ctx: ^Electrum_Ctx, sh: [32]u8) -> (status: string, empty: bool, err: Error) {
	idx := ctx.idx
	entries := query_history_resolved(idx, sh, 0, -1, context.temp_allocator) or_return

	b := strings.builder_make(context.temp_allocator)
	last: [32]u8
	have_last := false
	for r in entries {
		if have_last && r.txid == last {continue}
		last = r.txid
		have_last = true
		hb: [64]byte
		fmt.sbprintf(&b, "%s:%d:", txid_to_hex(r.txid, hb[:]), r.entry.height)
	}
	if ctx.mp != nil {
		seen := make(map[[32]u8]struct {}, context.temp_allocator)
		for e in mempool_entries(ctx.mp, sh) {
			if e.txid in seen {continue}
			seen[e.txid] = {}
			hb: [64]byte
			fmt.sbprintf(&b, "%s:%d:", txid_to_hex(e.txid, hb[:]), e_mempool_height(ctx.mp, e.txid))
		}
	}
	if strings.builder_len(b) == 0 {
		return "", true, nil
	}
	digest := sha256(transmute([]byte)strings.to_string(b))
	out := strings.builder_make(context.temp_allocator)
	e_hex(&out, digest[:])
	return strings.to_string(out), false, nil
}

@(private = "file")
e_confirmed_history :: proc(ctx: ^Electrum_Ctx, sh: [32]u8, b: ^strings.Builder, first: ^bool) -> Error {
	entries, herr := query_history_resolved(ctx.idx, sh, 0, -1, context.temp_allocator)
	if herr != nil {
		return herr
	}
	last: [32]u8
	have_last := false
	for r in entries {
		if have_last && r.txid == last {continue}
		last = r.txid
		have_last = true
		hb: [64]byte
		fmt.sbprintf(
			b,
			`%s{{"tx_hash":"%s","height":%d}}`,
			"" if first^ else ",",
			txid_to_hex(r.txid, hb[:]),
			r.entry.height,
		)
		first^ = false
	}
	return nil
}

@(private = "file")
e_mempool_history :: proc(ctx: ^Electrum_Ctx, sh: [32]u8, b: ^strings.Builder, first: ^bool) {
	if ctx.mp == nil {return}
	seen := make(map[[32]u8]struct {}, context.temp_allocator)
	for e in mempool_entries(ctx.mp, sh) {
		if e.txid in seen {continue}
		seen[e.txid] = {}
		fee: u64
		if mtx, mok := ctx.mp.txs[e.txid]; mok {
			fee = mtx.fee
		}
		hb: [64]byte
		fmt.sbprintf(
			b,
			`%s{{"tx_hash":"%s","height":%d,"fee":%d}}`,
			"" if first^ else ",",
			txid_to_hex(e.txid, hb[:]),
			e_mempool_height(ctx.mp, e.txid),
			fee,
		)
		first^ = false
	}
}

// e_mempool_height: Electrum reports unconfirmed txs at height 0, or -1
// when they spend outputs of other unconfirmed txs.
@(private = "file")
e_mempool_height :: proc(mp: ^Mempool, txid: [32]u8) -> int {
	mtx, ok := mp.txs[txid]
	if !ok {return 0}
	for &op in mtx.spends {
		parent: [32]u8
		copy(parent[:], op[0:32])
		if parent in mp.txs {
			return -1
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// Query worker pool: requests execute off the loop thread so no client's
// request blocks another's. Workers acquire the current index generation
// (refcounted) and the mempool's shared lock for the request's duration;
// subscription mutations come back as actions applied on the loop thread.
// Per-connection ordering is preserved: one request in flight per
// connection, the rest queue in arrival order.

E_Pool :: struct {
	slot:        ^Index_Slot,
	mp:          ^Mempool,
	rc:          ^Rpc_Client,
	banner:      string,
	version:     string,
	max_history: int,
	loop:        ^nbio.Event_Loop,
	allocator:   runtime.Allocator,

	mu:       sync.Mutex,
	sem:      sync.Sema,
	jobs:     [dynamic]E_Job,
	head:     int,
	shutdown: bool,

	done_mu: sync.Mutex,
	done:    [dynamic]E_Done,

	threads: [dynamic]^thread.Thread,
}

E_Job :: struct {
	conn:        ^E_Conn, // electrum job
	hconn:       ^H_Conn, // esplora job (line carries the path)
	unix_fd:     posix.FD, // unix-socket job when both conns are nil
	line:        string, // owned by pool.allocator
	http_method: string, // owned (esplora)
	http_body:   string, // owned (esplora)
}

E_Done :: struct {
	conn:    ^E_Conn,
	hconn:   ^H_Conn,
	status:  int, // esplora
	ctype:   string, // esplora (static)
	resp:    string, // owned by pool.allocator
	actions: [dynamic]E_Sub_Action, // strings owned by pool.allocator
}

ELECTRUM_WORKERS :: 4

// Worker_Recover contains a request fault: panics, asserts, and
// bounds-check violations inside a request handler abort THAT REQUEST —
// the client gets an internal-error response and the worker lives on.
// Request handlers are read-only, so abandoning one mid-flight is safe;
// the only held resources (index refcount, mempool shared lock) are
// tracked here and released on the recovery path. Chain mutation code
// (catch-up, promotion) deliberately has no such net: a fault there is
// still fatal, because continuing could write a wrong index.
@(private = "file")
Worker_Recover :: struct {
	jb:     libc.jmp_buf,
	active: bool,
	idx:    ^Index,
	ctx:    ^Electrum_Ctx, // holds the live mempool-lock state
	job:    E_Job,
	pool:   ^E_Pool,
}

@(private = "file")
worker_fault_handler :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	rec := (^Worker_Recover)(context.user_ptr)
	if rec != nil && rec.active {
		log.errorf(
			"hrafnar: request handler fault: %s %s at %v — request aborted, worker recovered",
			prefix,
			message,
			loc,
		)
		rec.active = false
		libc.longjmp(&rec.jb, 1)
	}
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

// e_fault_complete answers the faulted request's client so nothing hangs.
@(private = "file")
e_fault_complete :: proc(pool: ^E_Pool, job: ^E_Job) {
	if job.hconn != nil {
		resp, _ := clone_string("internal error", pool.allocator)
		sync.mutex_lock(&pool.done_mu)
		append(&pool.done, E_Done{hconn = job.hconn, status = 500, ctype = "text/plain", resp = resp})
		sync.mutex_unlock(&pool.done_mu)
		nbio.wake_up(pool.loop)
	} else if job.conn != nil {
		resp, _ := clone_string(
			`{"jsonrpc":"2.0","error":{"code":-32603,"message":"internal server error"},"id":null}` + "\n",
			pool.allocator,
		)
		actions := make([dynamic]E_Sub_Action, pool.allocator)
		sync.mutex_lock(&pool.done_mu)
		append(&pool.done, E_Done{conn = job.conn, resp = resp, actions = actions})
		sync.mutex_unlock(&pool.done_mu)
		nbio.wake_up(pool.loop)
	} else {
		posix.close(job.unix_fd)
	}
}

electrum_pool_start :: proc(
	pool: ^E_Pool,
	slot: ^Index_Slot,
	mp: ^Mempool,
	rc: ^Rpc_Client,
	banner: string,
	version: string,
	max_history: int,
	loop: ^nbio.Event_Loop,
	workers := 0, // <=0: ELECTRUM_WORKERS
	allocator := context.allocator,
) {
	pool.slot = slot
	pool.mp = mp
	pool.rc = rc
	pool.banner = banner
	pool.version = version
	pool.max_history = max_history
	pool.loop = loop
	pool.allocator = allocator
	pool.jobs = make([dynamic]E_Job, allocator)
	pool.done = make([dynamic]E_Done, allocator)
	pool.threads = make([dynamic]^thread.Thread, allocator)
	n_workers := workers if workers > 0 else ELECTRUM_WORKERS
	for _ in 0 ..< max(n_workers, 1) {
		t := thread.create(e_worker_main)
		t.data = pool
		t.init_context = context
		append(&pool.threads, t)
		thread.start(t)
	}
}

electrum_pool_stop :: proc(pool: ^E_Pool) {
	sync.mutex_lock(&pool.mu)
	pool.shutdown = true
	sync.mutex_unlock(&pool.mu)
	for _ in pool.threads {
		sync.sema_post(&pool.sem)
	}
	for t in pool.threads {
		thread.join(t)
		thread.destroy(t)
	}
	delete(pool.threads)
	for &j in pool.jobs[pool.head:] {
		if j.line != "" {delete(j.line, pool.allocator)}
	}
	delete(pool.jobs)
	for &d in pool.done {
		e_done_free(pool, &d)
	}
	delete(pool.done)
}

@(private = "file")
e_done_free :: proc(pool: ^E_Pool, d: ^E_Done) {
	delete(d.resp, pool.allocator)
	for &a in d.actions {
		delete(a.status, pool.allocator)
	}
	delete(d.actions)
}

// electrum_pool_submit_unix hands a CLI socket connection to a worker;
// the worker owns the fd from here (reads, serves, writes, closes).
electrum_pool_submit_unix :: proc(pool: ^E_Pool, fd: posix.FD) {
	sync.mutex_lock(&pool.mu)
	append(&pool.jobs, E_Job{unix_fd = fd})
	sync.mutex_unlock(&pool.mu)
	sync.sema_post(&pool.sem)
}

@(private = "file")
e_dispatch_line :: proc(conn: ^E_Conn, line: string) {
	srv := conn.srv
	owned, _ := clone_string(line, srv.pool.allocator)
	if conn.busy {
		append(&conn.pending, owned)
		return
	}
	conn.busy = true
	conn.ops += 1
	e_pool_submit(srv.pool, conn, owned)
}

@(private = "file")
e_pool_submit :: proc(pool: ^E_Pool, conn: ^E_Conn, owned_line: string) {
	sync.mutex_lock(&pool.mu)
	append(&pool.jobs, E_Job{conn = conn, line = owned_line})
	sync.mutex_unlock(&pool.mu)
	sync.sema_post(&pool.sem)
}

@(private = "file")
e_worker_main :: proc(t: ^thread.Thread) {
	pool := (^E_Pool)(t.data)
	rec: Worker_Recover
	rec.pool = pool
	context.user_ptr = &rec
	context.assertion_failure_proc = worker_fault_handler
	for {
		sync.sema_wait(&pool.sem)
		sync.mutex_lock(&pool.mu)
		if pool.head >= len(pool.jobs) {
			done := pool.shutdown
			sync.mutex_unlock(&pool.mu)
			if done {return}
			continue
		}
		job := pool.jobs[pool.head]
		pool.head += 1
		if pool.head == len(pool.jobs) {
			clear(&pool.jobs)
			pool.head = 0
		}
		sync.mutex_unlock(&pool.mu)

		// Fault containment: anything that panics between here and
		// rec.active=false lands back at this setjmp, releases what the
		// request held, and answers the client with an internal error.
		rec.job = job
		rec.idx = nil
		rec.ctx = nil
		rec.active = true
		if libc.setjmp(&rec.jb) != 0 {
			if rec.ctx != nil && rec.ctx.mp_locked && pool.mp != nil {
				sync.rw_mutex_shared_unlock(&pool.mp.lock)
				rec.ctx.mp_locked = false
			}
			if rec.idx != nil {
				index_release(rec.idx)
			}
			e_fault_complete(pool, &rec.job)
			free_all(context.temp_allocator)
			continue
		}

		// Deliberate fault hook: lets tests (and live probes) prove the
		// containment works. Harmless in production — the "request" just
		// gets the internal-error response.
		if job.line == "__hrafnar_fault_injection__" {
			panic("injected request fault")
		}

		if job.hconn != nil {
			idx := index_slot_get(pool.slot)
			rec.idx = idx
			ctx := Electrum_Ctx {
				idx         = idx,
				mp          = pool.mp,
				rc          = pool.rc,
				banner      = pool.banner,
				version     = pool.version,
				max_history = pool.max_history,
			}
			rec.ctx = &ctx
			if pool.mp != nil {
				sync.rw_mutex_shared_lock(&pool.mp.lock)
				ctx.mp_locked = true
			}
			st, ct, resp := esplora_handle(&ctx, job.http_method, job.line, job.http_body, pool.allocator)
			if ctx.mp_locked {
				sync.rw_mutex_shared_unlock(&pool.mp.lock)
				ctx.mp_locked = false
			}
			index_release(idx)
			rec.idx = nil
			rec.active = false
			delete(job.line, pool.allocator)
			delete(job.http_method, pool.allocator)
			delete(job.http_body, pool.allocator)
			sync.mutex_lock(&pool.done_mu)
			append(&pool.done, E_Done{hconn = job.hconn, status = st, ctype = ct, resp = resp})
			sync.mutex_unlock(&pool.done_mu)
			nbio.wake_up(pool.loop)
		} else if job.conn == nil {
			idx := index_slot_get(pool.slot)
			rec.idx = idx
			serve_connection(idx, pool.mp, job.unix_fd)
			index_release(idx)
			rec.idx = nil
			rec.active = false
		} else {
			idx := index_slot_get(pool.slot)
			rec.idx = idx
			ctx := Electrum_Ctx {
				idx         = idx,
				mp          = pool.mp,
				rc          = pool.rc,
				banner      = pool.banner,
				version     = pool.version,
				max_history = pool.max_history,
			}
			actions := make([dynamic]E_Sub_Action, pool.allocator)
			rec.ctx = &ctx
			if pool.mp != nil {
				sync.rw_mutex_shared_lock(&pool.mp.lock)
				ctx.mp_locked = true
			}
			resp := electrum_handle(&ctx, job.line, pool.allocator, &actions)
			if ctx.mp_locked {
				sync.rw_mutex_shared_unlock(&pool.mp.lock)
				ctx.mp_locked = false
			}
			index_release(idx)
			rec.idx = nil
			rec.active = false
			delete(job.line, pool.allocator)

			sync.mutex_lock(&pool.done_mu)
			append(&pool.done, E_Done{conn = job.conn, resp = resp, actions = actions})
			sync.mutex_unlock(&pool.done_mu)
			nbio.wake_up(pool.loop)
		}
		free_all(context.temp_allocator)
	}
}

// electrum_pool_drain applies completed work on the loop thread: queue
// responses, apply subscription actions, start the connection's next
// pending request.
electrum_pool_drain :: proc(srv: ^Electrum_Server) {
	pool := srv.pool
	if pool == nil {
		return
	}
	local := make([dynamic]E_Done, context.temp_allocator)
	sync.mutex_lock(&pool.done_mu)
	for &d in pool.done {
		append(&local, d)
	}
	clear(&pool.done)
	sync.mutex_unlock(&pool.done_mu)

	for &d in local {
		if d.hconn != nil {
			h_complete(srv, &d)
			delete(d.resp, pool.allocator)
			continue
		}
		conn := d.conn
		conn.ops -= 1
		if conn.dead {
			e_done_free(pool, &d)
			e_maybe_free(conn)
			continue
		}
		electrum_apply_actions(srv, conn, d.actions[:])
		append(&conn.outq, d.resp)
		e_done_free(pool, &d)
		conn.busy = false
		if len(conn.pending) > 0 {
			next := conn.pending[0]
			ordered_remove(&conn.pending, 0)
			conn.busy = true
			conn.ops += 1
			e_pool_submit(pool, conn, next)
		}
		e_flush(conn)
	}
}

// ---------------------------------------------------------------------------
// Subscriptions and push notifications (phase 2). The daemon calls the
// notify procs after each catch-up / mempool cycle with the scripthashes
// that cycle touched; only affected subscriptions recompute.

@(private = "file")
e_register_sub :: proc(conn: ^E_Conn, sh: [32]u8, status: string) {
	srv := conn.srv
	conn.subs[sh] = {}
	set, has := &srv.subs[sh]
	if !has {
		srv.subs[sh] = make(map[^E_Conn]struct {}, srv.allocator)
		set = &srv.subs[sh]
	}
	set^[conn] = {}
	e_cache_status(srv, sh, status)
}

@(private = "file")
e_unregister_sub :: proc(conn: ^E_Conn, sh: [32]u8) {
	srv := conn.srv
	delete_key(&conn.subs, sh)
	if set, has := &srv.subs[sh]; has {
		delete_key(set, conn)
		if len(set^) == 0 {
			s := set^
			delete_key(&srv.subs, sh)
			delete(s)
			if old, ok := srv.status_cache[sh]; ok {
				delete(old, srv.allocator)
				delete_key(&srv.status_cache, sh)
			}
		}
	}
}

@(private = "file")
e_unregister_conn :: proc(conn: ^E_Conn) {
	for sh in conn.subs {
		srv := conn.srv
		if set, has := &srv.subs[sh]; has {
			delete_key(set, conn)
			if len(set^) == 0 {
				s := set^
				delete_key(&srv.subs, sh)
				delete(s)
				if old, ok := srv.status_cache[sh]; ok {
					delete(old, srv.allocator)
					delete_key(&srv.status_cache, sh)
				}
			}
		}
	}
	clear(&conn.subs)
	delete_key(&conn.srv.all_conns, conn)
}

@(private = "file")
e_cache_status :: proc(srv: ^Electrum_Server, sh: [32]u8, status: string) {
	if old, ok := srv.status_cache[sh]; ok {
		if old == status {
			return
		}
		delete(old, srv.allocator)
	}
	cloned, _ := clone_string(status, srv.allocator)
	srv.status_cache[sh] = cloned
}

// electrum_notify recomputes status for touched subscribed scripthashes
// (or all of them after a reorg) and pushes to their subscribers.
electrum_notify :: proc(srv: ^Electrum_Server, touched: ^map[[32]u8]struct {}, all := false) {
	if len(srv.subs) == 0 {
		return
	}
	if srv.ctx.mp != nil {
		sync.rw_mutex_shared_lock(&srv.ctx.mp.lock)
	}
	defer if srv.ctx.mp != nil {
		sync.rw_mutex_shared_unlock(&srv.ctx.mp.lock)
	}
	if all {
		// Iterate a snapshot: pushes never mutate srv.subs, but be safe.
		shs := make([dynamic][32]u8, context.temp_allocator)
		for sh in srv.subs {
			append(&shs, sh)
		}
		for sh in shs {
			e_notify_sh(srv, sh)
		}
		return
	}
	if touched == nil {
		return
	}
	for sh in touched^ {
		if sh in srv.subs {
			e_notify_sh(srv, sh)
		}
	}
}

@(private = "file")
e_notify_sh :: proc(srv: ^Electrum_Server, sh: [32]u8) {
	status, empty, serr := electrum_status(srv.ctx, sh)
	if serr != nil {
		log.warnf("hrafnar: electrum: status recompute failed: %v", serr)
		return
	}
	new_status := "" if empty else status
	if old, ok := srv.status_cache[sh]; ok && old == new_status {
		return
	}
	e_cache_status(srv, sh, new_status)

	hb: [64]byte
	line: string
	if empty {
		line = fmt.tprintf(
			`{{"jsonrpc":"2.0","method":"blockchain.scripthash.subscribe","params":["%s",null]}}` + "\n",
			txid_to_hex(sh, hb[:]),
		)
	} else {
		line = fmt.tprintf(
			`{{"jsonrpc":"2.0","method":"blockchain.scripthash.subscribe","params":["%s","%s"]}}` + "\n",
			txid_to_hex(sh, hb[:]),
			new_status,
		)
	}
	if set, has := srv.subs[sh]; has {
		for conn in set {
			if conn.dead {continue}
			append(&conn.outq, line)
			e_flush(conn)
		}
	}
}

// electrum_notify_headers pushes the new tip header to every
// headers.subscribe subscriber.
electrum_notify_headers :: proc(srv: ^Electrum_Server) {
	tip := index_tip_height(srv.ctx.idx)
	if tip < 0 {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"jsonrpc":"2.0","method":"blockchain.headers.subscribe","params":[{{"height":%d,"hex":"`, tip)
	e_hex(&b, srv.ctx.idx.chain[tip].raw[:])
	strings.write_string(&b, "\"}]}\n")
	line := strings.to_string(b)
	for conn in srv.all_conns {
		if conn.dead || !conn.want_headers {continue}
		append(&conn.outq, line)
		e_flush(conn)
	}
}

// ---------------------------------------------------------------------------
// Small helpers.

// e_history_guard bounds the expensive path: resolving a deep address's
// txids costs one block read per distinct height, and on this shared
// thread a 60k-entry scan would stall every other client for the
// duration. Counting rows costs almost nothing, so oversized requests
// are refused before any block is read.
@(private = "file")
e_history_guard :: proc(ctx: ^Electrum_Ctx, sh: [32]u8) -> (ecode: int, emsg: string) {
	if ctx.max_history <= 0 {
		return 0, ""
	}
	n, herr := query_history_count(ctx.idx, sh)
	if herr != nil {
		return 1, fmt.tprintf("%v", herr)
	}
	if n > ctx.max_history {
		return 1, fmt.tprintf(
			"history too large: %d entries exceeds this server's limit of %d",
			n,
			ctx.max_history,
		)
	}
	return 0, ""
}

@(private = "file")
e_uint_param :: proc(params: json.Array, i: int) -> (v: int, ok: bool) {
	if i >= len(params) {return 0, false}
	f, fok := params[i].(json.Float)
	if !fok || f < 0 {return 0, false}
	return int(f), true
}

@(private = "file")
e_string_param :: proc(params: json.Array, i: int) -> (v: string, ok: bool) {
	if i >= len(params) {return "", false}
	s, sok := params[i].(json.String)
	return string(s), sok
}

// e_hash_param decodes a 32-byte hash sent in display order (reversed),
// as Electrum sends both txids and scripthashes.
@(private = "file")
e_hash_param :: proc(params: json.Array, i: int) -> (h: [32]u8, ok: bool) {
	s, sok := e_string_param(params, i)
	if !sok {return {}, false}
	return txid_from_hex(s)
}

// e_hex_pub / e_is_hex_pub: shared with the esplora layer.
e_hex_pub :: proc(b: ^strings.Builder, data: []byte) {
	e_hex(b, data)
}

e_is_hex_pub :: proc(s: string) -> bool {
	return e_is_hex(s)
}

@(private = "file")
e_hex :: proc(b: ^strings.Builder, data: []byte) {
	HEXD := "0123456789abcdef"
	for by in data {
		strings.write_byte(b, HEXD[by >> 4])
		strings.write_byte(b, HEXD[by & 0xF])
	}
}

@(private = "file")
e_is_hex :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) % 2 != 0 {return false}
	for c in s {
		switch c {
		case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		case:
			return false
		}
	}
	return true
}

@(private = "file")
e_clone :: proc(s: string, allocator: runtime.Allocator) -> string {
	out, _ := clone_string(s, allocator)
	return out
}

@(private = "file")
e_json_escape :: proc(b: ^strings.Builder, s: string) {
	for c in s {
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r', '\t':
			strings.write_byte(b, ' ')
		case:
			if c >= 0x20 {
				strings.write_rune(b, c)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Esplora HTTP transport: minimal HTTP/1.1 on the same nbio loop and the
// same worker pool as the Electrum listener — one concurrency model for
// every consumer. Keep-alive with in-order pipelining (one request in
// flight per connection, the rest wait in the buffer).

ESPLORA_MAX_REQUEST :: 1 << 20 // headers + body cap (broadcast hex fits well within)

H_Conn :: struct {
	srv:      ^Electrum_Server,
	sock:     nbio.TCP_Socket,
	chunk:    [16384]byte,
	inbuf:    [dynamic]byte,
	outq:     [dynamic]byte,
	inflight: [dynamic]byte,
	sending:  bool,
	dead:     bool,
	busy:     bool,
	ops:      int,
}

esplora_http_start :: proc(srv: ^Electrum_Server, bind: string) -> (err: Error) {
	ep, ok := net.parse_endpoint(bind)
	if !ok {
		log.errorf("hrafnar: cannot parse esplora_bind %q (want ip:port)", bind)
		return Usage_Error.Bad_Config
	}
	sock, lerr := nbio.listen_tcp(ep)
	if lerr != nil {
		log.errorf("hrafnar: esplora cannot listen on %s: %v", bind, lerr)
		return Usage_Error.Bad_Config
	}
	srv.esplora_sock = sock
	srv.esplora_on = true
	nbio.accept_poly(srv.esplora_sock, srv, h_on_accept)
	log.infof("hrafnar: esplora HTTP API listening on %s", bind)
	return nil
}

@(private = "file")
h_on_accept :: proc(op: ^nbio.Operation, srv: ^Electrum_Server) {
	if op.accept.err != nil {
		if !srv.stopping {
			nbio.accept_poly(srv.esplora_sock, srv, h_on_accept)
		}
		return
	}
	client := op.accept.client
	nbio.accept_poly(srv.esplora_sock, srv, h_on_accept)
	if srv.conns >= ELECTRUM_MAX_CONNS {
		nbio.close(client)
		return
	}
	srv.conns += 1
	conn := new(H_Conn, srv.allocator)
	conn.srv = srv
	conn.sock = client
	conn.inbuf = make([dynamic]byte, srv.allocator)
	conn.outq = make([dynamic]byte, srv.allocator)
	conn.inflight = make([dynamic]byte, srv.allocator)
	srv.h_conns[conn] = {}
	h_arm_recv(conn)
}

@(private = "file")
h_arm_recv :: proc(conn: ^H_Conn) {
	conn.ops += 1
	nbio.recv_poly(conn.sock, {conn.chunk[:]}, conn, h_on_recv, timeout = ELECTRUM_IDLE_TIMEOUT * time.Minute)
}

@(private = "file")
h_on_recv :: proc(op: ^nbio.Operation, conn: ^H_Conn) {
	conn.ops -= 1
	if conn.dead {
		h_maybe_free(conn)
		return
	}
	n := op.recv.received
	if op.recv.err != nil || n == 0 {
		h_close(conn)
		return
	}
	append(&conn.inbuf, ..conn.chunk[:n])
	if len(conn.inbuf) > ESPLORA_MAX_REQUEST {
		h_close(conn)
		return
	}
	h_try_dispatch(conn)
	h_arm_recv(conn)
}

// h_try_dispatch parses one complete request off the buffer when the
// connection is idle, and hands it to the worker pool.
@(private = "file")
h_try_dispatch :: proc(conn: ^H_Conn) {
	if conn.busy || conn.dead {
		return
	}
	data := string(conn.inbuf[:])
	head_end := strings.index(data, "\r\n\r\n")
	if head_end < 0 {
		return
	}
	head := data[:head_end]
	line_end := strings.index(head, "\r\n")
	req_line := head if line_end < 0 else head[:line_end]
	parts := strings.fields(req_line, context.temp_allocator)
	if len(parts) < 2 {
		h_close(conn)
		return
	}
	method := parts[0]
	target := parts[1]
	if qi := strings.index_byte(target, '?'); qi >= 0 {
		target = target[:qi]
	}

	content_len := 0
	for hline in strings.split_iterator(&head, "\r\n") {
		ci := strings.index_byte(hline, ':')
		if ci < 0 {continue}
		if strings.equal_fold(strings.trim_space(hline[:ci]), "content-length") {
			if v, vok := strconv.parse_int(strings.trim_space(hline[ci + 1:]), 10); vok {
				content_len = v
			}
		}
	}
	if content_len < 0 || content_len > ESPLORA_MAX_REQUEST {
		h_close(conn)
		return
	}
	total := head_end + 4 + content_len
	if len(conn.inbuf) < total {
		return // body still arriving
	}
	body := string(conn.inbuf[head_end + 4:total])

	pool := conn.srv.pool
	if pool == nil {
		h_close(conn)
		return
	}
	m, _ := clone_string(method, pool.allocator)
	p, _ := clone_string(target, pool.allocator)
	bd, _ := clone_string(body, pool.allocator)

	rest := len(conn.inbuf) - total
	copy(conn.inbuf[:rest], conn.inbuf[total:])
	resize(&conn.inbuf, rest)

	conn.busy = true
	conn.ops += 1
	sync.mutex_lock(&pool.mu)
	append(&pool.jobs, E_Job{hconn = conn, line = p, http_method = m, http_body = bd})
	sync.mutex_unlock(&pool.mu)
	sync.sema_post(&pool.sem)
}

// h_complete applies a finished HTTP job on the loop thread.
@(private = "file")
h_complete :: proc(srv: ^Electrum_Server, d: ^E_Done) {
	conn := d.hconn
	conn.ops -= 1
	if conn.dead {
		h_maybe_free(conn)
		return
	}
	b := strings.builder_make(context.temp_allocator)
	reason := "OK"
	switch d.status {
	case 400:
		reason = "Bad Request"
	case 404:
		reason = "Not Found"
	case 405:
		reason = "Method Not Allowed"
	case 500:
		reason = "Internal Server Error"
	}
	fmt.sbprintf(
		&b,
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n",
		d.status,
		reason,
		d.ctype,
		len(d.resp),
	)
	append(&conn.outq, strings.to_string(b))
	append(&conn.outq, d.resp)
	conn.busy = false
	h_flush(conn)
	h_try_dispatch(conn) // pipelined request may already be buffered
}

@(private = "file")
h_flush :: proc(conn: ^H_Conn) {
	if !conn.srv.started {
		return
	}
	if conn.sending || len(conn.outq) == 0 {
		return
	}
	conn.inflight, conn.outq = conn.outq, conn.inflight
	clear(&conn.outq)
	conn.sending = true
	conn.ops += 1
	nbio.send_poly(conn.sock, {conn.inflight[:]}, conn, h_on_sent, timeout = ELECTRUM_SEND_TIMEOUT * 1e9)
}

@(private = "file")
h_on_sent :: proc(op: ^nbio.Operation, conn: ^H_Conn) {
	conn.ops -= 1
	conn.sending = false
	if conn.dead {
		h_maybe_free(conn)
		return
	}
	if op.send.err != nil {
		h_close(conn)
		return
	}
	clear(&conn.inflight)
	h_flush(conn)
}

@(private = "file")
h_close :: proc(conn: ^H_Conn) {
	if conn.dead {return}
	conn.dead = true
	conn.srv.conns -= 1
	delete_key(&conn.srv.h_conns, conn)
	nbio.close(conn.sock)
	h_maybe_free(conn)
}

@(private = "file")
h_maybe_free :: proc(conn: ^H_Conn) {
	if conn.ops > 0 {return}
	delete(conn.inbuf)
	delete(conn.outq)
	delete(conn.inflight)
	free(conn, conn.srv.allocator)
}
