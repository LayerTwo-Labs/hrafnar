package hugin_tests

// End-to-end Electrum socket test: real daemon thread, real TCP client.

import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import hugin "../../hugin"

Daemon_Box :: struct {
	cfg:  hugin.Config,
	err:  hugin.Error,
	done: bool,
}

daemon_thread :: proc(t: ^thread.Thread) {
	box := (^Daemon_Box)(t.data)
	// Deliberately temp-allocated: the daemon must copy it, because its
	// serve loop resets the temp allocator every cycle (regression: the
	// version string turned to garbage on the wire).
	version := fmt.tprintf("hrafnar %s", "sockettest")
	box.err = hugin.daemon_run(box.cfg, 1, version)
	sync.atomic_store(&box.done, true)
}

@(test)
test_electrum_socket :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbufA: [22]byte
	script_a := bb_script(0x8A, sbufA[:])

	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	_, _ = world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	box := Daemon_Box {
		cfg = w.cfg,
	}
	box.cfg.electrum = true
	box.cfg.electrum_bind = "127.0.0.1:43117"
	box.cfg.mempool_off = true

	th := thread.create(daemon_thread)
	th.data = &box
	th.init_context = context
	thread.start(th)
	defer {
		hugin.daemon_request_stop()
		defer hugin.daemon_clear_stop()
		thread.join(th)
		thread.destroy(th)
	}

	// Connect, retrying while the daemon starts up.
	sock: net.TCP_Socket
	connected := false
	for _ in 0 ..< 100 {
		s, derr := net.dial_tcp("127.0.0.1:43117")
		if derr == nil {
			sock = s
			connected = true
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, connected, "could not connect to electrum port")
	if !connected {return}

	req := "{\"id\":1,\"method\":\"server.version\",\"params\":[\"t\",\"1.4\"]}\n"
	sent, serr := net.send_tcp(sock, transmute([]byte)req)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, sent, len(req))

	buf: [4096]byte
	total := 0
	deadline := time.now()
	for total == 0 || buf[total - 1] != '\n' {
		if time.duration_seconds(time.since(deadline)) > 5 {
			break
		}
		n, rerr := net.recv_tcp(sock, buf[total:])
		if rerr != nil || n == 0 {
			break
		}
		total += n
	}
	resp := string(buf[:total])
	testing.expectf(
		t,
		strings.contains(resp, "hrafnar sockettest") && strings.contains(resp, `"id":1`),
		"unexpected response: %q",
		resp,
	)

	// A second request on the SAME connection: persistence.
	req2 := "{\"id\":2,\"method\":\"blockchain.headers.subscribe\"}\n"
	_, serr2 := net.send_tcp(sock, transmute([]byte)req2)
	testing.expect_value(t, serr2, nil)
	total = 0
	deadline = time.now()
	for total == 0 || buf[total - 1] != '\n' {
		if time.duration_seconds(time.since(deadline)) > 5 {
			break
		}
		n, rerr := net.recv_tcp(sock, buf[total:])
		if rerr != nil || n == 0 {
			break
		}
		total += n
	}
	resp2 := string(buf[:total])
	testing.expectf(
		t,
		strings.contains(resp2, `"height":1`),
		"unexpected headers.subscribe response: %q",
		resp2,
	)

	net.close(sock)
	// Let the daemon notice the disconnect and free the connection before
	// shutdown, so the tracking allocator sees no leaks.
	time.sleep(500 * time.Millisecond)
}

// Concurrency: several clients hammer the daemon at once; every request
// gets its own well-formed response with its own id.
@(private = "file")
Hammer_Box :: struct {
	port:    int,
	base_id: int,
	n:       int,
	got:     int,
	fail:    bool,
}

@(private = "file")
hammer_thread :: proc(t: ^thread.Thread) {
	box := (^Hammer_Box)(t.data)
	sock, derr := net.dial_tcp(fmt.tprintf("127.0.0.1:%d", box.port))
	if derr != nil {
		box.fail = true
		return
	}
	defer net.close(sock)
	buf: [8192]byte
	for i in 0 ..< box.n {
		id := box.base_id + i
		req := fmt.tprintf(`{{"id":%d,"method":"blockchain.headers.subscribe"}}` + "\n", id)
		if _, serr := net.send_tcp(sock, transmute([]byte)req); serr != nil {
			box.fail = true
			return
		}
		total := 0
		for total == 0 || buf[total - 1] != '\n' {
			n, rerr := net.recv_tcp(sock, buf[total:])
			if rerr != nil || n == 0 {
				box.fail = true
				return
			}
			total += n
		}
		want := fmt.tprintf(`"id":%d`, id)
		if !strings.contains(string(buf[:total]), want) {
			box.fail = true
			return
		}
		box.got += 1
	}
}

@(test)
test_electrum_concurrent_clients :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbufA: [22]byte
	script_a := bb_script(0x8B, sbufA[:])
	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	_, _ = world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	box := Daemon_Box {
		cfg = w.cfg,
	}
	box.cfg.electrum = true
	box.cfg.electrum_bind = "127.0.0.1:43119"
	box.cfg.mempool_off = true

	th := thread.create(daemon_thread)
	th.data = &box
	th.init_context = context
	thread.start(th)
	defer {
		hugin.daemon_request_stop()
		defer hugin.daemon_clear_stop()
		thread.join(th)
		thread.destroy(th)
	}

	// Wait for the listener.
	ready := false
	for _ in 0 ..< 100 {
		s, derr := net.dial_tcp("127.0.0.1:43119")
		if derr == nil {
			net.close(s)
			ready = true
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, ready, "electrum port never opened")
	if !ready {return}

	N_CLIENTS :: 4
	N_REQS :: 25
	boxes: [N_CLIENTS]Hammer_Box
	clients: [N_CLIENTS]^thread.Thread
	for i in 0 ..< N_CLIENTS {
		boxes[i] = Hammer_Box {
			port    = 43119,
			base_id = 1000 * (i + 1),
			n       = N_REQS,
		}
		clients[i] = thread.create(hammer_thread)
		clients[i].data = &boxes[i]
		clients[i].init_context = context
		thread.start(clients[i])
	}
	for i in 0 ..< N_CLIENTS {
		thread.join(clients[i])
		thread.destroy(clients[i])
	}
	for i in 0 ..< N_CLIENTS {
		testing.expectf(t, !boxes[i].fail, "client %d failed", i)
		testing.expect_value(t, boxes[i].got, N_REQS)
	}
	time.sleep(300 * time.Millisecond) // let disconnects settle before shutdown
}

// Fault containment: a request that PANICS inside a worker must yield an
// internal-error response — and the daemon must keep serving afterwards.
@(test)
test_worker_fault_containment :: proc(t: ^testing.T) {
	w: Catchup_World
	world_init(t, &w, 2)
	defer world_destroy(&w)

	sbufA: [22]byte
	script_a := bb_script(0x8C, sbufA[:])
	h0, _ := world_coinbase(t, &w, {}, script_a, 1)
	_, _ = world_coinbase(t, &w, h0, script_a, 2)
	world_flush(t, &w)
	testing.expect_value(t, hugin.build_index(w.cfg), nil)
	testing.expect_value(t, hugin.catchup_run(w.cfg), nil)

	box := Daemon_Box {
		cfg = w.cfg,
	}
	box.cfg.electrum = true
	box.cfg.electrum_bind = "127.0.0.1:43125"
	box.cfg.mempool_off = true

	th := thread.create(daemon_thread)
	th.data = &box
	// The fault handler rightly logs errors; the test runner would count
	// them as failures, so this daemon runs mute.
	quiet := context
	quiet.logger = log.nil_logger()
	th.init_context = quiet
	thread.start(th)
	defer {
		hugin.daemon_request_stop()
		defer hugin.daemon_clear_stop()
		thread.join(th)
		thread.destroy(th)
	}

	sock: net.TCP_Socket
	connected := false
	for _ in 0 ..< 100 {
		s, derr := net.dial_tcp("127.0.0.1:43125")
		if derr == nil {
			sock = s
			connected = true
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, connected, "could not connect")
	if !connected {return}

	read_line :: proc(sock: net.TCP_Socket, buf: []byte) -> string {
		total := 0
		deadline := time.now()
		for total == 0 || buf[total - 1] != '\n' {
			if time.duration_seconds(time.since(deadline)) > 5 {break}
			n, rerr := net.recv_tcp(sock, buf[total:])
			if rerr != nil || n == 0 {break}
			total += n
		}
		return string(buf[:total])
	}

	// The magic line trips a deliberate panic inside the worker.
	req := "__hrafnar_fault_injection__\n"
	_, serr := net.send_tcp(sock, transmute([]byte)req)
	testing.expect_value(t, serr, nil)
	buf: [4096]byte
	resp := read_line(sock, buf[:])
	testing.expectf(t, strings.contains(resp, "internal server error"), "fault response wrong: %q", resp)

	// Same connection must still work...
	req2 := "{\"id\":7,\"method\":\"server.ping\"}\n"
	_, serr2 := net.send_tcp(sock, transmute([]byte)req2)
	testing.expect_value(t, serr2, nil)
	resp2 := read_line(sock, buf[:])
	testing.expectf(t, strings.contains(resp2, `"id":7`), "post-fault request failed: %q", resp2)

	// ...and repeated faults must not exhaust the worker pool.
	for _ in 0 ..< 8 {
		_, _ = net.send_tcp(sock, transmute([]byte)string("__hrafnar_fault_injection__\n"))
		_ = read_line(sock, buf[:])
	}
	req3 := "{\"id\":8,\"method\":\"server.ping\"}\n"
	_, serr3 := net.send_tcp(sock, transmute([]byte)req3)
	testing.expect_value(t, serr3, nil)
	resp3 := read_line(sock, buf[:])
	testing.expectf(t, strings.contains(resp3, `"id":8`), "daemon unhealthy after repeated faults: %q", resp3)

	net.close(sock)
	time.sleep(300 * time.Millisecond)
}
