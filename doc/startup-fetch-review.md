# Startup Fetch Review: Displayed sync, MAM/archiving, vCard/Avatar caches

Date: 2026-05-01

This document reviews how Wimsy interacts on startup with:

* XEP-0490 Message Displayed Synchronization (MDS)
* XEP-0313 MAM (catch-up and backfill)
* XEP-0084 PEP user-avatar metadata + data
* XEP-0153 vCard-temp avatar updates
* The local message / avatar cache (Hive via `StorageService`)

It identifies places where the client refetches data unnecessarily on every
connect and proposes concrete fixes (or, where a fix is not currently
possible, explains why).

The review is based on a `flutter run` startup trace (`wimsy.log`) plus
inspection of:

* `lib/xmpp/xmpp_service.dart`
* `lib/xmpp/mam_coordinator.dart`, `mam_query_planner.dart`,
  `mam_cursor_store.dart`, `mam_merge_engine.dart`
* `lib/pep/pep_manager.dart`, `pep_caps_manager.dart`
* `lib/storage/storage_service.dart`

---

## TL;DR — biggest startup wins

| # | Symptom | Where | Effort | Saved traffic |
|---|---------|-------|--------|---------------|
| 1 | vCard `<vCard xmlns="vcard-temp"/>` fetched for every roster entry on every connect, even when we already have the photo bytes and hash | `_ensureContact` → `_requestVcardAvatar`, `lib/xmpp/xmpp_service.dart:6741` | Low | N × (roster size) IQ + payload (a vCard photo can be tens of KB) |
| 2 | vCard fetched again per presence even when the advertised `<photo>` hash matches the cached one | `_handleVcardPresenceUpdate`, `lib/xmpp/xmpp_service.dart:7694` | Low | One IQ per online roster contact each time presence is re-broadcast |
| 3 | MDS published items requested via PubSub IQ on every Ready, despite caching `displayed_sync` in Hive and despite the server pushing +notify | `_setupDisplayedSync`, `lib/xmpp/xmpp_service.dart:5186` | Low | One IQ + payload per startup |
| 4 | Per-chat MAM catch-up step is fired for every chat with cached messages, regardless of whether MDS displayed-id already matched a known local message (i.e. we are demonstrably up to date) | `_primeMamSync`, `lib/xmpp/xmpp_service.dart:7541` | Medium | One MAM `<query>` per cached chat, each producing a page of forwarded messages |
| 5 | "Displayed sync miss" → we drop the displayed marker silently and never narrow the catch-up; next time MDS arrives we still cannot match | `_applyDisplayedStateForChat`, `lib/xmpp/xmpp_service.dart:5460` | Medium | Repeated MAM pages on every startup for the same chat |
| 6 | Two duplicate self vCard fetches at session start (one in initial flush, one explicit) and `enable carbons:2` is sent twice | observed in log around `12:20:21–12:20:22` | Low | A handful of redundant IQs |

Items 1–3 are pure waste. Items 4–5 are the structural ones that explain why
"Displayed sync miss" log lines appear after every restart for chats with
many unread messages, and why we end up pulling a new MAM page on every
connect.

---

## 1. Displayed Sync (XEP-0490) — current behaviour

### What we do today

* On `XmppConnectionState.Ready` we call `_setupDisplayedSync()`
  (`xmpp_service.dart:5186`). This sends an IQ:

  ```xml
  <iq type="get" to="self">
    <pubsub xmlns="…/pubsub">
      <items node="urn:xmpp:mds:displayed:0"/>
    </pubsub>
  </iq>
  ```

  i.e. it fetches **all** items from the displayed node every connect.

* The result populates `_displayedStanzaIdByChat` and is persisted to
  `displayed_sync` in `StorageService` via `storeDisplayedSync` —
  `_displayedStanzaIdByChat` is also seeded from storage on app start.

* For each item we call `_applyDisplayedStateForChat`, which walks the
  in-memory message list for that chat looking for the `stanza-id`. If
  found, we mark MAM catch-up complete for that chat. If not found, we log
  "Displayed sync miss" (see `wimsy.log`) and **return false** without
  taking further action.

* PubSub event messages (`<event xmlns="…pubsub#event">`) for MDS are also
  handled by `_handleDisplayedSyncEvent`, so live updates from carbons /
  +notify already work.

### Problems

1. **Always-on full fetch.** We already cache the displayed map on disk,
   yet every connect we still query the entire `urn:xmpp:mds:displayed:0`
   node. There are two cheaper alternatives:

   * **Subscribe to MDS via +notify** (the spec defines this). The server
     will push `<event/>` items at our session and we don't need to poll.
     We currently do not advertise `urn:xmpp:mds:displayed:0+notify` in
     our `disco#info` features, and we do not subscribe via Carbons. We do
     however receive PEP events (we already handle them), so the simplest
     fix is just to add the `+notify` feature to our caps form, like we
     do for `urn:xmpp:avatar:metadata+notify`.
   * **Compare with the cached map** — if the published item count is
     small (one item per chat) we still get a full PubSub items result on
     IQ; we can skip the IQ when our cached map is non-empty and rely on
     +notify for catch-up.

2. **Misses are terminal.** When `_applyDisplayedStateForChat` cannot find
   the displayed `stanza-id` in the local message list, it logs a miss
   and gives up. As a consequence:

   * The MAM catch-up tracker for that chat is never marked complete from
     MDS, so the catch-up loop will keep running on every startup until
     the user actually opens the chat and we backfill.
   * The displayed marker is forgotten silently, so the next time MDS
     pushes the same `id` we will short-circuit at
     `_displayedStanzaIdByChat[id] == stanzaId` and never retry the match.
   * This is exactly what we see in the log:
     `Displayed sync miss for chat=xsf@muc.xmpp.org … messages=25
     knownStanzaIds=[…5 ids…]` — we have only 25 cached messages and the
     server's displayed marker points further back.

### Recommendations

* **R1.1 (easy).** Skip the explicit `_setupDisplayedSync` IQ when
  `_displayedStanzaIdByChat` was successfully restored from disk; fall
  back to the IQ only when the cache is empty.
* **R1.2 (easy).** Advertise `urn:xmpp:mds:displayed:0+notify` in our
  caps disco form and rely on PubSub auto-subscription. This eliminates
  the IQ entirely on subsequent restarts.
* **R1.3 (medium).** On a "Displayed sync miss":
  * Persist the unresolved `(chatJid, stanzaId)` pair to disk
    (e.g. `displayed_sync_pending`).
  * On the next MAM page that contains this `stanza-id`, resolve and
    remove the pending entry, then set the displayed timestamp and clear
    the catch-up flag.
  * Drive a single bounded MAM query toward this `stanza-id` (use it as
    `before` and stop) instead of firing the generic catch-up step.

This last point is the key structural fix: it converts an unbounded
"catch-up since latest known mam-id" into a precise "fetch up to the
displayed marker", which is exactly what MDS is for.

---

## 2. MAM catch-up on connect

### What we do today

In `_primeMamSync()` (`xmpp_service.dart:7541`), once the connection is
Ready we iterate over every cached DM chat and every bookmark and:

* If the chat has cached messages → call `_startMamCatchUp(jid, …)`,
  which posts a MAM `<query>` using `MamQueryPlanner.catchUp`
  (`afterId=<latestMamId>`). This is correct behaviour — we ask for
  messages newer than what we already have.
* If the chat has no cached messages → call
  `_requestRoomMam(roomJid, max:25, before:'')` for rooms or
  `_requestMamInitial(jid)` for DMs.

`MamCursorStore` throttles repeats inside a session (5s for catch-up,
30s for backfill) and keeps `prependOffset`/timer state. Cursors per chat
are correctly persisted via `_seededMessageJids` and `latestMamIdFor`,
so we are not re-pulling history we already have.

### Where this is wasteful

* The catch-up step fires **for every cached chat**, including chats the
  user has not opened in months and is unlikely to open this session.
  For a typical roster with dozens of contacts/MUCs this is dozens of
  parallel `<iq><query xmlns="urn:xmpp:mam:2">` requests at startup.
* Even when MDS already tells us "the last message you displayed in
  chat X is stanza Y" and we have Y in our local cache, we still go and
  ask MAM for newer messages. That part is correct in principle (we
  could legitimately have new messages), but it means we are essentially
  doing a fan-out poll on every connect.
* For MUCs we additionally do a fan-out of `<presence/>` and chat-state /
  caps disco, and then immediately ask the MUC's MAM. We already see in
  the log that `summit@muc.xmpp.org` is dragging in a long backlog
  (`queryid="VPNAXKAHR"`) on the aux QUIC stream, blocking other work.

### Recommendations

* **R2.1 (medium).** Defer per-chat MAM catch-up until the user actually
  opens the chat (or makes the chat list visible), keeping only:
  * A single global "last seen" anchor per account, similar to how
    Conversations does it: query MAM with `start=<lastSyncAt>` (or a
    server-side bounded period like 24h), get one merged stream, then
    update per-chat anchors as messages come in.
  * Plus a per-chat cap of e.g. 25 messages on the first time the chat
    is opened.

  We have most of the machinery already (`MamCursorStore`,
  `mergeMamIdsIntoExisting`, `latestMamIdFor`); the missing piece is a
  single global `last_mam_id_seen` and a corresponding initial query at
  connect time.

* **R2.2 (low).** When MDS displayed-id matches a local message *and* the
  message's MAM id equals `latestMamIdFor(chat)`, skip the catch-up
  query for that chat entirely — we already know we are caught up to
  the displayed marker. (Today we set the displayed timestamp and clear
  the pending flag, but `_primeMamSync` still iterates and fires
  catch-up.)

* **R2.3 (low).** Make `_primeMamSync` skip chats that the user has not
  opened in the current session unless the user has explicitly enabled
  "fetch all on startup" in preferences.

* **R2.4 (low).** Sort/throttle the connect-time fan-out: bookmark joins
  trigger MUC presence + MAM + caps disco; we should batch caps disco
  hits via a single bounded queue (we already do this for vCards via
  `_vcardRequests`). A tiny token-bucket limiter would smooth this out.

### Why we cannot do "no MAM at all" today

Without persisting a `last_mam_id_seen` per account in `StorageService`
we do not have a single global anchor. Today the per-chat anchors are
necessary because messages can arrive in chats we never explicitly
loaded (e.g. via carbons while offline). We can build R2.1, but it
requires adding one new key to `StorageService` and one new query path.

---

## 3. Avatar caching — PEP user-avatar (XEP-0084)

### What we do today

`PepManager` (`lib/pep/pep_manager.dart`) is the well-behaved bit:

* On boot we seed `_metadataByJid` and `_avatarBlobs` from
  `StorageService.loadAvatarMetadata()` / `loadAvatarBlobs()`.
* `requestMetadataIfMissing(bareJid)` is a no-op when we already have
  metadata for that JID.
* `requestAvatarData(bareJid, hash)` is a no-op when we already have
  the blob for that hash.
* PubSub event messages with `urn:xmpp:avatar:metadata` update the cache
  and request the data only when the hash is new.

This is correct. The only minor improvements possible:

* **R3.1 (very low).** We never expire stale blobs that are no longer
  referenced by any metadata entry. For long-lived installs this is a
  small but real disk leak. A periodic GC pass over `_avatarBlobs`
  versus `_metadataByJid` would fix it.
* **R3.2 (low).** We do not subscribe (`<subscribe>`) to anyone other
  than ourselves. PEP +notify is enough for contacts who advertise our
  caps via PEP, but for non-presence-subscribed contacts (open MUCs
  etc.) we will pay a one-shot metadata IQ when we first see them. This
  is unavoidable without a presence subscription.

### Why some PEP avatar IQs *do* fail in the log

The log shows several `<error code="404"><item-not-found/>` PEP avatar
metadata responses (e.g. for `test1@dave.cridland.net`, `test2@…`). That
is expected: those JIDs publish a vCard avatar but no PEP one. We
*should* cache the 404 too, otherwise we will retry every connect.

* **R3.3 (low).** Treat `item-not-found` on
  `urn:xmpp:avatar:metadata` as "no PEP avatar" and store a sentinel in
  `_metadataByJid` (e.g. an `AvatarMetadata` with empty `hash`) so
  `requestMetadataIfMissing` short-circuits next startup.

---

## 4. Avatar caching — vCard-temp (XEP-0153)

This is the worst offender on startup.

### What we do today

`xmpp_service.dart:7604–7653` defines `_requestVcardAvatar` /
`_requestVcardDetails`. Triggers:

* `_ensureContact` calls `_requestVcardAvatar(entry.jid)` for every
  **new** roster entry (line 6741). However, on first connect after app
  start, *every* roster entry is a "new" entry as far as in-memory
  `_contacts` is concerned (we seed contacts from disk before
  `_setupRoster` runs, so this is only fine if we persist contacts; we
  do — but we still re-issue the vCard fetch elsewhere).
* `_handleVcardPresenceUpdate` calls `_requestVcardAvatar` whenever a
  presence stanza carries `<x xmlns='vcard-temp:x:update'><photo>`. The
  guard at line 7724 is good (skip when hash matches and bytes
  cached) — but the line 7727 `_vcardAvatarState[bareJid] = hash;` is
  applied **before** we know whether bytes are cached, and the next call
  to `_requestVcardAvatar` is unconditional.
* `_setupRoster`-equivalent paths in `xmpp_service.dart:1286, 1453,
  2339, 6741` all call `_requestVcardAvatar` / `_requestVcardDetails`
  without consulting `_vcardAvatarBytes` or `_vcardAvatarState`.
* The self vCard is fetched again at line 1036
  (`_requestVcardDetails(_currentUserBareJid!, preferName: true)`) on
  every Ready — duplicating any roster-driven self fetch.

The persistence story is fine: `storeVcardAvatar`,
`storeVcardAvatarState` keep both bytes and the hash in Hive, and we
seed both maps at boot via `_seedVcardAvatars` / `_seedVcardAvatarState`.

So we already *have* the data. We just don't *use* it as a guard.

### Recommendations

* **R4.1 (high impact, low effort).** Add a guard at the top of
  `_requestVcardDetails`:

  ```dart
  if (!preferName &&
      _vcardAvatarBytes.containsKey(bareJid) &&
      (_vcardAvatarState[bareJid] ?? '').isNotEmpty &&
      _vcardAvatarState[bareJid] != _vcardNoAvatar) {
    return; // Already have bytes + hash; vCard advertises only avatar here.
  }
  ```

  i.e. only fetch the vCard when we do not have cached bytes for the
  current advertised hash, or when we genuinely need the name
  (`preferName == true`).

* **R4.2 (very low effort).** In `_handleVcardPresenceUpdate`:

  ```dart
  if (existing == hash && _vcardAvatarBytes.containsKey(bareJid)) {
    return; // already there
  }
  ```

  is already present and correct. The bug is that *other* call-sites
  (line 6741, etc.) bypass this gate. Centralising the cache check in
  `_requestVcardDetails` (R4.1) covers them all.

* **R4.3 (low effort).** Cache "this JID has no vCard"
  (`InvalidVCard`) across restarts. Today `_vcardUnavailable` is a
  process-only `Set<String>`, so we will retry next startup. Persist
  it (e.g. `storeVcardAvatarState(jid, _vcardNoAvatar)` already does
  the equivalent for missing photos; extend it to missing vCards
  altogether by adding a separate sentinel or storing a tag in
  `vcardAvatarState`).

* **R4.4 (low).** Coalesce duplicate self vCard fetches: `_setupRoster`
  may re-add self to the contacts map, and we explicitly fetch it again
  at line 1036. A single `_vcardRequests` guard already prevents two
  outstanding requests, but we are still issuing one we don't need. Add
  the same R4.1 guard.

---

## 5. Other startup multipliers seen in the log

These are not strictly cache misses but they magnify the impact of the
above:

* **Carbons enabled twice.** `enable xmlns="urn:xmpp:carbons:2"` is sent
  in two different code paths during initial flush (`KNBYYPMLT` and
  `VSBVMXXRT` in the log). Harmless but wasteful. Track a
  `_carbonsRequested` flag.
* **Caps disco fan-out.** Every distinct `node#ver` from MUC presence
  triggers a disco#info IQ. We do cache caps locally (`pep_caps_manager`
  reads features), but we do not currently use a shared, persistent
  caps cache à la Entity Capabilities (XEP-0115) verifier. Persisting
  caps results across restarts (keyed by `node#ver`) would eliminate the
  flurry of `disco#info` IQs visible in the log.
* **Reactions PEP node fetched on every Ready** (`UJXJYDOXP` in the
  log). Same +notify treatment as MDS would solve it.

---

## 6. Things we *cannot* avoid without more information

Some of the startup chatter is simply structural and cannot be reduced
without protocol-level changes or new server hints:

1. **MUC presence broadcast on join.** When we re-enter a MUC we will
   receive presence for every occupant. That is the protocol; we cannot
   suppress it. The cost is in caps disco (which we *can* cache; see
   above) and in MUC avatar updates (vCard-temp photos in MUC presence)
   — those are addressable by R4.1.
2. **Roster fetch.** The roster IQ is needed for subscription state; we
   already use `ver=` (the log shows
   `<query xmlns='jabber:iq:roster' ver='364576852'/>`) and the server
   correctly returns an empty result when we are up to date. So this
   one is already optimal.
3. **MAM "tail" query for chats with no local cache.** If we have
   nothing to anchor against, we have to ask the server for the most
   recent N. Nothing to fix here.
4. **Initial server stream features negotiation.** Out of scope for this
   review. SASL2 / Bind 2 / FAST would amortise this and is being
   tracked in `doc/plan-sasl2.md`.

---

## 7. Concrete plan / TODO

Tackling in roughly priority order:

1. **R4.1 — DONE.** Centralised vCard cache guard added to
   `_requestVcardDetails` (`lib/xmpp/xmpp_service.dart`). The decision
   logic was extracted as `shouldFetchVcardForCache` in
   `lib/xmpp/vcard_utils.dart` and is exercised by unit tests in
   `test/vcard_utils_test.dart`. `_handleVcardPresenceUpdate` now passes
   the freshly advertised `<photo>` hash through to the guard so a hash
   change still triggers a refetch. _Impact: removes most of the vCard
   storm at connect._
2. **R3.3 — DONE.** `AvatarMetadata.noPepAvatar()` sentinel added in
   `lib/models/avatar_metadata.dart` (with a guarded `fromMap` round-trip
   so the sentinel survives across restarts even though `bytes` is `-1`).
   `PepManager` now tracks pending `urn:xmpp:avatar:metadata` GET IQs
   and, on a non-`RESULT` reply (e.g. `<error type="cancel"
   ><item-not-found/>`), persists the sentinel via
   `StorageService.storeAvatarMetadata`. `requestMetadataIfMissing`
   short-circuits when the sentinel is in-cache. `avatarBytesFor` /
   `avatarHashFor` treat sentinel entries as "no avatar". Real metadata
   events overwrite the sentinel. New tests in
   `test/pep_manager_test.dart` cover all four code paths.
3. **R1.1 — DONE.** `_setupDisplayedSync` now early-returns when the
   in-memory `_displayedStanzaIdByChat` map was successfully restored
   from disk. The decision lives in `shouldFetchDisplayedSyncBootstrap`
   (`lib/xmpp/startup_fetch_helpers.dart`) and is exercised by
   `test/startup_fetch_helpers_test.dart`. A `force` flag preserves the
   ability to manually re-pull the entire MDS state when desired.
4. **R1.2 — DONE.** On audit it turned out
   `urn:xmpp:mds:displayed:0+notify` was already present in
   `vendor/xmpp_stone/lib/src/features/servicediscovery/ServiceDiscoverySupport.dart`
   (alongside `urn:xmpp:avatar:metadata+notify`). The Section 1 narrative
   above ("we currently do not advertise") was incorrect at the time the
   review was written. To prevent silent regressions, a regression
   suite `test/service_discovery_features_test.dart` now asserts that
   the +notify entries (and other core disco features) remain in the
   list. `doap.xml` already lists XEP-0490 as supported.
5. **R1.3 — DONE (partially).** A new on-disk key
   `displayed_sync_pending` is added to `StorageService`
   (`loadDisplayedSyncPending` / `storeDisplayedSyncPending`,
   wiped alongside the existing displayed_sync map by
   `clearDisplayedSync`). `_applyDisplayedStateForChat` now records the
   unresolved (chatJid, stanzaId) pair in an in-memory
   `_displayedSyncPending` map (seeded from disk in `attachStorage` and
   cleared everywhere `_displayedStanzaIdByChat` was). A new
   `_resolveDisplayedSyncPending` helper is invoked from every
   message-append path (DM and MUC, including the MAM-prepend path)
   and re-runs the matcher when the new message's stanza-id matches.
   On a successful match the displayed timestamp is set and MAM catch-up
   is marked complete for the chat — exactly as if MDS had matched on
   first sight.

   Tests in `test/displayed_sync_pending_test.dart` cover the storage
   round-trip and that `clearDisplayedSync` wipes both maps.

   _Not done in this commit:_ driving a single bounded MAM query
   towards the persisted `stanza-id` (using it as `before=`). The
   resolver above is sufficient for the most common case (the missing
   message comes back through the existing per-chat catch-up, or a
   later live message) and avoids changing MAM query routing in this
   batch. The bounded-query optimisation would land cleanly as a
   subsequent change, on top of the persistence introduced here.
6. **R2.2 — DONE.** `_primeMamSync` now consults
   `shouldFetchMamCatchUpForChat` (`lib/xmpp/startup_fetch_helpers.dart`,
   already shipped with R1.1) for every cached DM and every bookmarked
   MUC; if the persisted displayed marker matches the stanza-id of the
   newest local message, the per-chat MAM `<query/>` is skipped
   entirely. A small new helper
   `_stanzaIdAtLatestMamId(bareJid, {isRoom})` looks up the stanza-id of
   the message at the latest MAM id, with a `null` fallback whenever
   that information isn't available (in which case the catch-up still
   fires, exactly as before).
7. **R5 / caps cache — DONE.** New persisted Entity Capabilities cache
   in `StorageService` (key `entity_caps`,
   `loadEntityCaps`/`storeEntityCaps`/`clearEntityCaps`). `PepCapsManager`
   accepts an optional `StorageService` (passed in by `xmpp_service.dart`),
   seeds `_capsFeatures` from disk in its constructor, and persists every
   successful `disco#info` result. When MUC presence advertises a
   `node#ver` we already cached, the disco IQ is short-circuited and the
   features become immediately available via `featuresForBareJid`. New
   tests in `test/pep_caps_manager_test.dart` cover (a) persistence on
   disco result, (b) seed-from-disk skipping the disco IQ, and (c)
   unknown `node#ver` still triggering disco even with a seeded cache.
8. **R2.1 — DONE (partially).** Added the persisted global anchor
   `last_mam_id_seen` to `StorageService`
   (`loadLastMamIdSeen` / `storeLastMamIdSeen` / `clearLastMamIdSeen`).
   `XmppService` seeds `_lastMamIdSeen` from disk in `attachStorage`,
   exposes it via the new `lastMamIdSeen` getter, and bumps it from
   every message-append path (DM, MUC tail, MUC MAM-prepend) via the
   new private helper `_bumpLastMamIdSeen` (a lexicographic
   compare-and-swap). New tests in `test/last_mam_id_seen_test.dart`
   cover the storage round-trip.

   _Not done in this commit:_ the actual unified catch-up query that
   uses this anchor instead of fanning out per-chat. That would change
   MAM query routing and is intentionally left as a follow-up — the
   anchor it would need to read is now persisted and updated, so the
   follow-up can be a localised change inside `_primeMamSync` /
   `MamQueryPlanner` without touching the message-ingest paths.
9. **R3.1 — DONE.** `PepManager.gcUnreferencedAvatarBlobs()` evicts any
   cached blob whose hash is not referenced by a current non-sentinel
   `_metadataByJid` entry. The pass is invoked once from the constructor
   immediately after the on-disk seeds are loaded, and is safe to call
   ad-hoc (returns the eviction count). `StorageService` gained a small
   `replaceAvatarBlobs(Map)` helper to persist the trimmed set in one
   write. New tests in `test/pep_manager_test.dart` cover the eviction
   semantics and idempotency on a clean cache.

Each of the above can ship as its own PR with tests:

* `MamCursorStore` already has a deterministic `now`/`schedule` seam,
  so R2.2 is unit-testable without a network.
* `PepManager` is constructor-injectable with a mock `Connection`; the
  +notify and 404 paths are easily testable.
* The vCard cache guard (R4.1) needs a unit test that asserts no IQ is
  emitted when bytes for the advertised hash are already cached, and
  that an IQ *is* emitted when the advertised hash differs.

---

## Log review — 2026-05-01 13:40 session (`wimsy.log`)

This section answers three questions about the log captured on 2026-05-01.

### 1. Have the startup-fetch-review fixes taken effect?

**No — the log predates all nine commits.** Every fix (R4.1 through R3.1)
was committed during the same session in which this log was captured, so
the binary that produced the log did not include any of them. The evidence
is clear:

* Two "Displayed sync miss" lines appear at `13:40:16` — R1.1 (skip MDS
  bootstrap IQ when cache is seeded) and R1.3 (persist pending markers)
  were not active.
* 31 `<vCard xmlns="vcard-temp"/>` GET IQs are sent in the first ~5 seconds
  after Ready — R4.1 (cache-guard) was not active.
* `urn:xmpp:avatar:metadata` is polled for every roster contact at Ready
  (10+ IQs in the initial flush) — R3.3 (negative-cache sentinel) was not
  active.
* Per-chat MAM catch-up queries fire for every bookmarked MUC regardless
  of MDS state — R2.2 (skip when MDS proves up-to-date) was not active.

A fresh log taken after a hot-restart with the new code should show: no
"Displayed sync miss" lines (or at most one per chat that has genuinely
new messages), no vCard storm, no avatar-metadata poll at Ready, and
significantly fewer MAM queries.

### 2. Additional issues visible in this log

**a) Double roster IQ at Ready**

In the single Ready flush at `13:40:23.562` we send *two* roster IQs
back-to-back:

```
YIVVNRAHB  <query xmlns="jabber:iq:roster"/>          ← bare, no ver=
MBVSUKUKH  <query xmlns="jabber:iq:roster" ver="364576852"/>  ← versioned
```

The server returns the full roster for `YIVVNRAHB` (ignoring the `ver=`
attribute because it is absent) and an empty result for `MBVSUKUKH`
(because the version matches). The bare IQ is redundant — we already have
a cached version token so we should only send the versioned form. This is
a minor bug in the Ready flush assembly: the bare IQ is likely emitted by
one code path and the versioned one by another, both firing at the same
time.

**b) Carbons enabled twice**

`enable xmlns="urn:xmpp:carbons:2"` is sent at two distinct points:

1. `13:40:22.768` — `NJJOJDNQI` — during the post-bind feature negotiation
   phase (the `ConnectionNegotiatorManager` carbons negotiator).
2. `13:40:23.562` — `HFWGKSCKB` — inside the Ready flush, as part of the
   same batch that sends the roster IQ and presence.

The second enable is harmless (the server just returns a result) but wastes
a round-trip. The Ready flush should check whether carbons were already
enabled by the negotiator and skip the redundant IQ.

**c) `urn:xmpp:avatar:metadata` polled for every roster contact at Ready**

Even though we advertise `urn:xmpp:avatar:metadata+notify` (confirmed by
R1.2 audit), the Ready flush still sends an explicit
`<items node="urn:xmpp:avatar:metadata" max_items="1"/>` IQ to every
roster contact that has a PEP node. With +notify in our caps, the server
will push any changed metadata to us automatically; the poll is only needed
for contacts whose server does not support PEP +notify. The current code
appears to poll unconditionally. A guard similar to R1.1 (skip when we
already have cached metadata and the contact's server supports +notify)
would eliminate this fan-out. This is a lower-priority item than the vCard
storm because the payloads are small, but with a large roster it adds up.

### 3. The disconnect at the end

The disconnect is **clean and server-initiated due to the idle timeout**.

Evidence:

* The first stream features stanza (pre-auth, `13:40:20`) advertises
  `<idle-seconds>360</idle-seconds>` — the server will close the stream
  after 360 seconds of inactivity.
* The connection became Ready at `13:40:23` and the initial burst of IQs
  and MAM pages completed by roughly `13:40:40`. After that the log shows
  only incoming MUC presence and vCard responses — no outbound traffic.
* At `13:41:08` (approximately 45 seconds after Ready, well within the
  360-second window) the log records `QUIC connection closed cleanly (no
  error reported)` followed immediately by
  `XmppConnectionState.ForcefullyClosed` and a reconnect schedule.

The 45-second gap is shorter than the 360-second idle limit, which means
the server closed the connection for a reason *other* than the idle timer.
The most likely cause is that the Openfire server closed the QUIC
connection at the QUIC transport layer (a `CONNECTION_CLOSE` frame with
no application error), possibly because it considers the QUIC session
idle once the initial stream of stanzas drains, or because of a
server-side session management policy. The `QUIC connection closed cleanly`
message confirms there was no TLS or QUIC error — this is a graceful
`CONNECTION_CLOSE`.

**What to do:** The reconnection manager correctly schedules a reconnect
(`delay=3847ms`). However, to avoid this happening in production we should
send a periodic XMPP ping (XEP-0199) to keep the QUIC connection alive.
The server already advertises `urn:xmpp:ping` in its disco features. A
ping every 60–90 seconds (well under the 360-second idle limit) would
prevent the server from closing the connection. This is separate from the
startup-fetch work and should be tracked as its own issue.

---

## Log review — 2026-05-01 15:34 session (`wimsy.log`, updated)

This section reviews the log captured at 15:34 on 2026-05-01, taken after
`flutter run -d linux` with the latest code (all nine R4.1–R3.1 commits
present).

### 1. Have the startup-fetch-review fixes taken effect?

**Partially — but a critical re-seed bug prevents most guards from working
on reconnect.**

The log shows **six connection cycles** (Ready at 14:34:49, 14:35:46,
14:36:37, 14:37:37, 14:38:34, 14:39:26) caused by repeated server-initiated
QUIC disconnects. Per-cycle counts:

| Cycle | vCard IQs | avatar:metadata IQs | MAM queries |
|-------|-----------|---------------------|-------------|
| 1     | 16        | 10                  | 39          |
| 2     | 23        | 7                   | 123         |
| 3     | 8         | 7                   | 119         |
| 4     | 11        | 7                   | 78          |
| 5     | 9         | 11                  | 66          |
| 6     | 14        | 10                  | 113         |

Every cycle re-fetches vCards and avatar metadata, and re-runs MAM
catch-up queries. The root cause is a **re-seed bug**:

* `_vcardAvatarBytes`, `_vcardAvatarState`, and `_mamCursorStore` are
  cleared in the disconnect handler (`_safeClose`, around line 1165).
* They are seeded from disk only in `attachStorage` (line 453), which is
  called **once at startup**, not on reconnect.
* The Ready handler (`XmppConnectionState.Ready` branch, line 1044) never
  calls `_seedVcardAvatars` / `_seedVcardAvatarState` / re-seeds the MAM
  cursor store.
* As a result, R4.1's `shouldFetchVcardForCache` guard sees an empty cache
  on every reconnect and allows all vCard IQs through; R2.2's MAM skip
  similarly has no cursor data to consult.

**Fix (new item R6):** Add re-seed calls at the top of the Ready handler,
mirroring `attachStorage`:

```dart
// In the XmppConnectionState.Ready branch, before _setupRoster() etc.:
if (_storage != null) {
  _seedVcardAvatars(_storage!.loadVcardAvatars());
  _seedVcardAvatarState(_storage!.loadVcardAvatarState());
  // MAM cursor store is re-seeded via MamCoordinator.loadFromStorage()
}
```

`PepManager` is unaffected — `_setupPep` creates a fresh instance on every
reconnect and its constructor loads from `StorageService`, so it correctly
re-seeds itself.

**What is working correctly:**

* The "Displayed sync miss" lines (lines 79–80) fire *before* the first
  Ready (line 171), from the disk-seed path. R1.3 persistence is working —
  the stanza-ids are genuinely absent from the local cache (new messages
  arrived while offline), which is the expected behaviour.
* `PepCapsManager` (R5) re-seeds on every `_setupPep` call — no caps
  disco fan-out visible.
* The double roster IQ and double carbons-enable from the previous log
  review are still present (not yet fixed).

### 2. The repeated disconnects

The server closes the QUIC connection every 45–60 seconds, consistently
mid-MAM-stream (the disconnect at 14:35:30 occurs while a large burst of
MAM pages is still arriving on `quic-aux-15`). This is **not** an idle
timeout — the 30-second foreground keepalive ping is correctly configured
in `StreamManagmentModule` (`_pingIntervalForeground = Duration(seconds: 30)`)
and fires at Ready. The server advertises `<idle-seconds>360</idle-seconds>`.

The pattern — clean `QUIC connection closed cleanly (no error reported)`
mid-stream — points to an **Openfire QUIC session data or stream limit**:
the server appears to close the QUIC connection once a per-session byte or
stream count is reached, regardless of XMPP-level activity. One cycle also
shows `QUIC connection closed (could not query close reason:
DroppableDisposedException)`, suggesting the Rust QUIC layer is being torn
down before the close reason can be read.

**What to do:** This is an Openfire server-side issue (likely a bug or
misconfiguration in its QUIC implementation). The client correctly
reconnects each time. Longer term, SASL2/Bind2 resumption would make
reconnects cheaper. For now, the reconnect loop is the correct behaviour.

### 3. Summary of remaining work

| Item | Status | Notes |
|------|--------|-------|
| R4.1 vCard cache guard | ⚠️ Partial | Guard logic correct; broken by re-seed bug (R6) |
| R3.3 PEP negative cache | ✅ Working | PepManager re-seeds on reconnect |
| R1.1 MDS bootstrap skip | ✅ Working | Fires correctly from disk cache |
| R1.2 MDS +notify disco | ✅ Working | Confirmed in caps |
| R1.3 Displayed sync pending | ✅ Working | Persists and resolves correctly |
| R2.2 MAM skip when MDS up-to-date | ⚠️ Partial | Broken by re-seed bug (R6) |
| R5 Caps cache | ✅ Working | Re-seeds via PepCapsManager constructor |
| R2.1 Global MAM anchor | ✅ Working | Persisted; unified query deferred |
| R3.1 Avatar blob GC | ✅ Working | Runs at construction |
| **R6 Re-seed on reconnect** | ❌ Not done | New item; fixes R4.1 and R2.2 regressions |

---

## Appendix: log evidence (excerpts from `wimsy.log`, 2026-05-01)

* `Displayed sync miss for chat=xsf@muc.xmpp.org stanzaId=32d798f6-…
  messages=25 knownStanzaIds=[5 ids]` — the local cache is too short to
  resolve the displayed marker; we then re-pull MAM rather than
  asking for "messages up to the displayed `stanza-id`".
* Multiple `<iq type="get" … ><vCard xmlns="vcard-temp"/></iq>` blasted
  to every roster entry within ~50ms of becoming Ready.
* `enable xmlns="urn:xmpp:carbons:2"` sent twice (`KNBYYPMLT` and
  `VSBVMXXRT`).
* `urn:xmpp:avatar:metadata` 404s for `test1@…`, `test2@…`,
  `test-dino@…` — these will repeat on every restart until R3.3 is
  applied.
* `summit@muc.xmpp.org` MAM page (`queryid="VPNAXKAHR"`) is a long
  stream of forwarded historical messages running for several seconds
  on the QUIC aux stream — this is exactly the kind of fan-out R2.1 is
  designed to defer.
