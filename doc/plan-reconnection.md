# Reconnection Consolidation Plan

## Objective
Consolidate reconnection behavior into a single implementation in `xmpp_stone` so reconnect scheduling, stream resumption, and retry backoff are owned by one state machine. Keep `xmpp_service` focused on application policy inputs and UI/status projection.

## Current Risk Summary
- Reconnection logic is currently split between:
  - `lib/xmpp/xmpp_service.dart` (`_scheduleReconnect`, `_tryResumeStream`, `_attemptReconnect`)
  - `vendor/xmpp_stone/lib/src/ReconnectionManager.dart`
- Keepalive failures from service and forceful-close handling in library can both trigger reconnect paths.
- Two independent timers/schedulers increase risk of duplicate reconnect attempts and unstable state transitions.

## Policy Decisions (Confirmed)
1. Auto-reconnect should run in both foreground and background.
2. Authentication failure should halt auto-reconnection.
3. Retry attempts should be unbounded.
4. Backoff cap should be 10 minutes.
5. Add jitter of approximately ±25% to reconnect delay.
6. On network change (offline -> online), retry immediately.

## Target Ownership Model
- `xmpp_stone` owns:
  - reconnect scheduling and timers
  - resume-first behavior (XEP-0198)
  - reconnect backoff/jitter policy execution
  - reconnection state transitions and attempt accounting
- `xmpp_service` owns:
  - feeding context (network/app lifecycle/user intent)
  - translating reconnection state into app status/UI messages
  - explicit user-initiated connect/disconnect flows

## Phased Implementation

### Phase 1: Define Contract and Guardrails
- Add a design note documenting reconnection state transitions and ownership boundaries.
- Define a single reconnect trigger path for all failure signals (keepalive timeout, forceful close, stream errors).
- Clarify terminal vs recoverable failures:
  - terminal: auth failures
  - recoverable: transport/socket closures, keepalive timeouts

Deliverables:
- Design doc + API sketch in repository.
- No behavior changes yet.

### Phase 2: Build Unified Reconnect Controller in `xmpp_stone`
- Replace or subsume `ReconnectionManager` with a policy-driven controller owned by `Connection`.
- Add a reconnection API surface (names indicative):
  - `setReconnectPolicy(...)`
  - `setReconnectContext({ networkOnline, allowAutoReconnect })`
  - `requestReconnect(reason, { shortTimeout = false, immediate = false })`
  - `reconnectStateStream`
- Enforce single active reconnect timer.
- Implement exponential backoff with:
  - unbounded attempts
  - max delay 10 minutes
  - jitter approximately ±25%
- Ensure network transition to online can force immediate retry.

Deliverables:
- Unified controller implementation.
- Reconnection state stream/events exposed via `Connection`.

### Phase 3: Centralize Resume + Retry Decisions in `xmpp_stone`
- Move resume-first decisioning fully into library controller:
  - if resumable + forced close => try resume path first
  - on resume failure, continue with scheduled reconnect
- Route keepalive failure handling into same controller path (not a separate scheduler).
- Treat auth failures as terminal stop condition for auto-reconnect.

Deliverables:
- One decision engine for resume/reconnect.
- Terminal failure handling enforced in one place.

### Phase 4: Remove Service-Side Scheduler
- Remove from `xmpp_service`:
  - `_reconnectTimer`
  - `_reconnectAttempt`
  - `_scheduleReconnect`
  - `_tryResumeStream`
  - `_attemptReconnect`
- Replace with:
  - context updates into `Connection` reconnect controller
  - listeners to `reconnectStateStream` for UI/status updates
- Keep manual `connect()` and explicit `disconnect()` semantics unchanged.

Deliverables:
- `xmpp_service` no longer runs its own reconnect timing logic.

### Phase 5: Regression Tests
Add targeted tests at both layers.

`xmpp_stone` tests:
- forceful close => single scheduled reconnect
- multiple failure signals => deduped single scheduled attempt
- backoff growth with jitter bounded to ±25%
- delay cap at 10 minutes
- unbounded retries continue past previous fixed limits
- auth failure halts further auto-reconnect
- network offline suspends retries; online triggers immediate retry
- resume-first path then fallback to reconnect

App/service tests:
- explicit user disconnect does not auto-reconnect
- service reflects reconnect state transitions correctly
- keepalive failure triggers reconnect via library path only

Deliverables:
- New/updated test suites proving no duplicate scheduler behavior.

### Phase 6: Cleanup and Observability
- Remove dead reconnection code and obsolete fields/config in both layers.
- Add structured debug logging for:
  - reconnect reason
  - computed delay (including jitter)
  - attempt count
  - terminal-stop reasons
- Ensure docs and comments reflect final architecture.

Deliverables:
- Final cleaned implementation with operational visibility.

## Rollout Notes
- Prefer landing in small commits per phase to limit blast radius.
- During migration, keep temporary compatibility guards only where required.
- Verify interaction with existing keepalive consolidation and SM resume flow before removing old code paths.

## Validation Requirements (per AGENTS.md)
Before each commit:
- `flutter analyze`
- `flutter test`
- `cd vendor/xmpp_stone && dart test`
