# SASL2 (XEP-0388) Implementation Plan

## Objective
Implement SASL2 (XEP-0388) for client authentication in `xmpp_stone` and integrate it into Wimsy's existing connection flow, while keeping the design ready for follow-on work on Bind2 (XEP-0386), FAST, IAP, and related modern features.

## Scope
In scope for this plan:
- SASL2 stream feature parsing and mechanism negotiation.
- SASL2 auth exchange (`<authenticate/>`, `<challenge/>`, `<response/>`, `<success/>`, `<failure/>`).
- No stream restart after SASL2 success.
- Feature negotiation continuation after SASL2 success.
- Backward-compatible fallback to existing SASL1 flow.
- Tests for parser, negotiation state flow, and failure handling.

Out of scope for this phase:
- Full Bind2 implementation.
- FAST token issuance/consumption.
- IAP task handling.
- SASL channel-binding support changes (track as follow-up).

## Current Baseline (Code Reality)
- SASL is currently handled by `SaslAuthenticationFeature` with SASL1 namespace and messages.
- On auth success, `Connection` transitions to `Authenticated`, which currently triggers `_openStream()` (stream restart behavior).
- Resource binding is currently a separate RFC 6120 bind negotiator (`BindingResourceConnectionNegotiator`) based on `<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>`.
- Negotiation is queue-driven in `ConnectionNegotiatorManager` and keyed by stream features/nonzas.

Implication: SASL2 requires changes to both auth wire format and connection state semantics.

## Protocol Notes (XEP-0388)
- Namespace: `urn:xmpp:sasl:2`.
- Stream feature element: `<authentication/>` (not `<mechanisms/>`).
- Success semantics: server sends `<success/>` and then fresh `<stream:features/>`; no stream restart.
- Extensibility points to preserve now: `<inline/>`, `<continue/>`, and task flow (`<next/>`, `<task-data/>`).

## Design Principles
- Keep SASL1 and SASL2 side-by-side initially to reduce rollout risk.
- Centralize auth protocol differences behind a versioned/auth-profile abstraction.
- Avoid implementing optional SASL2 extensions in this phase, but do not block them architecturally.
- Preserve existing behavior for servers that only advertise SASL1.

## Phased Plan

### Phase 1: Introduce SASL Profile Abstraction
Files:
- `vendor/xmpp_stone/lib/src/features/sasl/SaslAuthenticationFeature.dart`
- new: `vendor/xmpp_stone/lib/src/features/sasl/SaslProfile.dart` (or equivalent)

Changes:
- Add explicit auth profile selection: `sasl1`, `sasl2`.
- Parse both:
  - SASL1: `<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>`
  - SASL2: `<authentication xmlns='urn:xmpp:sasl:2'/>`
- Keep mechanism preference logic shared.

Deliverable:
- Negotiator can detect and choose SASL2 when offered, with fallback to SASL1.

### Phase 2: Add SASL2 Wire Handlers
Files:
- new: `vendor/xmpp_stone/lib/src/features/sasl/Sasl2AuthHandler.dart`
- optionally new shared helpers for SASL message encoding/decoding
- existing SASL handlers updated only where code reuse is beneficial

Changes:
- Implement SASL2 client messages:
  - `<authenticate mechanism='...'>`
  - optional `<initial-response/>`
- Handle server nonzas in `urn:xmpp:sasl:2`:
  - `<challenge/>`, `<success/>`, `<failure/>`
  - parse and store optional `additional-data` and `authorization-identifier`
- For this phase, treat `<continue/>` as unsupported-but-recognized (fail with explicit reason and telemetry).

Deliverable:
- Successful SASL2 auth for PLAIN/SCRAM mechanisms on servers not requiring tasks.

### Phase 3: Fix Post-Auth State Machine (No Restart)
Files:
- `vendor/xmpp_stone/lib/src/Connection.dart`
- `vendor/xmpp_stone/lib/src/features/ConnectionNegotatiorManager.dart`
- possibly `vendor/xmpp_stone/lib/src/features/Negotiator.dart` state hooks

Changes:
- Remove unconditional stream reopen on `Authenticated` for SASL2 sessions.
- Ensure incoming post-auth `<stream:features/>` is consumed by negotiator pipeline without restart.
- Keep current restart behavior for SASL1.
- Add clear state transition markers/logging (e.g. `AuthenticatedSasl2AwaitingFeatures`).

Deliverable:
- Correct SASL2 transition from auth success to next features and bind/session negotiation.

### Phase 4: Prepare Inline-Feature Extension Points
Files:
- `vendor/xmpp_stone/lib/src/features/sasl/...`
- `vendor/xmpp_stone/lib/src/features/ConnectionNegotatiorManager.dart`

Changes:
- Parse `<inline/>` advertisement under SASL2 `<authentication/>` and expose as typed capability set.
- Define pluggable interface for inline requests/results (without implementing Bind2/SM inline behavior yet).
- Ensure data model can carry inline outcomes from `<success/>` into later negotiators.

Deliverable:
- Minimal extension API so Bind2/FAST/IAP work does not require redesign.

### Phase 5: Error Handling and Fallback Rules
Files:
- `vendor/xmpp_stone/lib/src/features/sasl/...`
- `vendor/xmpp_stone/lib/src/Connection.dart`

Changes:
- Clear policy for unsupported SASL2 task flow (`<continue/>`, `<task-data/>`): explicit auth failure message and terminal stop.
- If SASL2 negotiation fails before mechanism attempt due to capability mismatch, optionally retry SASL1 only when server advertises SASL1 in the same features set.
- Keep auth failure semantics consistent with reconnection policy.

Deliverable:
- Predictable behavior across mixed/legacy deployments.

### Phase 6: Tests
Add/expand tests in `vendor/xmpp_stone/test`:
- SASL2 feature parsing:
  - detects mechanisms from `<authentication/>`
  - captures `<inline/>` entries
- SASL2 message generation:
  - `<authenticate/>` format with/without initial response
- SASL2 success path:
  - no stream restart
  - subsequent features are negotiated
- SASL2 failure path:
  - `<failure/>` handling
  - `<continue/>` unsupported path gives explicit failure
- Compatibility:
  - SASL1-only server path unchanged
  - dual-advertised server prefers configured/default profile

App-level confidence checks:
- Existing Flutter integration tests continue passing.
- No regressions in connection/reconnection flows tied to auth states.

## Implementation Order (Recommended)
1. Phase 1 + tests for parser/profile selection.
2. Phase 2 + tests for wire messages and success/failure parsing.
3. Phase 3 + state-machine tests (critical correctness).
4. Phase 4 scaffolding (inline model).
5. Phase 5 fallback/error policy.
6. Full regression run (`flutter analyze`, `flutter test`, `cd vendor/xmpp_stone && dart test`).

## Open Questions (With Suggested Defaults)
1. Should SASL2 be preferred when both SASL1 and SASL2 are advertised?
Suggested default: Yes, prefer SASL2 by default behind a temporary account-level override flag.

2. What should we do when server sends `<continue/>` (task flow) before we implement tasks?
Suggested default: Fail authentication with explicit `SASL2 task flow not yet supported` error; do not silently fall back mid-handshake.

3. Should we attempt SASL1 fallback after a SASL2 protocol-level failure?
Suggested default: Only for pre-auth negotiation incompatibility (e.g. malformed/unsupported SASL2 feature), not after mechanism exchange has started.

4. How much of `<success/>` payload should we persist now?
Suggested default: Parse and store `authorization-identifier`, `additional-data`, and unknown child elements as raw XML for future Bind2/FAST/IAP consumption.
ANSWER: We should keep the authentication-identifier, and use that as the bare Jid of the connection. The additional-data can be fed into the SASL mechanism, then discarded. Other elements we'll need for extensions.

5. Do we implement `<user-agent/>` in initial SASL2 `authenticate` now?
Suggested default: No for first increment; add as optional follow-up once core flow is stable.
ANSWER: We should implement this, possibly as a an additional phase in the plan.

6. How should we represent inline feature offers/results internally?
Suggested default: `Map<Xmlns, XmlElement>` in v1, wrapped by small typed helpers where needed.

7. Do we add new connection states or reuse existing ones?
Suggested default: Add one explicit transitional SASL2 post-auth state to avoid ambiguous behavior and simplify debugging.

## Risks and Mitigations
- Risk: Regressing SASL1 behavior.
  Mitigation: Keep separate handlers + dedicated compatibility tests.

- Risk: Incorrect post-auth flow (accidental stream restart).
  Mitigation: Explicit tests asserting no `_openStream()` for SASL2 success.

- Risk: Future Bind2/FAST needs forcing refactor.
  Mitigation: Phase 4 extension points before feature implementation.

## Definition of Done
- Client authenticates successfully via SASL2 on compatible servers.
- No stream restart occurs after SASL2 success.
- Server-provided post-auth features are negotiated correctly.
- SASL1 fallback remains functional for legacy servers.
- Unsupported SASL2 task flow fails clearly and predictably.
- Required test suites pass:
  - `flutter analyze`
  - `flutter test`
  - `cd vendor/xmpp_stone && dart test`
