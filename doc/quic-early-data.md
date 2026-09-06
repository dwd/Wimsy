# QUIC early authentication

Wimsy can send the XMPP stream opening and SASL2 FAST authentication before a
resumed QUIC handshake completes. Initial connections use the normal handshake.
TLS tickets persist in an encrypted file across process restarts. The client
configuration is shared across endpoint creation, and server
certificates are checked against the bundled Mozilla trust roots.

Early authentication requires a cached IAP configuration, a usable HT token,
an explicit FAST `tls-0rtt` advertisement, and durable counter storage. Password
authentication is never selected for the early-data path. The FAST counter is
incremented and flushed before sending; token replacement resets it. FAST
tokens and counters are stored together in the encrypted account store.

Only the transport-acquisition winner sends application bytes. Incoming XML is
held until the TLS handshake completes. If QUIC rejects early data, the client
discards the early control stream, opens a new one, and replays the bounded
initial flight once. An accepted flight is discarded from the replay buffer.
Handshake failure uses normal reconnection and does not impersonate a SASL
failure. No application stanzas are sent before resource binding.

The server must support TLS resumption and early data, advertise FAST early
authentication, and atomically reject duplicate or decreasing token counters
before processing inline binding/resumption. TLS acceptance alone is insufficient.

Loopback Rust tests exercise ticket reuse, acceptance, rejection and replacement
streams. Dart tests cover replay ordering, buffer bounds, durable counter
reservation, token rotation, and capability-cache updates.

## rustls 0.24 port

The vendored Quinn 0.11 forks use pinned rustls 0.24.0-dev.1 and its separate
rustls-ring 0.1.0-dev.1 provider. This is a local adapter port, not an upstream
Quinn release. It preserves our transport-parameter, acknowledgement-watermark
and in-flight statistics patches. The Rust workspace includes both forks so
their protocol and runtime unit suites can be run together.

The adapter retains partial TLS CRYPTO input, processes rustls output events in
order across encryption-level changes, and retains the TLS exporter after the
handshake. Peer certificate identities and error alerts use the new interfaces.
Only RFC QUIC v1 is advertised; obsolete pre-RFC drafts removed by rustls are
explicitly rejected. The optional platform-verifier convenience constructor now
loads native trust anchors into rustls's verifier, because the external 0.23
platform-verifier adapter is incompatible. Wimsy uses bundled Mozilla roots.

The pinned prerelease exposes `Tls13Session::encode` and `from_slice`. Its
encoding is treated as version-specific, never as a stable interchange format.

## Persistence and recovery

The ticket file is `quic-sessions.bin` beside the account database. Its random
256-bit AES-GCM key is stored inside the PIN-encrypted Hive box and flushed
before the ticket file is used. Each write uses a fresh random nonce. Neither
the key nor session secrets are logged. FAST's stable per-account SASL user-agent
ID is also persisted before authentication.

Tickets include their resumption secret, timing metadata and remembered QUIC
transport parameters. Entries are keyed by rustls's server name and security
configuration hash; the application uses fixed `xmpp-client` ALPN. The cache is
bounded to 64 security contexts, eight tickets per context and a 4 MiB file.

Rust locks a separate lock file, reloads the latest cache, then writes an
atomically replaced, synced encrypted file. A ticket is removed durably before
it is returned to TLS. This handles concurrent clients and crashes without
reusing a consumed ticket. If consumption cannot be committed, no ticket is
returned. Expired tickets, corrupted ciphertext, changed keys and incompatible
formats fall back to a full verified handshake. New tickets arrive through the
TLS session-store callback, including tickets issued after authentication.

A process-level integration test starts independent client processes against a
live loopback server and verifies accepted 0-RTT after restart, then full-handshake
fallback after ticket expiry, corruption, server-name changes and trust-store
changes. Additional tests cover concurrent
consumption, failed durable writes, encrypted Hive key recovery and stable
client identity. Provisional connections are explicitly closed on cancellation;
control-stream acquisition and replay have timeouts. A failed provisional
handshake penalizes its address so the next acquisition can choose another path. Token expiry during
acquisition closes the provisional connection instead of falling back to a
password in early data.
