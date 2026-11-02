/// Pure helpers extracted from `xmpp_service.dart` so the connect-time
/// fetch-elision decisions tracked in `doc/startup-fetch-review.md` can be
/// unit-tested without spinning up a live Connection / StorageService.
///
/// Each function is intentionally tiny, side-effect free, and named after
/// the recommendation it implements (R1.1, R2.2, etc.). The corresponding
/// production code calls into them from `xmpp_service.dart`.
library;

/// R1.1 (REVERTED — see wimsy2.log "already-read messages shown unread"
/// bug): this used to skip the bootstrap `urn:xmpp:mds:displayed:0`
/// PubSub items GET whenever the in-memory map of displayed stanza ids was
/// restored from disk on startup, on the assumption that PEP `+notify`
/// pushes would keep the cache live thereafter.
///
/// That assumption is false for a device that was offline (e.g. the
/// desktop client over a weekend while the user read messages on mobile):
/// `+notify` only delivers *live* publishes to currently-subscribed,
/// online resources. There is no XEP-0060/XEP-0163 mechanism in use here
/// to replay MDS items published while this device was disconnected, so
/// skipping the bootstrap IQ left `_displayedStanzaIdByChat` pinned to a
/// stale, possibly weeks-old marker forever — reproduced in
/// `wimsy2.log`, where `gajim@conference.gajim.org` and
/// `xsf@muc.xmpp.org` kept a stanza-id far older than the already-cached,
/// already-read local messages, making them reappear as unread on every
/// restart.
///
/// The bootstrap IQ is a single cheap PubSub items GET, so we now always
/// issue it on connect regardless of cache state. [hasCachedDisplayedSync]
/// and [force] are kept for API/test compatibility (and so a future,
/// genuinely gap-aware skip — e.g. based on last-connected time — can be
/// reintroduced safely), but the function unconditionally returns true.
bool shouldFetchDisplayedSyncBootstrap({
  required bool hasCachedDisplayedSync,
  bool force = false,
}) {
  return true;
}

/// R2.2 — skip the per-chat MAM catch-up `<query/>` when the displayed
/// marker we already have on disk points at a stanza whose MAM id matches
/// the latest local MAM id for the same chat. Under those conditions we are
/// demonstrably caught up to the displayed marker and there is nothing the
/// catch-up query could give us beyond what +notify / live messages already
/// will.
///
/// All three pieces of context come from `xmpp_service.dart`'s in-memory
/// state:
///
///   * [displayedStanzaId] — the stanza-id MDS reports as displayed in this
///     chat. Empty / null when MDS has nothing for the chat.
///   * [latestLocalMamId] — the MAM id of the newest message in our local
///     cache. Null when the chat has no cached messages.
///   * [stanzaIdAtLatestMamId] — the stanza-id of that newest cached
///     message. Null when missing.
///
/// Returns true when the catch-up query should still go out.
bool shouldFetchMamCatchUpForChat({
  required String? displayedStanzaId,
  required String? latestLocalMamId,
  required String? stanzaIdAtLatestMamId,
}) {
  // No MDS marker — we don't know whether we're caught up, so fetch.
  if (displayedStanzaId == null || displayedStanzaId.isEmpty) {
    return true;
  }
  // No local MAM cursor — nothing to compare against, so fetch.
  if (latestLocalMamId == null || latestLocalMamId.isEmpty) {
    return true;
  }
  // Latest local message has no recorded stanza-id — be safe and fetch.
  if (stanzaIdAtLatestMamId == null || stanzaIdAtLatestMamId.isEmpty) {
    return true;
  }
  // Marker matches the latest local message: caught up.
  return displayedStanzaId != stanzaIdAtLatestMamId;
}
