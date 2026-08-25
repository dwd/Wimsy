# QUIC Migration Plan

# doc/plan-quic-migration.md

## Objective
Allow a live QUIC XMPP connection to survive a network-path change (Wi-Fi → cellular, IPv4 → IPv6, etc.) by leveraging QUIC's built-in connection migration (RFC 9000 §9) instead of immediately tearing down and rebuilding the XMPP session.

## Background
The server side (Quinn-based) already supports migration with `ServerConfig::migration = true` and a 600 s idle timeout (per XEP-0467). The client endpoint (`vendor/flutter_quic/rust/src/core/endpoint.rs`) already sets `max_idle_timeout = 600s` and `keep_alive_interval = 240s`. QUIC itself handles PATH_CHALLENGE / PATH_RESPONSE at the transport layer; no application-level framing is needed.

## Scope
**In scope:**
- Detecting a network-interface change on the client.
- Attempting QUIC connection migration (Quinn handles this transparently when the UDP socket is rebound to the new interface).
- Falling back to a full XMPP reconnect if migration fails or is not viable.
- Exposing a `rebind` API in `flutter_quic` so the Dart layer can ask Quinn to migrate to the current local address.
- Logging migration outcomes (success, failure, latency via PATH_CHALLENGE frame stats).
- Tests for the migration probe/fallback logic.

**Out of scope:**
- Proactive multi-path (sending on two paths simultaneously).
- WebSocket or TCP migration.
- iOS/Android background-mode network monitoring (handled by existing `connectivity_plus` listener).

## Current Baseline
- `lib/main.dart` subscribes to `connectivity_plus` `onConnectivityChanged` **on Android only**, then calls `XmppService.handleConnectivityChange(online)`.
- `XmppService.handleConnectivityChange` calls `requestReconnect(reason: networkChanged, immediate: true)` — a full tear-down every time.
- `QuicCapableXmppSocket` (`lib/xmpp/quic_xmpp_socket.dart`) holds a `QuicConnection` object with a direct reference to the underlying Quinn connection.
- `QuicConnection.local_ip()` is already exposed in the Rust layer (`vendor/flutter_quic/rust/src/core/connection.rs` line 108).
- `QuicFrameStats.path_challenge` and `path_response` counters are already surfaced via `getQuicStats()`.
- `quinn::Endpoint::rebind()` exists in Quinn 0.11 and is available in the vendored copy — it atomically swaps the underlying UDP socket, triggering an automatic PATH_CHALLENGE on the new path.

## Key Decisions
 Decision | Choice | Rationale |
---|---|---|
 Migration trigger | On `onConnectivityChanged`, attempt migration first; reconnect only on failure | Preserves XMPP session, avoids SASL re-auth |
 Migration mechanism | Expose `endpoint.rebind(newSocket)` from Quinn via `flutter_quic` FFI | Quinn handles PATH_CHALLENGE internally once the socket is rebound |
 Migration success detection | Wait up to 2 s for `path_challenge` RX frame counter to increase; if it does, declare success | Low-overhead; reuses existing `connectionStats()` call |
 Migration failure fallback | Call existing `requestReconnect(networkChanged)` path | No change to reconnect logic |
 iOS coverage | Extend `connectivity_plus` subscription from Android-only to all IO platforms | Needed for iPhone Wi-Fi ↔ cellular |

## Proposed Changes

### 1. `vendor/flutter_quic` — Rust layer
- Add `pub fn rebind_to_current_address(&self) -> Result<(), QuicError>` in `rust/src/core/endpoint.rs`: creates a fresh UDP socket bound to the unspecified address on the same address family, then calls `self.inner.rebind(new_socket)`.
- Add a corresponding `#[frb]` bridge function `endpoint_rebind_to_current_address` in `rust/src/api/bridge.rs`.
- Hand-add the Dart declaration `endpointRebindToCurrentAddress` in `lib/src/rust/api/bridge.dart`.
- Update `frb_generated.dart` / `frb_generated.io.dart` with the new codec wiring.

### 2. `lib/xmpp/quic_xmpp_socket.dart`
- Add `enum MigrationResult { success, failed }`.
- Add `Future<MigrationResult> attemptMigration()` method:
    - Returns `failed` immediately if not QUIC or endpoint is null.
    - Reads current `path_challenge` RX counter from `getQuicStats()`.
    - Calls `endpointRebindToCurrentAddress(endpoint: _endpoint!)`.
    - Polls `getQuicStats()` every 200 ms for up to `migrationProbeTimeout` (default 2 s), returning `success` as soon as the `path_challenge` counter increments.
    - Returns `failed` on timeout or FFI exception.
- Add `@visibleForTesting` `migrationProbeTimeout` constructor parameter for fast test override.

### 3. `lib/xmpp/xmpp_service.dart`
- Modify `handleConnectivityChange(bool online)` to:
    1. If the active socket is `QuicCapableXmppSocket`, call `socket.attemptMigration()`.
    2. On `MigrationResult.success`, retain the session without an XMPP IQ
       probe. The successful PATH_CHALLENGE/datagram observation already
       proves the rebound path, while IQ response routing across XEP-0467
       streams cannot safely drive a connection-failure timeout.
    3. On `MigrationResult.failed` or non-QUIC transport, keep existing `requestReconnect(networkChanged)` path.
    4. Log migration start/success/failure via `debugPrint`.

### 4. `lib/main.dart`
- Remove `Platform.isAndroid` guard around `_connectivitySubscription`; subscribe on all non-web IO platforms.

### 5. Tests
- `test/quic_migration_test.dart`:
    - `attemptMigration()` returns `success` when fake stats show `path_challenge` RX increment.
    - `attemptMigration()` returns `failed` on timeout.
    - `attemptMigration()` returns `failed` immediately when `_useQuic == false`.
    - `handleConnectivityChange` does NOT call `requestReconnect` on QUIC migration success.
    - `handleConnectivityChange` DOES call `requestReconnect` on migration failure.

## File Summary
 File | Change |
---|---|
 `vendor/flutter_quic/rust/src/core/endpoint.rs` | Add `rebind_to_current_address()` |
 `vendor/flutter_quic/rust/src/api/bridge.rs` | Add FFI bridge function |
 `vendor/flutter_quic/lib/src/rust/api/bridge.dart` | Add `endpointRebindToCurrentAddress` declaration |
 `vendor/flutter_quic/lib/src/rust/frb_generated.*` | Add codec wiring for new function |
 `lib/xmpp/quic_xmpp_socket.dart` | Add `MigrationResult` enum and `attemptMigration()` |
 `lib/xmpp/xmpp_service.dart` | Try migration before reconnect |
 `lib/main.dart` | Remove Android-only guard |
 `test/quic_migration_test.dart` | New migration tests |

## Definition of Done
- On Android and iOS, switching from Wi-Fi to cellular while using QUIC triggers PATH_CHALLENGE and keeps the XMPP session open.
- If migration fails within 2 s, a full reconnect occurs (existing behaviour).
- `flutter analyze`, `flutter test`, and `dart test` (in `vendor/xmpp_stone` and `vendor/flutter_quic`) all pass.

# Delivery Steps

###   Step 1: Write doc/plan-quic-migration.md (done)
The file `doc/plan-quic-migration.md` exists and contains the full QUIC connection migration plan.

- Create `doc/plan-quic-migration.md` with all sections: Objective, Background, Scope, Current Baseline, Key Decisions table, Proposed Changes (Rust layer rebind API, `attemptMigration()` in `QuicCapableXmppSocket`, `handleConnectivityChange` migration-first logic, iOS platform guard removal in `main.dart`), File Summary table, Definition of Done.
- The file content is the plan document only — no source code is modified in this stage.

###   Step 2: Add `endpointRebindToCurrentAddress` to the Rust/FFI layer
The Rust `QuicEndpoint` gains a `rebind_to_current_address()` method and the corresponding flutter_rust_bridge glue is in place so Dart can call it.

- Add `pub fn rebind_to_current_address(&self) -> Result<(), QuicError>` to `vendor/flutter_quic/rust/src/core/endpoint.rs`: binds a fresh UDP socket on an unspecified address for the right address family, then calls `self.inner.rebind(new_socket)`.
- Add a matching `#[frb]` bridge function `endpointRebindToCurrentAddress` to `vendor/flutter_quic/rust/src/api/bridge.rs`.
- Update the hand-written Dart bridge declarations in `vendor/flutter_quic/lib/src/rust/api/bridge.dart` to expose the new `endpointRebindToCurrentAddress` function via `RustLib.instance.api`.
- Update `vendor/flutter_quic/lib/src/rust/frb_generated.dart` and `frb_generated.io.dart` with the generated codec wiring for the new function.

###   Step 3: Implement `attemptMigration()` in `QuicCapableXmppSocket`
`QuicCapableXmppSocket` has an `attemptMigration()` method that calls the rebind FFI and polls for PATH_CHALLENGE acknowledgement.

- Add `enum MigrationResult { success, failed }` (top-level) in `lib/xmpp/quic_xmpp_socket.dart`.
- Add `Future<MigrationResult> attemptMigration()` that:
    - Returns `MigrationResult.failed` immediately if `_useQuic` is false or `_endpoint` is null.
    - Reads the current `path_challenge` counter from `getQuicStats()`.
    - Calls `endpointRebindToCurrentAddress(endpoint: _endpoint!)`.
    - Polls `getQuicStats()` every 200 ms for up to 2 s, returning `success` as soon as the `path_challenge` RX counter has incremented.
    - Returns `failed` on timeout or on any FFI exception.
- Add `@visibleForTesting` constructor parameter `migrationProbeTimeout` (default 2 s) so tests can set a short timeout.

###   Step 4: Update `handleConnectivityChange` and extend platform coverage in `main.dart`
On a network change the client attempts QUIC migration before falling back to a full reconnect; the connectivity listener now fires on all non-web IO platforms.

- In `lib/xmpp/xmpp_service.dart`, modify `handleConnectivityChange(bool online)`:
    - Cast the active socket to `QuicCapableXmppSocket` when the socket type indicates QUIC.
    - Call `socket.attemptMigration()` and await the result.
    - On `MigrationResult.success`, retain the session without an XMPP IQ
      probe and skip the full `requestReconnect`.
    - On `MigrationResult.failed` or non-QUIC socket, preserve the existing `requestReconnect(reason: networkChanged, immediate: true)` call.
    - Add `debugPrint` log lines for migration attempt start, success, and failure.
- In `lib/main.dart`, remove the `Platform.isAndroid` guard around the `onConnectivityChanged` subscription so iOS (and other IO platforms) also trigger migration.

###   Step 5: Add tests and commit
Unit tests cover all new migration behaviours; `flutter analyze` and `flutter test` pass; the changes are committed.

- Create `test/quic_migration_test.dart` with tests for:
    - `attemptMigration()` returns `success` when a fake `getQuicStats()` stub increments the `path_challenge` RX counter within the timeout.
    - `attemptMigration()` returns `failed` when the counter never changes (timeout path).
    - `attemptMigration()` returns `failed` immediately when `_useQuic == false`.
    - `handleConnectivityChange` does NOT call `requestReconnect` when `attemptMigration()` returns `success`.
    - `handleConnectivityChange` DOES call `requestReconnect` when `attemptMigration()` returns `failed`.
- Run `flutter analyze`, `flutter test`, and the dart tests in `vendor/xmpp_stone` to confirm zero regressions.
- Commit all changed files (`doc/plan-quic-migration.md`, Rust/FFI files, `quic_xmpp_socket.dart`, `xmpp_service.dart`, `main.dart`, `test/quic_migration_test.dart`) with a clear headline and detailed commit message describing what was changed and how it was tested.
