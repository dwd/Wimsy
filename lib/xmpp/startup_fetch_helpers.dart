/// Pure helpers extracted from `xmpp_service.dart` so the connect-time
/// fetch-elision decisions tracked in `doc/startup-fetch-review.md` can be
/// unit-tested without spinning up a live Connection / StorageService.
///
/// Each function is intentionally tiny, side-effect free, and named after
/// the recommendation it implements (R1.1, R2.2, etc.). The corresponding
/// production code calls into them from `xmpp_service.dart`.
library;

/// R1.1 — skip the bootstrap `urn:xmpp:mds:displayed:0` PubSub items GET
/// when the in-memory map of displayed stanza ids was successfully restored
/// from disk on startup.
///
/// PEP +notify pushes (already handled by the existing event handler) keep
/// the cache live thereafter, so the IQ is only required on a true cold
/// start (no persisted MDS state for this account).
///
/// [hasCachedDisplayedSync] should be true when the in-memory
/// `_displayedStanzaIdByChat` map is non-empty after disk seeding.
///
/// [force] is provided for completeness — callers that genuinely want to
/// re-pull MDS regardless of cache (e.g. a manual "resync" command in the
/// UI) can pass true.
bool shouldFetchDisplayedSyncBootstrap({
  required bool hasCachedDisplayedSync,
  bool force = false,
}) {
  if (force) {
    return true;
  }
  return !hasCachedDisplayedSync;
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
