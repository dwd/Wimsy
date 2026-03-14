# MAM Reliability Extraction + Test Plan

## Purpose
Stabilize MAM behavior by extracting MAM logic from `XmppService` into independently testable units before changing behavior. The target is to diagnose and fix the reported issue where pagination appears to drop middle history and only show earliest + latest ranges.

## Problem Statement
Observed behavior:
- Fetching older messages is unreliable.
- Cache appears to lose or collapse messages.
- Resulting history often contains an earliest segment and a latest segment, with gaps in the middle.

Constraints for this phase:
- No trial-and-error production fixes.
- Build a deterministic test harness first.
- Keep extraction behavior-preserving initially.

## Current MAM Flow (Supporting Notes)
Primary code locations in `lib/xmpp/xmpp_service.dart`:
- Entry points:
  - `selectChat()` -> `_requestMamOnOpen()` / `_requestRoomMamOnOpen()` (~1006-1075, ~7074+).
  - `requestOlderMessages()` paging logic (~1022-1075).
- Query dispatch:
  - `_requestMamInitial()` (~7094-7115).
  - `_runMamCatchUpStep()` (~7122-7187).
  - `_requestRoomMam()` (~6448-6472).
- Message insertion/dedupe/merge:
  - `_addMessage()` / `_addRoomMessage()` (~5440-5774).
  - `_mergeMamIdsIntoExisting()` (~6256+).
  - `_insertMessageOrdered()` (~5812+).
- Paging/catch-up state:
  - `_mamBackfillAt`, `_mamPageRequestAt`, `_mamCatchUpAt`, `_mamCatchUpPending`, `_mamPrependOffset`, timers (~177-184).
  - `_startMamPrepend()` 2-second offset window (~7189-7197).
- Cursor helpers:
  - `oldestMamIdFor()` / `latestMamIdFor()` and room equivalents (~490-560).

## Key Risk Hypotheses To Validate
1. Cursor selection by timestamp instead of archive order:
- `oldestMamIdFor` / `latestMamIdFor` choose by local `timestamp`, not strict MAM order.
- Delayed/offline messages or skewed server delay stamps may produce incorrect anchors.

2. Aggressive merge heuristic collapsing distinct messages:
- `_mergeMamIdsIntoExisting()` merges by `(from,to,body,oob,outgoing)` within a 2-minute window when IDs are missing.
- This can accidentally coalesce multiple distinct messages with similar content/time.

3. Prepend offset lifetime too short for real network latency:
- `_startMamPrepend()` resets `_mamPrependOffset` after 2 seconds.
- Late-arriving results from the same page may stop being prepended and instead be inserted by timestamp ordering.

4. Mixed anchor semantics (`before` vs `beforeId`, `after` vs `afterId`) with seeded caches:
- Query mode switches on `_seededMessageJids` / `_seededRoomMessageJids`.
- Incorrect seeded-state transitions can request wrong ranges.

5. Catch-up loop completion heuristic:
- `_runMamCatchUpStep()` repeats only if `latestMamId` changed after 2s timer.
- If response advances partial IDs but local latest selection is unstable, loop may terminate early.

## Extraction Targets (Behavior-Preserving First)
Create focused units with narrow interfaces:

1. `MamQueryPlanner` (pure)
- Inputs: current scope state, seeded mode, cursor IDs, request type (`initial`, `older`, `catchup`).
- Output: query plan (`jid/toJid`, `max`, `before/after/beforeId/afterId`).

2. `MamCursorStore` (stateful, testable)
- Owns per-scope request throttles, prepend offsets, catch-up pending states, timer policy.
- Exposes deterministic state transitions.

3. `MamMergeEngine` (pure)
- Owns merge/dedupe rules now in `_addMessage`, `_addRoomMessage`, `_mergeMamIdsIntoExisting`.
- Input: existing list + incoming event.
- Output: explicit change-set (insert/update/no-op + reason).

4. `MamCoordinator` (stateful orchestration)
- Drives planner + cursor store + query adapter + merge engine.
- No direct UI dependencies.
- `XmppService` becomes adapter/wiring layer.

5. `MamQueryAdapter` (thin boundary)
- Wraps `connection.getMamModule().queryById(...)`.
- Makes outbound query calls observable in tests.

## Test Strategy
### Layer 1: Pure Unit Tests
Target: planner + merge engine.
- No timers, no async, no xmpp connection.
- Exhaustive table-driven tests.

### Layer 2: State Machine Tests
Target: cursor store + coordinator with fake clock/timers.
- Deterministic fake clock.
- Verifies throttle windows, catch-up transitions, prepend windows.

### Layer 3: Coordinator + Fake MAM Transport
Target: end-to-end MAM behavior without real network.
- Fake transport captures query requests and allows scripted paged responses.
- Validates cursor progression, gap-free growth, and no accidental message collapse.

### Layer 4: XmppService Wiring Regression
- Minimal integration tests to ensure extraction wiring preserves existing behavior.

## Required Test Fixtures / Fakes
1. `FakeClock` and `FakeScheduler`
- Control `DateTime.now()` and timer firing.

2. `FakeMamTransport`
- Records each query.
- Allows injecting response pages out-of-order/late.

3. `MamMessageFactory`
- Generates deterministic messages with configurable:
  - `mamId`, `stanzaId`, `messageId`
  - `timestamp` vs archive order mismatches
  - duplicate bodies, duplicate timestamps

4. `ScopeHarness`
- DM and room scope wrappers with same assertions.

## Core Test Matrix
### A. Pagination Correctness (Older)
- A1: Repeated older fetch returns contiguous pages with no gaps.
- A2: Late page response still prepends correctly.
- A3: Duplicate page response is idempotent.
- A4: Seeded mode (`beforeId`) and non-seeded mode (`before`) both walk backwards correctly.

### B. Catch-Up Correctness (Newer)
- B1: Catch-up from latest cursor appends all unseen messages.
- B2: Catch-up stops only when truly exhausted.
- B3: Seeded (`afterId`) and non-seeded (`after`) both correct.

### C. Merge/Dedupe Safety
- C1: Same logical message reflected live+MAM merges IDs without duplication.
- C2: Two distinct messages with same body within 2 minutes do NOT collapse.
- C3: Room reflected echoes do not remove middle messages.
- C4: `stanzaId`/`mamId` dedupe does not cross sender scope improperly.

### D. Cursor Robustness
- D1: Anchor choice robust to timestamp skew.
- D2: Missing IDs fallback behavior is stable.
- D3: Cursor never regresses after successful page.

### E. Timer/Throttle Behavior
- E1: Request throttles prevent bursts but allow expected retries.
- E2: Prepend window does not expire mid-page.
- E3: Catch-up loop timer cannot terminate while pending page still in flight.

### F. Reported Failure Reproduction
Build a deterministic repro scenario:
- Load mid-history cache.
- Simulate older paging with delayed/misaligned timestamps and duplicate body content.
- Verify whether current merge + cursor rules collapse middle pages.
- Preserve this scenario as a permanent regression test before behavior changes.

## Invariants To Assert In Tests
- Message count monotonicity:
  - Older/catch-up fetch should never reduce total count unless explicit prune policy says so.
- Cursor monotonicity:
  - `oldest` moves backward or stays, `latest` moves forward or stays.
- Idempotence:
  - Replaying same MAM page does not mutate final state.
- Ordering stability:
  - Sorting/insertion yields deterministic order under equal timestamps.
- Scope isolation:
  - DM and room cursors/state cannot cross-contaminate.

## Proposed Implementation Sequence
1. Baseline characterization tests (against existing behavior) in an isolated harness.
2. Extract `MamQueryPlanner` (no behavior change) + tests.
3. Extract `MamMergeEngine` + tests, including known risky merge-window cases.
4. Extract `MamCursorStore` + deterministic timer tests.
5. Introduce `MamCoordinator` and adapt `XmppService`.
6. Add high-level regression test reproducing current failure pattern.
7. Only after green baseline + repro, implement targeted behavior fixes.

## Candidate Fixes (After Extraction, Not Now)
- Replace timestamp-based cursor selection with archive-order-aware strategy.
- Narrow or remove body/time heuristic merges unless corroborated by stronger identity signals.
- Replace fixed 2s prepend reset with in-flight page token tracking.
- Track request/response correlation IDs and page completion explicitly.

## Observability / Debugging Notes
Add structured debug events in coordinator tests and optional runtime logging:
- Query planned/sent (`scope`, `direction`, anchors, mode).
- Page received (`count`, first/last IDs).
- Merge decisions (`insert/update/skip`, reason).
- Cursor transitions (before/after).
- Timer transitions (scheduled/cancelled/fired).

This will make future field bug reports diagnosable without guessing.

## Acceptance Criteria For This Planning Track
- MAM logic extracted behind testable boundaries.
- Reproducible failing scenario encoded as an automated test.
- Deterministic tests covering pagination, catch-up, merge safety, timer behavior, and seeded/non-seeded modes.
- No production behavior changes introduced until tests are in place and baseline is understood.

## Open Questions
- Does server behavior differ for `before`/`after` vs `beforeId`/`afterId` across target deployments enough to require per-server policy?
- Should we persist explicit archive cursors separately from message timestamps/IDs?
- Do we need a hard policy for equal-timestamp ordering (e.g., secondary sort by mam-id)?
