# TLS for hrafnar with Caddy

How to put TLS in front of both hrafnar endpoints with one process and one
certificate lifecycle:

| | public | proxied to |
|---|---|---|
| esplora HTTP API | `https://your.domain` (443) | `127.0.0.1:3000` |
| Electrum server | `your.domain:50002` (TLS) | `127.0.0.1:50001` |

hrafnar deliberately has no TLS in-process — it is a small amount of code with a
large amount of risk attached, and terminating it outside means certificate
renewal is somebody else's job. This is that somebody.

**Why bother:** the Electrum and esplora ports carry *which addresses a wallet is
asking about*. In plaintext that is visible to anyone on the path. Some wallets
(Bitkey among them) also refuse a non-SSL Electrum server outright.

**A note on Cloudflare:** it can serve the esplora half for free, but its proxy
only handles a fixed list of HTTP ports and 50002 is not among them — arbitrary
TCP needs Spectrum, which is Enterprise. It also means Cloudflare sees every
address every wallet queries, which is much of what running your own indexer was
meant to avoid.

---

## What you need first

- A domain pointing at the server (`dig +short your.domain` should return its IP).
- Ports **80** and **443** reachable, plus **50002**. Port 80 is needed for the
  ACME challenge even though nothing is served on it.
- hrafnar running, with its ports currently on `0.0.0.0` or `127.0.0.1` — both
  work; we move them to localhost at the end.

---

## 1. Build Caddy with the layer4 plugin

Stock Caddy speaks HTTP only. Electrum is raw TCP with TLS, which needs
[`caddy-l4`](https://github.com/mholt/caddy-l4). It is maintained by Caddy's
author but ships outside the core binary, so you build one that includes it.

```sh
# Caddy's apt repo provides both caddy and xcaddy
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-xcaddy.list
sudo apt update && sudo apt install -y caddy xcaddy

# Build a Caddy that includes layer4
xcaddy build --with github.com/mholt/caddy-l4

# Verify the modules are in there before replacing anything
./caddy list-modules | grep layer4 | head
```

That last check matters: if `layer4` modules are missing, the build silently
produced a stock Caddy and every step below will look like a config error.

Then swap it in:

```sh
sudo systemctl stop caddy
sudo mv ./caddy /usr/bin/caddy
sudo chmod +x /usr/bin/caddy
caddy version
```

Installing the `caddy` package first is deliberate: it creates the `caddy` user,
`/etc/caddy`, and a systemd unit with `AmbientCapabilities=CAP_NET_BIND_SERVICE`
so a non-root process can bind 80 and 443. Replacing only the binary keeps all
of that.

---

## 2. The Caddyfile

`/etc/caddy/Caddyfile` — replace `your.domain`:

```caddyfile
{
	# Electrum over TLS on the conventional SSL port. The `tls` handler
	# terminates; `proxy` forwards the decrypted stream to hrafnar.
	layer4 {
		:50002 {
			route {
				tls
				proxy 127.0.0.1:50001
			}
		}
	}
}

# esplora over HTTPS. Caddy obtains and renews the certificate itself, and
# the same certificate is what the layer4 listener above presents.
your.domain {
	reverse_proxy 127.0.0.1:3000
}
```

Reload and watch it start:

```sh
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl restart caddy
sudo journalctl -u caddy -f
```

The first start fetches a certificate; that takes a few seconds and logs
`certificate obtained successfully`.

---

## 3. Move hrafnar off the public ports

Now that Caddy is in front, the plaintext ports should not be reachable from
outside. In `hrafnar.config`:

```ini
electrum_bind = 127.0.0.1:50001
esplora_bind  = 127.0.0.1:3000
```

```sh
hrafnar stop && hrafnar daemon
```

Confirm nothing is listening publicly any more:

```sh
sudo ss -tlnp | grep -E '3000|50001|50002|443'
```

`127.0.0.1:3000` and `127.0.0.1:50001` are hrafnar; `:443` and `:50002` are
Caddy. If hrafnar still shows `0.0.0.0`, the config did not take.

---

## 4. Firewall

```sh
sudo ufw allow 80/tcp   comment 'ACME challenge'
sudo ufw allow 443/tcp  comment 'hrafnar esplora (TLS)'
sudo ufw allow 50002/tcp comment 'hrafnar Electrum (TLS)'

# the plaintext ports are no longer public
sudo ufw delete allow 3000/tcp
sudo ufw delete allow 50001/tcp

sudo ufw status numbered
```

---

## 5. Verify

```sh
# esplora over HTTPS
curl -s https://your.domain/blocks/tip/height

# Electrum over TLS — expect the hrafnar version string
printf '{"jsonrpc":"2.0","id":0,"method":"server.version","params":["probe","1.4"]}\n' \
  | openssl s_client -quiet -connect your.domain:50002 -servername your.domain 2>/dev/null \
  | head -1

# certificate is real and not self-signed
openssl s_client -connect your.domain:50002 -servername your.domain </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

**Then test with an actual wallet.** `openssl s_client` always sends SNI; some
clients do not, and Caddy selects certificates by SNI. A client that omits it
fails here where stunnel — which presents one fixed certificate regardless —
would have worked. This is the failure that only appears at connect time, so do
not skip it.

Point a wallet at `ssl://your.domain:50002` and confirm it syncs.

---

## If layer4 fights you

Combining TLS *automation* with `layer4` is the fiddly part of this setup;
there is a [dedicated issue thread](https://github.com/mholt/caddy-l4/issues/332)
on getting the Caddyfile syntax right. If it will not cooperate, stunnel does
the Electrum half reliably, reusing the certificate Caddy already manages:

```ini
# /etc/stunnel/stunnel.conf
[electrum]
accept  = 0.0.0.0:50002
connect = 127.0.0.1:50001
cert = /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/your.domain/your.domain.crt
key  = /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/your.domain/your.domain.key
```

Caddy keeps that certificate renewed, but **stunnel will not notice a renewal**.
Add a hook to restart it, or you will lose the Electrum port roughly 60 days
later with everything else still working:

```sh
# /etc/systemd/system/stunnel-reload.timer  (daily is plenty)
sudo systemctl restart stunnel4
```

stunnel also needs read access to those files — they are owned by `caddy` and
not world-readable by default.

Keep Caddy for esplora either way; that half is one line and needs no plugin.

---

## Troubleshooting

**`Connection refused` on 443** — nothing is listening. Caddy failed to start:
`sudo journalctl -u caddy -n 50`. Refused means the packet reached the box; a
*timeout* would point at the firewall instead. That distinction saves a lot of
time.

**Certificate never issues** — port 80 must be open and reachable from the
internet for the ACME HTTP challenge, and DNS must already point at this host.
Check with `dig +short your.domain` from somewhere else.

**Electrum connects but the wallet reports an SSL error** — usually SNI (above),
or the wallet pinning a self-signed certificate from an earlier setup. Try
removing and re-adding the server in the wallet.

**`layer4` modules missing** — `caddy list-modules | grep layer4`. If empty, the
`xcaddy build` did not include the plugin and you are running stock Caddy.

**esplora works, Electrum does not** — confirm hrafnar is actually serving
Electrum: `hrafnar logs` should show `electrum server listening on 127.0.0.1:50001`.
If `electrum = off` in the config, Caddy is proxying to nothing.
