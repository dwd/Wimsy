# PEP Implementation Plan

## Goal
Add XEP-0163 (PEP) support to Wimsy, with an initial feature that benefits the roster/UI and has clear testable behavior.

## First Use-Case
PEP-based avatars via XEP-0084 (User Avatar):
- `urn:xmpp:avatar:data` (binary payloads)
- `urn:xmpp:avatar:metadata` (hash references)

This gives immediate UI value (avatars) and is widely supported. It also lays the groundwork for other PEP payloads later.

## Architecture Overview
- Implement a minimal PubSub/PEP module in the vendored `xmpp_stone`:
  - Publish (`<pubsub><publish>`)
  - Retract (`<pubsub><retract>`)
  - Subscribe (`<pubsub><subscribe>`)
  - Event handling (`<message><event>`)
- Expose a `PepManager` service in app code:
  - Subscribe to avatar metadata
  - Fetch missing avatar data blobs
- Cache data locally (encrypted)
- Update UI bindings (roster + message list)
- Add +notify auto-subscription:
  - Parse presence `<c>` caps (XEP-0115)
  - Query disco#info for node#ver
  - Auto-subscribe when `urn:xmpp:avatar:metadata+notify` is present

## Data Model
- `AvatarMetadata`: jid, item id, hash, content type, byte length, timestamp
- `AvatarBlob`: hash -> bytes
- Persistence: encrypted Hive box
  - `avatar_metadata` by bare JID
  - `avatar_blobs` by hash

## PubSub/PEP Flows
1) Subscribe to metadata:
   - `pubsub` service for PEP is the bare JID of the user (PEP node on their account).
   - Send `<iq type='set'><pubsub><subscribe node='urn:xmpp:avatar:metadata'/></pubsub></iq>`.
2) Receive metadata event:
   - `<message><event><items node='urn:xmpp:avatar:metadata'><item id='hash'><metadata>...</metadata></item></items></event></message>`
3) If hash unknown: request data:
   - `<iq type='get'><pubsub><items node='urn:xmpp:avatar:data' max_items='1'/></pubsub></iq>`
4) Receive data:
   - `<iq type='result'><pubsub><items node='urn:xmpp:avatar:data'><item id='hash'><data>base64...</data></item></items></pubsub></iq>`
5) Update cache + UI.

## Implementation Steps
1) Add PEP/PubSub stanza builders + parsers
   - New `PubSubElement`, `EventElement`, and helpers in `vendor/xmpp_stone`.
   - Parse event payloads into a simple `PepEvent` model.
2) Add `PepManager` in app
   - Subscribe to metadata for all roster contacts + self on connect.
   - Handle incoming event messages, update cache, trigger data fetch.
3) Cache + UI
   - Store avatars in Hive (encrypted).
   - UI reads avatar for contact; fallback to placeholder initials.
4) Add backfill
   - On startup, show cached avatars immediately.
   - On connect, refresh metadata.

## Automated Tests
### Unit tests (Dart)
- `PepEventParserTest`:
  - Given an incoming PEP event stanza, parse metadata hash + jid.
- `AvatarCacheTest`:
  - Store/retrieve metadata + blobs.
  - Missing hash returns null.
- `PepManagerTest`:
  - On metadata event for unknown hash, issues data fetch IQ.
  - On data result, stores blob and updates metadata.
- `PepCapsManagerTest`:
  - Presence with caps triggers disco#info request.
  - +notify feature response triggers PEP subscribe.

### Integration tests
- `PepFlowTest`:
  - Simulate connection, push synthetic PEP event stanzas into handler, assert UI model updates.

## Manual Test Strategy
1) Use a server account that supports PEP + XEP-0084 (Prosody, ejabberd).
2) Connect two clients:
   - Client A: set avatar (e.g., via another client).
   - Client B (Wimsy): should update roster avatar within seconds.
3) Verify cache:
   - Disconnect, restart, confirm avatar appears before network sync.
4) Verify update:
   - Change avatar again; Wimsy updates and replaces cached blob.

## Follow-ups (Future PEP features)
- XEP-0108 (User Activity)
- XEP-0107 (User Mood)
- XEP-0115 (Entity Capabilities)
- XEP-0172 (User Nickname)
