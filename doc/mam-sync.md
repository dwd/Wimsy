# MAM Sync Behavior

This document describes how Wimsy syncs Message Archive Management (MAM) history, how it de-dupes messages, and when fetches occur.

Nomenclature follows `doc/ids-sync-dedupe.md`:
- mam-id: XEP-0359 stanza-id scoped by the archive jid.
- stanza-id: XEP-0359 stanza-id scoped by the sender jid.
- attr-id: the stanza `id` attribute scoped by the sender jid.

## MAM scope

- 1:1 scope: the bare JID of the peer.
- Room scope: the bare JID of the room.

All MAM queries and MAM-bound identifiers are scoped by these bare JIDs.

## When MAM requests happen

- On connect (catch-up): for any scope with cached messages, Wimsy runs a catch-up request.
- On chat open:
  - If no cached messages exist for that scope, Wimsy runs an initial fetch.
  - If cached messages exist, Wimsy runs a catch-up request.
- On scroll-to-top (backfill): older history is fetched using the earliest mam-id.
- Rooms: joining a room triggers an initial fetch if no cached room messages exist.
- Rooms: joining a room with cached messages snapshots the latest mam-id
  *before* sending the join stanza, and that snapshot (not a value recomputed
  afterwards) seeds the first post-join catch-up request. This keeps the
  cursor anchored to what was known prior to joining, so live messages
  received while the join is in flight can't shift it forward and cause the
  catch-up to skip anything. Any overlap between those live messages and the
  catch-up results is resolved by the de-duplication strategy below.

## Fetch cases

### Initial

Used when we have no cached messages for a scope.

- 1:1: query the most recent page with `max = 50` and `before = ''`.
- Room: query the most recent page with `max = 25` and `before = ''`.

### Catch-up

Used when we already have cached messages for a scope.

- Use the latest mam-id as an RSM `after` cursor.
- Request `max = 50` per batch.
- If more than 50 messages exist, we currently issue additional batches in order
  by re-querying with the newest mam-id observed so far.

### Backfill

Used when the user scrolls to the top of the chat window.

- Use the earliest mam-id as an RSM `before` cursor.
- Request `max = 50` for 1:1 and `max = 25` for rooms.

## Tracking mam-id bounds

Wimsy tracks the earliest and latest mam-id per scope in cache. These bounds are
used for:
- Catch-up (`after = latestMamId`)
- Backfill (`before = earliestMamId`)

## Crash/disconnect-safe catch-up cursor

In addition to the cache-derived bounds above, Wimsy persists an explicit
per-scope "latest confirmed mam-id" cursor and a "catch-up complete" flag to
disk as they change, not just once catch-up finishes:
- Every message carrying a mam-id that came from an actual MAM `<result>`
  (initial fetch, catch-up, or backfill) immediately advances and persists
  that scope's cursor.
- A live message's mam-id (the room-scoped stanza-id trusted per the
  de-duplication strategy below) only advances the persisted cursor once
  catch-up for that scope has completed in the current session. While a
  catch-up is in flight, trusting a live id could jump the cursor past
  messages the catch-up hasn't fetched yet (since it may have a later
  timestamp than the batch currently being fetched), permanently skipping
  them.
- The "catch-up complete" flag is cleared the moment a new catch-up starts
  for a scope and set once it finishes, so live ids are only trusted again
  after the current catch-up is done.

On the next catch-up request (e.g. after a connection interruption or an
app crash mid-catch-up), Wimsy prefers this persisted cursor over the value
re-derived from the cached messages, so sync resumes from exactly the last
confirmed position instead of potentially being advanced too far by
not-yet-confirmed state.

## De-duplication strategy

Wimsy de-dupes messages on insertion using identifiers provided by the server:

- mam-id is a primary de-dupe key.
- stanza-id is also a de-dupe key.
- attr-id is used to merge missing mam-id / stanza-id onto existing messages.
- Empty IDs are ignored.
- For room messages, XEP-0359 guarantees the room-scoped stanza-id embedded
  in a live stanza is the same id the archive later returns in a MAM
  `<result>`. Wimsy relies on this and treats a live room message's
  stanza-id as its mam-id immediately, without waiting for a MAM result to
  confirm it. If a room isn't MAM-capable there is no stanza-id to begin
  with, so this has no effect there. (This does not apply to 1:1 chats,
  where the embedded stanza-id is scoped by the sender jid rather than the
  archive jid.)

This prevents duplicate messages when:
- MAM backfill overlaps with previously cached history.
- Carbons or live messages are later delivered as MAM results.

## Persisted raw XML and message source

- The `rawXml` Wimsy persists/displays for a message is the actual
  `<message/>` stanza only - the enclosing MAM envelope (`<result
  xmlns='urn:xmpp:mam:2'>`/`<forwarded/>`, likewise XEP-0280 carbons'
  `<sent/>`/`<received/>`/`<forwarded/>`) is stripped before storage, since
  that wrapper is transport plumbing rather than part of the message itself.
- Each `ChatMessage` also carries a `source` field recording where it came
  from: `'mam'` when it was parsed out of a MAM `<result>` (initial fetch,
  catch-up, or backfill), or `'live'` for a normally-delivered/sent stanza
  (including carbons, which are not MAM results). The set of values is
  expected to grow as more origins are distinguished (e.g. offline storage,
  history import).
- The XML viewer in the message detail view shows this `source` alongside
  the raw XML, so it's possible to tell at a glance whether a given message
  was seen live or learned about via MAM.

## Sent messages vs MAM copies

- Sent messages appear immediately via the local chat flow.
- When the server later returns the same message via MAM, Wimsy merges mam-id / stanza-id
  onto the existing message where possible.
- Merge uses the attr-id when available; otherwise it falls back to a short
  body/from/to/time heuristic.

## Notifications and unread state

- Unread state is derived from the displayed sync store (XEP-0490) when available,
  falling back to the last-read timestamp in the UI session.
- The chat list displays a per-scope unread counter for incoming messages after
  that displayed timestamp.
- Unread counters and notifications are suppressed during catch-up until the
  displayed stanza-id for that scope is present in cache.
- Notifications are raised only for incoming messages without a mam-id (live
  delivery). MAM results with a mam-id do not notify; MAM results without a
  mam-id can notify.

## Notes and limitations

- Catch-up currently uses repeated `after` batches instead of server counts.
- Room history is fetched even if the room is not currently joined.
