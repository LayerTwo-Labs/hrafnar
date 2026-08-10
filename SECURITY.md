# Security Policy

## Reporting a vulnerability

Email **jacob@ecash.com**. Please do not open a public issue for
anything security-sensitive.

Include what you can of: the version (`hrafnar version`), platform, a
description of the issue, and reproduction steps or a proof of concept.
You'll get an acknowledgement as soon as the report is read, and a fix or
an honest assessment as fast as a small project can manage. Please allow a
reasonable window for a fix to ship before disclosing publicly.

## Supported versions

Pre-1.0, only the latest release is supported — fixes ship as a new
release, not as backports.

## Scope: what counts as security-sensitive here

hrafnar is trusted for **balance correctness** and can be exposed as a
**network service**. Reports in these areas are especially welcome:

- Anything that makes the index serve a **wrong balance, history, or
  proof** without erroring (silent corruption is the project's worst-case
  failure, per the design docs).
- Memory-safety or crash bugs reachable from the **Electrum TCP port** or
  the query socket — malformed JSON-RPC, oversized requests, protocol
  abuse. The Electrum server is designed to be exposable; bugs that make
  that unsafe are high priority.
- Resource-exhaustion attacks that a remote client can trigger despite
  the built-in guards (history caps, connection limits, idle timeouts).
- Corruption of the index by crafted data in a Bitcoin datadir (blk
  files are parsed as untrusted input — a malformed record must produce
  an error, never a panic or a bad row).

Out of scope: attacks requiring local access to the index directory
(file permissions are the boundary there), the absence of TLS on the
Electrum port (documented — front it with stunnel/nginx), and bugs in
bitcoind or wallets themselves.

## Keys and funds

hrafnar never holds, sees, or handles private keys or funds. It reads
public chain data and serves queries about it. The worst a compromised
hrafnar can do is lie about balances or leak which addresses you query —
both worth reporting, neither puts coins at direct risk.
