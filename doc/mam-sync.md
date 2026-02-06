# MAM Sync Behavior

This document describes how Wimsy syncs Message Archive Management (MAM) history, how it de-dupes messages, and when fetches occur.

## When MAM requests happen

- Global sync on connect: a global MAM query is issued when the connection becomes ready.
- Per-conversation only when empty: MAM requests are issued when a chat is opened and there are no cached messages for that JID.
- Requests are rate-limited per JID: a backfill for the same JID will not run more than once every 30 seconds.

## Initial fetch strategy (per conversation)

When a chat is opened and there are no cached messages, Wimsy queries MAM for that JID with `max = 50`.
All queries are scoped with the `with` field set to the JID for the chat.

If there are already cached messages, MAM is not queried for that JID on open.

## Initial global fetch strategy

On connection ready, Wimsy primes the archive with a global fetch:

- 1:1 messages: query most recent 50 messages globally (no `with` filter).
- Bookmarked rooms: query most recent 25 messages per bookmarked room JID.

## De-duplication strategy

Wimsy de-dupes messages on insertion using identifiers provided by the server:

- If a MAM `result` has an ID (`mamId`), it is the primary de-dupe key.
- If a `stanza-id` is present, it is also used for de-dupe.
- Empty IDs are ignored (they are not valid keys).

This prevents duplicate messages when:
- MAM backfill overlaps with previously cached history.
- Carbons or live messages are later delivered as MAM results.

## Sent messages vs MAM copies

- Sent messages appear immediately via the local chat flow.
- When the server later returns the same message via MAM, Wimsy merges `mamId`/`stanza-id` onto the existing message where possible.
- Merge uses the stanza `id` when available; otherwise it falls back to a short body/from/to/time heuristic.

## Paging / older history

Per-conversation paging is not automatic beyond the initial 50 for empty chats.

For global sync after reconnect:

- If there is a latest cached 1:1 MAM ID, Wimsy requests all messages after it (max 50).
- If the server has more than 50 new messages, Wimsy also fetches the most recent 50 and then walks backwards in the background using `before` to complete the archive.

## Notes and limitations

- Global MAM sync uses recent-50 and background `before` walking; it does not currently track server counts.
- Bookmarked rooms are displayed but not joined; they are queried for recent messages only.
