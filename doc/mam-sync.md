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

## De-duplication strategy

Wimsy de-dupes messages on insertion using identifiers provided by the server:

- mam-id is a primary de-dupe key.
- stanza-id is also a de-dupe key.
- attr-id is used to merge missing mam-id / stanza-id onto existing messages.
- Empty IDs are ignored.

This prevents duplicate messages when:
- MAM backfill overlaps with previously cached history.
- Carbons or live messages are later delivered as MAM results.

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
