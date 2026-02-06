# MUC Implementation Plan

This plan covers adding Multi‑User Chat (XEP‑0045) support to Wimsy, including code changes, automated tests, and a manual verification checklist.

## Scope

- Join/leave MUCs (including bookmarks).
- Basic groupchat messaging (send/receive).
- Occupant list (nick, role, affiliation) with live updates.
- Room subject changes and history handling.
- Presence in rooms and simple “you are connected” state.

Out of scope (initially): moderated actions (kick/ban), voice/roles UI, invites, MUC JID registration, and advanced config UI.

## Dependencies / Library Work

xmpp_stone currently lacks XEP‑0045 primitives. We need to add a minimal MUC module in `vendor/xmpp_stone`:

- Stanza builders:
  - `<presence to='room@conference.example/nick'><x xmlns='http://jabber.org/protocol/muc'/></presence>`
  - `<message type='groupchat' to='room@conference.example'><body>...</body></message>`
  - `<presence type='unavailable' to='room@conference.example/nick'/>`
- Parsers:
  - Room presence updates (occupant nick, role, affiliation, status codes 110/201, etc.).
  - Groupchat messages and subject changes.
- Module API:
  - `MucManager.join(roomJid, nick, {password})`
  - `MucManager.leave(roomJid, nick)`
  - `MucManager.send(roomJid, body)`
  - Streams: `roomMessageStream`, `roomPresenceStream`, `roomSubjectStream`.

## Client Integration

- Models
  - Add `RoomEntry` (room JID, nick, subject, joined state, occupants count).
  - Add `RoomMessage` or reuse `ChatMessage` with a `isGroupchat` flag.
- Storage
  - Store joined rooms and last used nick.
  - Cache recent room messages (optional in v1) with timestamps.
- UI
  - Show bookmarked rooms as joinable items.
  - When joining, open a groupchat view with message list and occupant count.
  - Indicate join/leave state and show subject.
- Service
  - Add `MucService` (or extend `XmppService`) to manage joins/leaves and expose room streams.

## MAM + MUC

- For groupchats, query MAM with `with=room@conference.example` for recent history (max 25) on join.
- De‑dupe against live groupchat messages using `stanza-id` when available.

## Tests (Automated)

### Vendor (xmpp_stone)

- Build presence join/leave stanzas correctly.
- Parse groupchat message and subject change.
- Parse occupant presence with roles/affiliations and self‑presence (status code 110).

### App layer

- `MucService.join` triggers correct stanza.
- Incoming groupchat message updates message cache and UI state.
- Occupant updates update room state without crashing.

## Manual Test Plan

1) Join a public room (e.g., `room@conference.server`)
   - Verify join presence is sent and no error returned.
   - Check subject appears if the room has one.
2) Send a message
   - Confirm it appears locally and is echoed back.
3) Receive messages from others
   - Verify sender nick is shown correctly.
4) Leave the room
   - Confirm presence unavailable is sent and room is marked as left.
5) Re‑join
   - Ensure history is fetched (if MAM enabled).
6) Invalid password / members‑only
   - Ensure error is surfaced and room remains unjoined.

## Sequencing

1) Add vendor MUC primitives + parsing.
2) Add service layer for join/leave/send + streams.
3) UI for room list + room chat view.
4) MAM integration for rooms.
5) Tests + manual verification.
