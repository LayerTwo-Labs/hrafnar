package hugin

// Daemon mode: a catch-up loop plus a Unix-socket query server in one
// process. The socket lives at <index_dir>/hrafnar.sock; each connection
// carries one request line and receives one response (see server.odin),
// then closes.
//
// Single-threaded by design: queries are answered between catch-up cycles,
// so there is no locking and no torn state. A query arriving mid-catch-up
// waits; catch-up on a synced chain takes well under a second.

import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:nbio"
import "core:sync"
import "core:thread"
import "core:sys/posix"
import "core:time"

SOCKET_NAME :: "hrafnar.sock"
PIDFILE_NAME :: "hrafnar.pid"
ERRFILE_NAME :: "hrafnar.err"

socket_path :: proc(index_dir: string) -> string {
	return fmt.tprintf("%s/%s", index_dir, SOCKET_NAME)
}

pidfile_path :: proc(index_dir: string) -> string {
	return fmt.tprintf("%s/%s", index_dir, PIDFILE_NAME)
}

// daemonize forks into the background: the parent returns child_pid > 0
// and should exit; the child returns 0 detached from the terminal. stdin
// comes from /dev/null; stdout and stderr append to <index>/hrafnar.err so
// a panic or assertion failure is never lost — the file logger carries
// normal output, this file carries only crash traces.
daemonize :: proc(index_dir: string) -> (child_pid: int, err: Error) {
	pid := posix.fork()
	if pid < 0 {
		return 0, os.Error(os.General_Error.Broken_Pipe)
	}
	if pid > 0 {
		return int(pid), nil
	}
	posix.setsid()
	devnull := posix.open(cstring("/dev/null"), {.RDWR})
	if devnull >= 0 {
		posix.dup2(devnull, 0)
	}
	// stdout/stderr go to the crash file — or, if it cannot be opened
	// (index dir missing on a first run), to /dev/null. They must NEVER
	// stay on the terminal: a detached child writing to the tty spams the
	// user's prompt and cannot be Ctrl-C'd.
	errpath := fmt.ctprintf("%s/%s", index_dir, ERRFILE_NAME)
	errfd := posix.open(errpath, {.WRONLY, .CREAT, .APPEND}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	out := errfd if errfd >= 0 else devnull
	if out >= 0 {
		posix.dup2(out, 1)
		posix.dup2(out, 2)
	}
	if errfd > 2 {
		posix.close(errfd)
	}
	if devnull > 2 {
		posix.close(devnull)
	}
	return 0, nil
}

// Build_Responder answers Unix-socket queries during the bootstrap build
// with a progress line instead of leaving them to time out.
@(private = "file")
Build_Responder :: struct {
	fd:   posix.FD,
	stop: bool, // atomic
}

@(private = "file")
build_responder_main :: proc(t: ^thread.Thread) {
	br := (^Build_Responder)(t.data)
	for !sync.atomic_load(&br.stop) {
		pfd := posix.pollfd {
			fd     = br.fd,
			events = {.IN},
		}
		n := posix.poll(&pfd, 1, 500)
		if n <= 0 || .IN not_in pfd.revents {
			continue
		}
		conn := posix.accept(br.fd, nil, nil)
		if conn < 0 {
			continue
		}
		sbuf: [160]byte
		status := build_status_get(sbuf[:])
		resp: string
		if len(status) > 0 {
			resp = fmt.tprintf("ERR index building: %s (tail hrafnar.log for detail)\n", status)
		} else {
			resp = "ERR index building (tail hrafnar.log for detail)\n"
		}
		send_all(conn, transmute([]byte)resp)
		posix.close(conn)
		free_all(context.temp_allocator)
	}
}

// daemon_request_stop asks a daemon running in this process to exit its
// serve loop — the in-process equivalent of SIGTERM, used by tests.
daemon_request_stop :: proc() {
	sync.atomic_store(&stop_requested, true)
}

// proc_rss_mb reports this process's resident memory. The OOM killer
// leaves nothing in our own logs — SIGKILL cannot be caught — so the only
// way memory growth becomes visible is to print it as we go.
proc_rss_mb :: proc() -> int {
	when ODIN_OS == .Linux {
		data, err := os.read_entire_file("/proc/self/statm", context.temp_allocator)
		if err != nil {
			return 0
		}
		fields := strings.fields(string(data), context.temp_allocator)
		if len(fields) < 2 {
			return 0
		}
		pages, ok := strconv.parse_int(fields[1], 10)
		if !ok {
			return 0
		}
		return pages * 4096 / (1024 * 1024) // statm is in pages
	} else {
		return 0
	}
}

// The run marker records that a daemon is alive; it is removed on a clean
// exit. Finding one at startup means the previous run was killed — by the
// OOM killer, a power loss, or SIGKILL — none of which can leave a note.
@(private = "file")
RUN_MARKER_NAME :: "hrafnar.running"

@(private = "file")
run_marker_path :: proc(index_dir: string) -> string {
	return fmt.tprintf("%s/%s", index_dir, RUN_MARKER_NAME)
}

@(private = "file")
run_marker_check_and_set :: proc(index_dir: string) {
	path := run_marker_path(index_dir)
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		log.warnf(
			"hrafnar: the previous run (%s) did not shut down cleanly — it was killed, not stopped. " +
			"If memory is the suspect, check: dmesg -T | grep -i 'killed process'",
			strings.trim_space(string(data)),
		)
	}
	_ = os.write_entire_file(path, transmute([]byte)fmt.tprintf("pid %d, started", posix.getpid()))
}

@(private = "file")
run_marker_clear :: proc(index_dir: string) {
	os.remove(run_marker_path(index_dir))
}

// daemon_clear_stop resets the shutdown flag. The daemon calls it on
// start so a previous in-process run cannot cancel this one, and tests
// call it to isolate from each other.
daemon_clear_stop :: proc() {
	sync.atomic_store(&stop_requested, false)
}

// daemon_stop signals a running daemon via its pidfile.
daemon_stop :: proc(index_dir: string) -> (err: Error) {
	data, rerr := os.read_entire_file(pidfile_path(index_dir), context.temp_allocator)
	if rerr != nil {
		log.errorf("hrafnar: no pidfile at %s — is a daemon running?", pidfile_path(index_dir))
		return rerr
	}
	pid, ok := strconv.parse_int(strings.trim_space(string(data)), 10)
	if !ok || pid <= 1 {
		return Corruption.Bad_Record
	}
	if posix.kill(posix.pid_t(pid), .SIGTERM) != .OK {
		log.errorf("hrafnar: cannot signal pid %d: %v (stale pidfile?)", pid, posix.errno())
		os.remove(pidfile_path(index_dir))
		return os.Error(os.General_Error.Not_Exist)
	}
	log.infof("hrafnar: sent SIGTERM to daemon (pid %d)", pid)
	return nil
}

@(private)
stop_requested: bool

// daemon_should_stop reports shutdown for one daemon instance. A caller
// supplying its own flag is isolated from the process-global entirely.
@(private = "file")
daemon_should_stop :: proc(stop: ^bool) -> bool {
	if stop != nil {
		return sync.atomic_load(stop)
	}
	return sync.atomic_load(&stop_requested)
}

// stop_was_requested is checked from long-running build/catch-up loops so
// SIGINT aborts promptly instead of being swallowed until serving starts.
@(private)
stop_was_requested :: proc "contextless" () -> bool {
	return sync.atomic_load(&stop_requested)
}

@(private = "file")
handle_stop_signal :: proc "c" (sig: posix.Signal) {
	sync.atomic_store(&stop_requested, true)
}

// Daemon_State_Snapshot captures what on-disk state a catch-up cycle can
// change; the open index is rebuilt only when it differs.
Daemon_State :: struct {
	cp_height:  u32,
	cp_hash:    [32]u8,
	recent_len: i64,
}

daemon_state_snapshot :: proc(cfg: Config) -> (s: Daemon_State) {
	h, hash, err := checkpoint_read(cfg.index_dir)
	if err == nil {
		s.cp_height = h
		s.cp_hash = hash
	}
	if info, serr := os.stat(fmt.tprintf("%s/%s", cfg.index_dir, RECENT_LOG_NAME), context.temp_allocator); serr == nil {
		s.recent_len = info.size
	}
	return
}

// daemon_run serves until SIGINT/SIGTERM. poll_seconds is the catch-up
// interval. With no index present it bootstraps one with a full bulk
// build before serving.
// stop: an optional per-instance shutdown flag. When supplied, this daemon
// watches ONLY that flag and never reads or writes the process-global one.
// That matters for in-process daemons (tests, embedders): the global is
// shared, so one daemon shutting down used to cancel unrelated catch-ups
// running concurrently — which is exactly how CI first went red.
// Production passes nil and is driven by SIGINT/SIGTERM through the global.
daemon_run :: proc(
	cfg: Config,
	poll_seconds: int = 30,
	version: string = "hrafnar",
	stop: ^bool = nil,
) -> (
	err: Error,
) {
	cfg := config_fill_defaults(cfg)
	if stop == nil {
		daemon_clear_stop()
	}
	poll_seconds := max(poll_seconds, 1)

	// First log line within milliseconds of start: the operator must never
	// wonder whether the process is alive.
	log.infof(
		"hrafnar: daemon starting (pid %d): index %s, datadir %s",
		posix.getpid(),
		cfg.index_dir,
		cfg.datadir,
	)

	// Refuse a second daemon on the same index. A bare connect probe: it
	// succeeds against any bound listener (even one busy building and not
	// yet accepting), and fails fast against a stale socket file.
	if socket_has_listener(cfg.index_dir) {
		log.errorf("hrafnar: a daemon is already serving %s", cfg.index_dir)
		return Usage_Error.Bad_Config
	}
	// The loop resets the temp allocator every iteration, and the deferred
	// cleanup below outlives all of them: the socket path needs a stable
	// allocation.
	spath, perr := clone_string(socket_path(cfg.index_dir), context.allocator)
	if perr != nil {
		return os.Error(perr)
	}
	defer delete(spath)
	os.remove(spath) // stale socket from an unclean shutdown

	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		log.errorf("hrafnar: cannot create socket: %v", posix.errno())
		return os.Error(os.General_Error.Invalid_File)
	}
	defer posix.close(fd)

	addr, alen, aok := make_unix_sockaddr(spath)
	if !aok {
		log.errorf("hrafnar: socket path too long: %s", spath)
		return Usage_Error.Bad_Config
	}
	if posix.bind(fd, cast(^posix.sockaddr)&addr, alen) != .OK {
		log.errorf("hrafnar: cannot bind %s: %v", spath, posix.errno())
		return os.Error(os.General_Error.Invalid_File)
	}
	defer os.remove(spath)
	if posix.listen(fd, 16) != .OK {
		log.errorf("hrafnar: cannot listen on %s: %v", spath, posix.errno())
		return os.Error(os.General_Error.Invalid_File)
	}

	posix.signal(.SIGINT, handle_stop_signal)
	posix.signal(.SIGTERM, handle_stop_signal)
	// A client that disconnects mid-response (Ctrl-C on the CLI) makes our
	// next socket write raise SIGPIPE, whose default action would kill the
	// whole daemon. Ignore it; write errors are handled at the call sites.
	posix.sigignore(.SIGPIPE)

	// Pidfile, so `hrafnar stop` can find us.
	ppath, pperr := clone_string(pidfile_path(cfg.index_dir), context.allocator)
	if pperr != nil {
		return os.Error(pperr)
	}
	defer delete(ppath)
	_ = os.write_entire_file(ppath, transmute([]byte)fmt.tprintf("%d\n", posix.getpid()))
	defer os.remove(ppath)

	// No checkpoint means no index: bootstrap with a full bulk build. The
	// socket is already bound, so a second daemon started meanwhile is
	// refused; queries during the build wait or time out and fall back.
	if _, _, cperr := checkpoint_read(cfg.index_dir); cperr != nil {
		log.infof(
			"hrafnar: no index at %s; running the initial bulk build (queries will be served once it completes)",
			cfg.index_dir,
		)
		responder := Build_Responder {
			fd = fd,
		}
		rth := thread.create(build_responder_main)
		rth.data = &responder
		rth.init_context = context
		thread.start(rth)
		berr := build_index(cfg)
		sync.atomic_store(&responder.stop, true)
		thread.join(rth)
		thread.destroy(rth)
		if berr != nil {
			if ue, is_ue := berr.(Usage_Error); is_ue && ue == .Cancelled {
				log.infof("hrafnar: interrupted during initial build; shutting down (delete %s before the next run)", cfg.index_dir)
				return nil
			}
			log.errorf(
				"hrafnar: initial build failed: %v (if a previous build was interrupted, delete %s and start again)",
				berr,
				cfg.index_dir,
			)
			return berr
		}
	}

	// First catch-up, then open the index for serving.
	run_marker_check_and_set(cfg.index_dir)
	defer run_marker_clear(cfg.index_dir)

	log.infof("hrafnar: reconciling chain state with the datadir (headers + tail scan; ~10-30s on a large chain)")
	// Index what is pending, but do NOT work off compaction debt here: the
	// servers are not listening yet, so a full sweep would delay opening the
	// Electrum and esplora ports by however long the backlog takes — 48
	// minutes on a large one, with every wallet down for the duration. The
	// catch-up runner picks the debt up on its first idle cycle, once we are
	// serving and a sweep can yield to arriving blocks.
	startup_yield := Yield_Check {
		fn = yield_always,
	}
	if cerr := catchup_run(cfg, nil, nil, &startup_yield); cerr != nil {
		if is_fatal_catchup_error(cerr) {
			return cerr
		}
		log.warnf("hrafnar: initial catch-up failed (will retry): %v", cerr)
	}
	log.infof("hrafnar: opening index databases")
	idx := index_open(cfg) or_return
	slot := Index_Slot {
		cur = idx,
	}
	// index_open returns ONE reference and the slot above takes it. The
	// serve loop keeps `idx` as its own handle and releases it on every
	// refresh, so it needs a reference of its own — without this second
	// acquire the first new block released the same generation twice
	// (once via the runner's index_slot_swap, once via the loop) and the
	// daemon read through freed mmaps and database handles.
	index_acquire(idx)
	defer index_release(idx) // the loop's handle, whichever generation it holds
	defer index_slot_swap(&slot, nil) // releases the slot's generation

	log.infof(
		"hrafnar: daemon serving %s (tip %d), watching for new blocks (fallback poll every %ds)",
		spath,
		index_tip_height(idx),
		poll_seconds,
	)


	// bitcoind RPC: the mempool tier syncs through it, and the Electrum
	// server needs it for broadcast and fee estimation. Failure degrades
	// gracefully to confirmed-only data.
	mp: Mempool
	mp_ptr: ^Mempool
	rc: Rpc_Client
	rc_ptr: ^Rpc_Client
	rpc_src: Rpc_Mempool_Source
	if !cfg.mempool_off || cfg.electrum {
		if rerr := rpc_init(&rc, cfg); rerr == nil {
			rc_ptr = &rc
		} else {
			log.warnf("hrafnar: cannot set up bitcoind rpc (%v); mempool/broadcast unavailable", rerr)
		}
	}
	mp_runner: Mempool_Runner
	if !cfg.mempool_off && rc_ptr != nil {
		mempool_init(&mp)
		rpc_src = Rpc_Mempool_Source{rc = rc_ptr}
		mp_ptr = &mp
		log.infof("hrafnar: mempool tracking via rpc %v", rc.endpoint)
	}
	defer if mp_runner.thread != nil {mempool_runner_stop(&mp_runner)}
	if mp_ptr != nil {
		mempool_runner_start(&mp_runner, mp_ptr, &slot, rpc_mempool_source(&rpc_src))
	}

	cu_runner: Catchup_Runner
	defer if cu_runner.thread != nil {catchup_runner_stop(&cu_runner)}
	catchup_runner_start(&cu_runner, cfg, &slot, poll_seconds)
	defer if mp_ptr != nil {
		mempool_destroy(&mp)
	}
	defer if rc_ptr != nil {
		rpc_destroy(&rc)
	}

	// Electrum server: shares this thread via the nbio event loop.
	es_ctx: Electrum_Ctx
	es: Electrum_Server
	es_active := false
	nbio_acquired := false
	serve_nbio := cfg.electrum || cfg.esplora
	// The caller's version/banner may be temp-allocated; the serve loop
	// resets temp every cycle, so the ctx needs stable copies.
	version_owned, _ := clone_string(version, context.allocator)
	defer delete(version_owned)
	banner_owned, _ := clone_string(
		cfg.electrum_banner if cfg.electrum_banner != "" else version,
		context.allocator,
	)
	defer delete(banner_owned)
	if serve_nbio {
		if aerr := nbio.acquire_thread_event_loop(); aerr != nil {
			log.errorf("hrafnar: electrum/esplora disabled: cannot init event loop: %v", aerr)
		} else {
			nbio_acquired = true
			es_ctx = Electrum_Ctx {
				idx         = idx,
				mp          = mp_ptr,
				rc          = rc_ptr,
				banner      = banner_owned,
				version     = version_owned,
				max_history = cfg.electrum_max_history,
			}
			electrum_server_init(&es, &es_ctx)
			es.started = true
			es_active = true
			pool := new(E_Pool)
			electrum_pool_start(
				pool,
				&slot,
				mp_ptr,
				rc_ptr,
				banner_owned,
				version_owned,
				cfg.electrum_max_history,
				nbio.current_thread_event_loop(),
				cfg.query_workers,
			)
			es.pool = pool
			log.infof("hrafnar: %d query workers", cfg.query_workers)
			if cfg.electrum {
				if eserr := electrum_listen(&es, cfg.electrum_bind); eserr != nil {
					log.errorf("hrafnar: electrum listener failed: %v", eserr)
				}
			}
			if cfg.esplora {
				if herr := esplora_http_start(&es, cfg.esplora_bind); herr != nil {
					log.errorf("hrafnar: esplora listener failed: %v", herr)
				}
			}
		}
	}
	defer if nbio_acquired {nbio.release_thread_event_loop()}

	for !daemon_should_stop(stop) {
		if es_active {
			// The nbio tick serves Electrum connections and paces the
			// loop; the Unix socket is then polled without blocking.
			nbio.tick(200 * time.Millisecond)
		}
		pfd := posix.pollfd {
			fd     = fd,
			events = {.IN},
		}
		n := posix.poll(&pfd, 1, 0 if es_active else 1000)
		if n > 0 && .IN in pfd.revents {
			conn := posix.accept(fd, nil, nil)
			if conn >= 0 {
				if es.pool != nil {
					electrum_pool_submit_unix(es.pool, conn)
				} else {
					serve_connection(idx, mp_ptr, conn)
				}
			}
		}
		if es_active {
			electrum_pool_drain(&es)
		}

		// The mempool syncs on its own thread (mempool.odin): its RPC
		// round-trips must never occupy the thread that writes responses.
		// Here we only pick up what changed and push notifications.
		if es_active && mp_runner.thread != nil {
			mp_touched := make(map[[32]u8]struct {}, context.temp_allocator)
			if mempool_runner_take(&mp_runner, &mp_touched) {
				electrum_notify(&es, &mp_touched)
			}
		}

		// Catch-up runs on its own thread (catchup.odin): indexing a new
		// block must not stop the daemon from serving. Here we only adopt
		// its result — the freshly opened index generation — and push.
		if cu_runner.thread != nil {
			if fatal, ferr := catchup_runner_fatal(&cu_runner); fatal {
				return ferr
			}
			cu_touched := make(map[[32]u8]struct {}, context.temp_allocator)
			tip_changed, reorg, refreshed := catchup_runner_take(&cu_runner, &cu_touched)
			if refreshed {
				// The runner already swapped the slot; adopt it for the
				// loop's own use (push notifications read through es_ctx).
				new_idx := index_slot_get(&slot)
				if new_idx != idx {
					index_release(idx)
					idx = new_idx
					es_ctx.idx = idx
				} else {
					index_release(new_idx)
				}
			}
			if es_active && tip_changed {
				electrum_notify_headers(&es)
				electrum_notify(&es, &cu_touched, reorg)
			}
		}
		free_all(context.temp_allocator)
	}

	if es_active {
		// Close the listener, let workers finish, apply their leftovers,
		// then give in-flight nbio operations a few ticks to complete.
		electrum_stop(&es)
		if es.pool != nil {
			electrum_pool_stop(es.pool)
			electrum_pool_drain(&es)
		}
		for _ in 0 ..< 5 {
			nbio.tick(20 * time.Millisecond)
		}
		if es.pool != nil {
			free(es.pool)
		}
		electrum_server_destroy(&es)
	}
	log.infof("hrafnar: daemon shutting down")
	return nil
}

// Tip_Watch detects new block data with one stat per tick: Core appends
// every new block to the highest-numbered blk file (or starts the next
// one), so watching that file's size plus the next file's existence
// catches everything within a second — no full poll needed.
Tip_Watch :: struct {
	newest_path:  string, // owned
	next_path:    string, // owned
	newest_size:  i64,
	newest_mtime: time.Time,
}

tip_watch_destroy :: proc(w: ^Tip_Watch) {
	delete(w.newest_path)
	delete(w.next_path)
	w^ = {}
}

tip_watch_refresh :: proc(w: ^Tip_Watch, cfg: Config) {
	tip_watch_destroy(w)
	files, err := blkfile_enumerate(cfg.datadir, context.temp_allocator)
	if err != nil || len(files) == 0 {
		return
	}
	newest := files[len(files) - 1]
	w.newest_path, _ = clone_string(newest.path, context.allocator)
	w.next_path, _ = clone_string(
		fmt.tprintf("%s/blk%05d.dat", cfg.datadir, newest.file_no + 1),
		context.allocator,
	)
	if info, serr := os.stat(w.newest_path, context.temp_allocator); serr == nil {
		w.newest_size = info.size
		w.newest_mtime = info.modification_time
	}
	for &f in files {
		delete(f.path, context.temp_allocator)
	}
}

tip_watch_changed :: proc(w: ^Tip_Watch) -> bool {
	if w.newest_path == "" {
		return false
	}
	if info, serr := os.stat(w.newest_path, context.temp_allocator); serr == nil {
		// Size ALONE is not enough. Core preallocates blk files in 16 MiB
		// chunks, so appending a block usually writes into space the file
		// already had and the size does not move — only every ~16 MiB does
		// it jump. Modification time changes on every append, so it is the
		// signal that actually tracks blocks. Watching size only meant this
		// returned false for most blocks, which was invisible while a 30s
		// fallback poll covered it — and became visible the moment a
		// compaction sweep started relying on it to yield.
		if info.size != w.newest_size || info.modification_time != w.newest_mtime {
			return true
		}
	}
	if _, serr := os.stat(w.next_path, context.temp_allocator); serr == nil {
		return true // Core rolled over to a new blk file
	}
	return false
}

// A reorg past the horizon means the index must not serve at all; anything
// else (Core mid-write, transient IO) is retried.
is_fatal_catchup_error :: proc(err: Error) -> bool {
	ue, is_ue := err.(Usage_Error)
	return is_ue && ue == .Reorg_Too_Deep
}

serve_connection :: proc(idx: ^Index, mp: ^Mempool, conn: posix.FD) {
	defer posix.close(conn)

	buf: [1024]byte
	total := 0
	for total < len(buf) {
		n := posix.recv(conn, &buf[total], c.size_t(len(buf) - total), {})
		if n <= 0 {
			break
		}
		total += int(n)
		if buf[total - 1] == '\n' {
			break
		}
	}
	if total == 0 {
		return
	}

	if mp != nil {
		sync.rw_mutex_shared_lock(&mp.lock)
	}
	response := serve_request(idx, mp, string(buf[:total]), context.temp_allocator)
	if mp != nil {
		sync.rw_mutex_shared_unlock(&mp.lock)
	}
	send_all(conn, transmute([]byte)response)
}

@(private = "file")
send_all :: proc(conn: posix.FD, data: []byte) {
	data := data
	for len(data) > 0 {
		n := posix.send(conn, raw_data(data), c.size_t(len(data)), {})
		if n <= 0 {
			return
		}
		data = data[n:]
	}
}

@(private = "file")
make_unix_sockaddr :: proc(path: string) -> (addr: posix.sockaddr_un, len_: posix.socklen_t, ok: bool) {
	if len(path) + 1 > len(addr.sun_path) {
		return {}, 0, false
	}
	when ODIN_OS != .Linux {
		addr.sun_len = u8(size_of(posix.sockaddr_un))
	}
	addr.sun_family = posix.sa_family_t(posix.AF.UNIX)
	for b, i in transmute([]byte)path {
		addr.sun_path[i] = c.char(b)
	}
	return addr, posix.socklen_t(size_of(posix.sockaddr_un)), true
}

// socket_has_listener reports whether anything is bound to the index's
// socket. connect() to a stale socket file fails immediately.
@(private = "file")
socket_has_listener :: proc(index_dir: string) -> bool {
	spath := socket_path(index_dir)
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return false
	}
	defer posix.close(fd)
	addr, alen, aok := make_unix_sockaddr(spath)
	if !aok {
		return false
	}
	return posix.connect(fd, cast(^posix.sockaddr)&addr, alen) == .OK
}

// ---------------------------------------------------------------------------
// Client side.

// daemon_query sends one request to a running daemon. ok=false when no
// daemon answers (caller falls back to opening the index directly).
daemon_query :: proc(
	index_dir: string,
	request: string,
	allocator := context.allocator,
) -> (
	response: string,
	ok: bool,
) {
	// No stat pre-check: os.stat cannot handle socket files, and connect
	// fails fast on a missing or dead socket anyway.
	spath := socket_path(index_dir)
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return "", false
	}
	defer posix.close(fd)

	// A daemon mid-bulk-build accepts connections but answers nothing for
	// a long time; time out rather than hang the CLI, which then falls
	// back to opening the index directly (or reports it's not built yet).
	timeout := posix.timeval {
		tv_sec = 10,
	}
	posix.setsockopt(fd, posix.SOL_SOCKET, .RCVTIMEO, &timeout, size_of(timeout))
	posix.setsockopt(fd, posix.SOL_SOCKET, .SNDTIMEO, &timeout, size_of(timeout))

	addr, alen, aok := make_unix_sockaddr(spath)
	if !aok {
		return "", false
	}
	if posix.connect(fd, cast(^posix.sockaddr)&addr, alen) != .OK {
		return "", false
	}

	line := fmt.tprintf("%s\n", request)
	send_all(fd, transmute([]byte)line)

	// The daemon closes the connection after its response: read to EOF.
	out := make([dynamic]byte, allocator)
	buf: [4096]byte
	for {
		n := posix.recv(fd, &buf[0], len(buf), {})
		if n <= 0 {
			break
		}
		append(&out, ..buf[:n])
	}
	if len(out) == 0 {
		delete(out)
		return "", false
	}
	return string(out[:]), true
}
