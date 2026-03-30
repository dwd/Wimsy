# Connection Robustness Improvements Plan

## Objective
Make TCP/XMPP connection establishment resilient across mixed IPv4/IPv6 networks and multi-record SRV DNS responses by:
- trying both address families with Happy Eyeballs behavior,
- trying multiple SRV targets (priority/weight aware), and
- producing deterministic, debuggable failover behavior.

## Current Behavior Review

### 1) SRV selection is single-target
- `lib/xmpp/srv_lookup_native.dart` collects SRV records, then `resolveXmppSrv()` returns exactly one `XmppSrvTarget` via `_pickSrvTarget(...)`.
- `lib/xmpp/xmpp_service.dart` consumes only that one target in `connect(...)` and sets one `account.host`/`account.port`.

Impact:
- if the selected SRV target is down/unreachable, we do not try other SRV records before failing.

### 2) Socket connection path is single-attempt per host
- `vendor/xmpp_stone/lib/src/connection/XmppWebsocketIo.dart` uses one `_tcpConnect(host, port)` call (default `Socket.connect`) for TCP, then optional TLS upgrade.
- No explicit Happy Eyeballs scheduling is implemented (no controlled A/AAAA racing with short delay).

Impact:
- behavior depends on platform DNS/stack ordering and timeout behavior.
- if the first family/path is slow or blackholed, connection can fail slowly or fail before alternate paths are attempted.

### 3) No composed failover strategy
- SRV choice and address-family choice are independent today, and both effectively single-shot from app perspective.

Impact:
- combined failure modes (bad first SRV + bad first family) are not handled robustly.

## Target Behavior

### 1) Build a ranked SRV attempt list (not a single pick)
- Resolve both `_xmpps-client._tcp` and `_xmpp-client._tcp` records.
- Preserve direct-TLS intent per record source (`_xmpps-client` => direct TLS, `_xmpp-client` => STARTTLS path).
- Convert SRV records into an **ordered attempt list**:
  - ascending `priority`,
  - weighted random selection **within each priority**, repeated without replacement (RFC 2782-style ordering for retries).
- Attempt each entry in order until one fully connects.

### 2) Per-SRV target: Happy Eyeballs for A/AAAA
For each SRV host:
- Resolve both A and AAAA addresses.
- Attempt connections in Happy Eyeballs style:
  - start first candidate immediately,
  - stagger alternate-family candidate after short delay (e.g. 200-300 ms),
  - continue through remaining addresses until one succeeds or all fail,
  - cancel in-flight losers when one succeeds.
- Apply this for plain TCP and direct TLS pre-handshake transport establishment.

### 3) Failover hierarchy
Connection attempts should proceed as:
1. current SRV target + Happy Eyeballs address attempts,
2. next SRV target + Happy Eyeballs,
3. continue until list exhausted,
4. if no SRV records exist, fallback to configured/manual host or domain defaults as today.

### 4) Error reporting and observability
- Track errors per attempted endpoint/address to avoid opaque "failed" states.
- Log:
  - SRV list and selected order,
  - address candidates per host,
  - winner family/address,
  - final failure summary with attempted endpoints.
- Surface condensed reason in existing connection error path.

## Proposed Implementation Phases

### Phase 1: SRV API and Ordering
Files:
- `lib/xmpp/srv_lookup_native.dart`
- `lib/xmpp/srv_lookup_stub.dart`
- `lib/xmpp/srv_lookup.dart`
- `lib/xmpp/xmpp_service.dart`

Changes:
- Add API returning multiple records (e.g. `resolveXmppSrvCandidates(String domain) -> List<XmppSrvTarget>`).
- Keep existing single-target helper temporarily for compatibility, but migrate `xmpp_service` to list-based flow.
- Implement deterministic weighted ordering helper and unit tests (seedable RNG for testability).

### Phase 2: Connection attempt model in `xmpp_stone`
Files:
- `vendor/xmpp_stone/lib/src/account/XmppAccountSettings.dart`
- `vendor/xmpp_stone/lib/src/Connection.dart`
- `vendor/xmpp_stone/lib/src/connection/XmppWebsocketApi.dart`
- `vendor/xmpp_stone/lib/src/connection/XmppWebsocketIo.dart`

Changes:
- Introduce endpoint attempt model (host, port, directTls, tlsHost).
- Let account/connection carry an ordered endpoint list for TCP mode.
- Update connect flow to iterate endpoints until success.
- Keep websocket flow unchanged.

### Phase 3: Happy Eyeballs connector utility
Files:
- new file under `vendor/xmpp_stone/lib/src/connection/` (e.g. `HappyEyeballsConnector.dart`)
- `vendor/xmpp_stone/lib/src/connection/XmppWebsocketIo.dart`

Changes:
- Implement address resolution + staggered racing with configurable delay and connect timeout.
- Reuse utility for plain TCP and direct TLS raw socket establishment.
- Preserve existing test injection pattern by allowing dependency injection for lookup/connect.

### Phase 4: Wire SRV failover end-to-end
Files:
- `lib/xmpp/xmpp_service.dart`
- vendor files from phases 2-3

Changes:
- Build endpoint attempt list in `xmpp_service.connect(...)` from SRV candidates.
- Pass full list into connection layer.
- Ensure direct TLS choice follows each SRV record, not only the first selected record.

### Phase 5: Tests

App tests (new):
- SRV ordering helper tests (priority + weighted-without-replacement behavior).
- `xmpp_service` tests that SRV candidates become endpoint attempt plan in expected order.

Vendor tests (new/expanded):
- `XmppWebsocketIo`:
  - IPv6 first fails, IPv4 succeeds within same host.
  - IPv4 first fails, IPv6 succeeds.
  - all addresses fail => host failure propagated.
- `Connection`:
  - first SRV endpoint fails, second succeeds.
  - direct TLS and STARTTLS endpoints both respected.

Regression tests:
- no behavioral change for websocket mode.
- existing reconnect behavior still triggers after forceful close.

### Phase 6: Cleanup and rollout
- Remove obsolete single-target SRV usage paths.
- Keep temporary compatibility wrappers only if needed for incremental landing.
- Land in small commits:
  1. SRV list + ordering,
  2. endpoint attempt model,
  3. Happy Eyeballs connector,
  4. integration + tests.

## Open Decisions to Confirm Before Implementation
1. Happy Eyeballs delay: choose default 250 ms unless you prefer a different value.
2. Per-address connect timeout: choose conservative default (e.g. 3-5 s) vs relying on OS timeout.
3. SRV ordering determinism: stable seed per connection attempt for reproducible logs/tests.
4. Whether to prefer `_xmpps-client` over `_xmpp-client` when priorities are equal across record sets, or strictly follow merged priority order.

## Definition of Done
- Connection attempt tries alternate IP family when first family path fails or stalls.
- Multiple SRV targets are attempted according to priority/weight ordering.
- Logs clearly show attempt sequence and final winner/failure.
- Test coverage demonstrates family fallback, SRV failover, and no websocket regression.
