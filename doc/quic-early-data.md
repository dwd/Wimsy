# QUIC early authentication

Wimsy can send the XMPP stream opening and SASL2 FAST authentication before a
resumed QUIC handshake completes. Initial connections use the normal handshake.
TLS tickets currently live only in the Rust process. The client configuration
and its certificate verifier are shared across endpoint creation, and server
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
