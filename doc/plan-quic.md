# QUIC Transport Plan (Single Reliable Channel)

## Objective
Add QUIC transport for XMPP on IO platforms using `flutter_quic`, with one reliable bidirectional channel for the XML stream.

## Scope
In scope for this phase:
- QUIC endpoint discovery via SRV: `_xmpp-client._quic.<domain>`.
- QUIC transport implementation for mobile/desktop (non-web).
- One reliable channel carrying the full XMPP XML stream.
- Automatic transport selection based on SRV records.
- Connection fallback to existing TCP transport path when QUIC fails.
- Tests for discovery, endpoint planning, and connection fallback behavior.

Out of scope for this phase:
- Web support.
- Multi-channel QUIC usage.
- Partial reliability / datagram use.
- XEP-level changes beyond transport.
- UI transport toggles.

## Confirmed Decisions
- ALPN: `xmpp-client` (per XEP-0467 baseline).
- Selection mode: automatic from SRV, no UI toggle/opt-in gate.
- Preference: QUIC SRV should be preferred over TCP SRV.
- Fallback: if QUIC fails, fall back to TCP and continue through TCP SRV failover list.

## Current Baseline
- `XmppService.connect(...)` resolves SRV candidates and builds TCP endpoint plans.
- `Connection` currently opens WebSocket or TCP via `XmppWebSocket` abstraction.
- Transport handling is centralized enough to add a new endpoint class + attempt loop.

## Design Principles
- Keep QUIC additive and low-risk: no behavior changes for non-QUIC-capable servers.
- Preserve robust fallback: QUIC failure should not block TCP SRV failover.
- Reuse existing parser, buffering, reconnection, and feature negotiation logic.

## Proposed Architecture

### 1. Endpoint and account model
- Add `XmppQuicEndpoint` (host, port, tlsHost).
- Add account fields:
  - `List<XmppQuicEndpoint>? quicEndpoints`
- Keep existing `tcpEndpoints` and websocket config untouched.

### 2. SRV discovery and preference
- Extend SRV lookup to query `_xmpp-client._quic.<domain>`.
- Keep existing `_xmpps-client._tcp` and `_xmpp-client._tcp` lookups.
- Build separate ordered candidate lists per transport type.
- Connection attempt order:
  1. QUIC candidates (ordered by priority/weight)
  2. TCP candidates (existing SRV-based ordering/failover)

### 3. Connection planning in `XmppService`
- Build and assign both `quicEndpoints` and `tcpEndpoints` from SRV results.
- For hosts with no SRV data, keep current fallback behavior.
- Keep websocket path unchanged when explicitly selected (or on web).

### 4. QUIC transport adapter
- Add QUIC-backed transport class using `flutter_quic`:
  - connect with ALPN `xmpp-client`
  - open one reliable bidirectional stream
  - map incoming bytes to existing response handling
  - write outbound XML payloads
  - close cleanly
- Preserve existing buffering behavior above transport.

### 5. Integrate into `Connection.openSocket()`
- Attempt QUIC endpoints first (if present).
- On QUIC endpoint failure, try next QUIC endpoint.
- If all QUIC endpoints fail, continue with existing TCP endpoint loop.
- Keep per-endpoint logging and aggregated failure context.

### 6. Reconnection behavior
- Reconnection reuses same preference order (QUIC first, TCP fallback).
- No separate UI/runtime mode switching needed for this phase.

## Phased Implementation

### Phase 1: Data model updates
Files:
- `vendor/xmpp_stone/lib/src/account/XmppAccountSettings.dart`
- `lib/storage/account_record.dart` (if account transport data is persisted)

Deliverable:
- Account can carry QUIC endpoint candidates.

### Phase 2: SRV lookup extension
Files:
- `lib/xmpp/srv_lookup_native.dart`
- `lib/xmpp/srv_lookup_stub.dart`
- `lib/xmpp/srv_target.dart` (or new QUIC target type)

Deliverable:
- QUIC SRV candidates resolved and ordered.

### Phase 3: Endpoint planning in service
Files:
- `lib/xmpp/xmpp_service.dart`
- new helper (e.g. `lib/xmpp/quic_endpoint_plan.dart`)

Deliverable:
- Service prepares QUIC-first then TCP fallback endpoint plans.

### Phase 4: QUIC transport implementation
Files:
- new transport adapter under `vendor/xmpp_stone/lib/src/connection/`.
- `vendor/xmpp_stone/lib/src/Connection.dart` attempt loop updates.

Deliverable:
- XMPP stream can run over single-channel QUIC.

### Phase 5: Tests
Add tests in:
- `test/` for SRV parsing/planning (including QUIC priority).
- `vendor/xmpp_stone/test/` for connection fallback sequencing.

Minimum test cases:
- QUIC SRV discovered and preferred over TCP SRV.
- QUIC connection failure falls back to TCP endpoint 1 then endpoint 2.
- QUIC unavailable still uses current TCP/websocket behavior.
- Buffered writes still coalesce correctly over QUIC transport adapter.

### Phase 6: Validation
Required checks before commit:
- `flutter analyze`
- `flutter test`
- `cd vendor/xmpp_stone && dart test`

## Open Questions (With Suggested Defaults)
1. Should QUIC and TCP SRV priorities be merged into a single cross-transport priority table, or keep transport buckets with hard QUIC-first preference?
Suggested default: Keep transport buckets and hard QUIC-first preference (as requested), then priority/weight inside each bucket.

2. QUIC handshake timeout before fallback?
Suggested default: 3 seconds per QUIC endpoint attempt before moving on.

3. Certificate validation behavior for QUIC?
Suggested default: Match existing TLS hostname/cert checks used for TCP/TLS.

## Definition of Done
- Client can establish XMPP session over QUIC (single reliable channel) on IO platforms.
- SRV discovery supports `_xmpp-client._quic.<domain>`.
- QUIC SRV is preferred; QUIC failures fall back to TCP SRV failover.
- Existing non-QUIC behavior remains unchanged.
- Test and analysis suite passes.
