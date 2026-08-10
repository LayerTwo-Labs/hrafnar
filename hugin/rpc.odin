package hugin

// Minimal Bitcoin Core JSON-RPC client: HTTP/1.1 POST over a local TCP
// connection, Basic auth from the datadir's .cookie file or explicit
// rpc_user/rpc_pass, one connection per request (mempool polls every
// couple of seconds; the overhead is irrelevant locally).
//
// Error tiers stay distinct: transport trouble is an os error, a
// malformed response is Corruption, and a JSON-RPC error object from the
// server is logged and surfaced as Usage_Error — a healthy transport
// carrying a fault.

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

Rpc_Client :: struct {
	endpoint:    net.Endpoint,
	auth:        string, // "Basic <b64>", owned; refreshed from the cookie on 401
	cookie_path: string, // owned; empty when user/pass auth is fixed
	configured:  bool,
	allocator:   runtime.Allocator,
}

// rpc_init resolves endpoint and credentials from the config. Auth
// precedence: explicit rpc_user/rpc_pass, else the .cookie file (given or
// derived as <datadir>/../.cookie — datadir points at blocks/).
rpc_init :: proc(rc: ^Rpc_Client, cfg: Config, allocator := context.allocator) -> (err: Error) {
	rc.allocator = allocator

	url := cfg.rpc_url
	if url == "" {
		url = "127.0.0.1:8332"
	}
	url = strings.trim_prefix(url, "http://")
	url = strings.trim_suffix(url, "/")
	ep, ok := net.parse_endpoint(url)
	if !ok {
		if addr, aok := net.parse_ip4_address(url); aok {
			ep = net.Endpoint {
				address = addr,
				port    = 8332,
			}
		} else {
			log.errorf("hugin: cannot parse rpc endpoint %q (want host:port)", url)
			return Usage_Error.Bad_Config
		}
	}
	if ep.port == 0 {
		ep.port = 8332
	}
	rc.endpoint = ep

	if cfg.rpc_user != "" {
		userpass := fmt.tprintf("%s:%s", cfg.rpc_user, cfg.rpc_pass)
		rc.auth = basic_auth_header(userpass, allocator)
	} else {
		cookie := cfg.rpc_cookie
		if cookie == "" {
			cookie = fmt.tprintf("%s/../.cookie", cfg.datadir)
		}
		perr: runtime.Allocator_Error
		rc.cookie_path, perr = clone_string(cookie, allocator)
		if perr != nil {
			return os.Error(perr)
		}
		if lerr := rpc_load_cookie(rc); lerr != nil {
			delete(rc.cookie_path, allocator)
			rc.cookie_path = ""
			return lerr
		}
	}
	rc.configured = true
	return nil
}

rpc_destroy :: proc(rc: ^Rpc_Client) {
	delete(rc.auth, rc.allocator)
	delete(rc.cookie_path, rc.allocator)
	rc^ = {}
}

@(private = "file")
rpc_load_cookie :: proc(rc: ^Rpc_Client) -> (err: Error) {
	data, rerr := os.read_entire_file(rc.cookie_path, context.temp_allocator)
	if rerr != nil {
		return rerr
	}
	delete(rc.auth, rc.allocator)
	rc.auth = basic_auth_header(strings.trim_space(string(data)), rc.allocator)
	return nil
}

@(private = "file")
basic_auth_header :: proc(userpass: string, allocator: runtime.Allocator) -> string {
	b64, _ := base64.encode(transmute([]byte)userpass, base64.ENC_TABLE, context.temp_allocator)
	out, _ := clone_string(fmt.tprintf("Basic %s", b64), allocator)
	return out
}

// rpc_call issues one JSON-RPC request. params is raw JSON (e.g.
// `["abc",true]`) or "" for none. Returns the parsed response envelope
// (free with json.destroy_value); pull the payload with rpc_result.
rpc_call :: proc(
	rc: ^Rpc_Client,
	method: string,
	params: string = "",
	allocator := context.allocator,
	intercept_errors := true, // false: return the error envelope for the caller to relay
) -> (
	envelope: json.Value,
	err: Error,
) {
	body := fmt.tprintf(
		`{{"jsonrpc":"1.0","id":1,"method":"%s","params":%s}}`,
		method,
		params if params != "" else "[]",
	)

	status, resp := rpc_http_post(rc, body) or_return
	if status == 401 && rc.cookie_path != "" {
		// bitcoind regenerates the cookie on restart: reload, retry once.
		rpc_load_cookie(rc) or_return
		status, resp = rpc_http_post(rc, body) or_return
	}
	if status != 200 && status != 500 {
		// bitcoind returns 500 with a JSON error body for RPC faults;
		// anything else is transport-level trouble.
		log.warnf("hugin: rpc %s: HTTP %d", method, status)
		return nil, Corruption.Bad_Record
	}

	parsed, perr := json.parse(resp, json.DEFAULT_SPECIFICATION, false, allocator)
	if perr != nil {
		return nil, Corruption.Bad_Record
	}
	obj, is_obj := parsed.(json.Object)
	if !is_obj {
		json.destroy_value(parsed, allocator)
		return nil, Corruption.Bad_Record
	}
	if eobj, has_err := obj["error"]; has_err && intercept_errors {
		if _, is_nil := eobj.(json.Null); !is_nil {
			emsg := "unknown"
			ecode: i64
			if em, eok := eobj.(json.Object); eok {
				if m, mok := em["message"].(string); mok {emsg = m}
				if c, cok := em["code"].(json.Float); cok {ecode = i64(c)}
			}
			log.warnf("hugin: rpc %s failed: %s (code %d)", method, emsg, ecode)
			json.destroy_value(parsed, allocator)
			return nil, Usage_Error.Rpc_Unavailable
		}
	}
	if _, has_res := obj["result"]; !has_res {
		json.destroy_value(parsed, allocator)
		return nil, Corruption.Bad_Record
	}
	return parsed, nil
}

// rpc_call_batch issues one HTTP request carrying many calls of the same
// method (JSON-RPC batch). The response is a JSON array whose elements
// carry "id" (the index into params_list) and "result". One round trip
// instead of thousands — this is what makes the initial mempool backfill
// tractable.
rpc_call_batch :: proc(
	rc: ^Rpc_Client,
	method: string,
	params_list: []string,
	allocator := context.allocator,
) -> (
	envelope: json.Value,
	err: Error,
) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for p, i in params_list {
		if i > 0 {strings.write_byte(&b, ',')}
		fmt.sbprintf(&b, `{{"jsonrpc":"1.0","id":%d,"method":"%s","params":%s}}`, i, method, p)
	}
	strings.write_byte(&b, ']')

	status, resp := rpc_http_post(rc, strings.to_string(b)) or_return
	if status == 401 && rc.cookie_path != "" {
		rpc_load_cookie(rc) or_return
		status, resp = rpc_http_post(rc, strings.to_string(b)) or_return
	}
	if status != 200 && status != 500 {
		log.warnf("hugin: rpc batch %s: HTTP %d", method, status)
		return nil, Corruption.Bad_Record
	}
	parsed, perr := json.parse(resp, json.DEFAULT_SPECIFICATION, false, allocator)
	if perr != nil {
		return nil, Corruption.Bad_Record
	}
	if _, is_arr := parsed.(json.Array); !is_arr {
		json.destroy_value(parsed, allocator)
		return nil, Corruption.Bad_Record
	}
	return parsed, nil
}

// rpc_result pulls the "result" field out of an rpc_call envelope. The
// value stays owned by the envelope.
rpc_result :: proc(envelope: json.Value) -> json.Value {
	if obj, ok := envelope.(json.Object); ok {
		return obj["result"]
	}
	return nil
}

// ---------------------------------------------------------------------------
// HTTP transport

@(private = "file")
rpc_http_post :: proc(rc: ^Rpc_Client, body: string) -> (status: int, resp: []byte, err: Error) {
	sock, derr := net.dial_tcp(rc.endpoint)
	if derr != nil {
		return 0, nil, os.Error(os.General_Error.Not_Exist)
	}
	defer net.close(sock)
	// A hung node must not hang the daemon's serve loop.
	net.set_option(sock, .Receive_Timeout, time.Second * 10)
	net.set_option(sock, .Send_Timeout, time.Second * 10)

	req := fmt.tprintf(
		"POST / HTTP/1.1\r\n" +
		"Host: %s\r\n" +
		"Authorization: %s\r\n" +
		"Content-Type: application/json\r\n" +
		"Content-Length: %d\r\n" +
		"Connection: close\r\n" +
		"\r\n%s",
		net.endpoint_to_string_allocator(rc.endpoint, context.temp_allocator),
		rc.auth,
		len(body),
		body,
	)
	data := transmute([]byte)req
	for len(data) > 0 {
		n, serr := net.send_tcp(sock, data)
		if serr != nil {
			return 0, nil, os.Error(os.General_Error.Broken_Pipe)
		}
		data = data[n:]
	}

	// Connection: close — read to EOF.
	buf := make([dynamic]byte, context.temp_allocator)
	chunk: [16384]byte
	for {
		n, rerr := net.recv_tcp(sock, chunk[:])
		if n > 0 {
			append(&buf, ..chunk[:n])
		}
		if rerr != nil || n == 0 {
			break
		}
	}
	if len(buf) < 12 {
		return 0, nil, Corruption.Truncated
	}

	// Status line: HTTP/1.1 NNN ...
	head := string(buf[:])
	sp := strings.index_byte(head, ' ')
	if sp < 0 || sp + 4 > len(head) {
		return 0, nil, Corruption.Bad_Record
	}
	code, cok := strconv.parse_int(head[sp + 1:sp + 4], 10)
	if !cok {
		return 0, nil, Corruption.Bad_Record
	}

	sep := strings.index(head, "\r\n\r\n")
	if sep < 0 {
		return 0, nil, Corruption.Truncated
	}
	return code, buf[sep + 4:], nil
}
