import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// This test encodes the exact manual QA routine from the issue:
//
//   1. Clear cache and exit.
//   2. Re-run (cold start #1): no local displayed-sync state, nothing to
//      restore. The MDS `urn:xmpp:mds:displayed:0` bootstrap IQ-GET returns
//      whatever the server currently holds (nothing yet, for a fresh
//      account).
//   3. Mark everything read: the user opens every chat, which both sets the
//      local `readByMe` flag on each cached message (xmpp_service.dart's
//      `markMessagesRead`) *and* publishes a XEP-0490 "displayed" marker to
//      the server for the latest stanza in that chat (`selectChat` /
//      `_publishDisplayedState`, also re-published whenever a further live
//      message arrives — see `mds_publish_on_active_chat_test.dart`).
//   4. Clear cache and exit again: this wipes the local message cache and
//      the local `displayed_sync` store (see `StorageService.
//      clearDisplayedSync`), so the `readByMe` flags are gone and there is
//      no local displayed-cutoff. The *server-side* MDS node, however,
//      still holds the markers published in step 3.
//   5. Re-run (cold start #2): messages are reloaded (e.g. via MAM) with
//      `readByMe = false` (fresh objects), but the MDS bootstrap IQ-GET
//      restores the previously published stanza ids. Applying them sets a
//      `displayedAt` cutoff timestamp per chat
//      (`XmppService._applyDisplayedStateForChat`), and
//      `XmppService.isMessageUnseen` falls back to that cutoff when
//      `readByMe` is false — so every message up to and including the
//      marker must still read as "seen" even though the per-message flag
//      was lost.
//
// Everything below is a small, self-contained model of the relevant pieces
// of `xmpp_service.dart` so this round trip can be exercised without a live
// Connection / StorageService / Hive box.
// ---------------------------------------------------------------------------

class _FakeMessage {
  final String stanzaId;
  final DateTime timestamp;
  final bool outgoing = false;
  bool readByMe = false;

  _FakeMessage({
    required this.stanzaId,
    required this.timestamp,
  });
}

/// Mirrors `shouldFetchDisplayedSyncBootstrap` from
/// `startup_fetch_helpers.dart`.
bool _shouldFetchDisplayedSyncBootstrap({
  required bool hasCachedDisplayedSync,
}) {
  return !hasCachedDisplayedSync;
}

class _ColdStartModel {
  /// Stands in for the actual XMPP server: the `urn:xmpp:mds:displayed:0`
  /// private PEP node contents, keyed by chat bareJid -> stanza-id. This
  /// outlives local "clear cache" operations, exactly like the real server.
  final Map<String, String> serverMdsNode;

  /// Local, per-session state — everything here is wiped by "clear cache".
  Map<String, String> localDisplayedSync = {};
  Map<String, DateTime> localDisplayedAtByChat = {};
  final Map<String, List<_FakeMessage>> chats;

  _ColdStartModel({Map<String, String>? serverMdsNode, required this.chats})
      : serverMdsNode = serverMdsNode ?? {};

  /// Cold start: load whatever is left in local storage, then — mirroring
  /// R1.1 — only hit the network for the bootstrap IQ-GET when nothing was
  /// restored from disk.
  void coldStart() {
    final hasCachedDisplayedSync = localDisplayedSync.isNotEmpty;
    if (_shouldFetchDisplayedSyncBootstrap(
      hasCachedDisplayedSync: hasCachedDisplayedSync,
    )) {
      _applyBootstrapResult(Map<String, String>.from(serverMdsNode));
    }
  }

  /// Mirrors `_applyDisplayedSyncItems` / `_applyDisplayedStateForChat`:
  /// for every (chat, stanzaId) pair returned by the server, find the
  /// matching cached message and set the chat's displayed-at cutoff to its
  /// timestamp.
  void _applyBootstrapResult(Map<String, String> items) {
    items.forEach((chatJid, stanzaId) {
      localDisplayedSync[chatJid] = stanzaId;
      final list = chats[chatJid];
      if (list == null) {
        return;
      }
      for (final message in list) {
        if (message.stanzaId == stanzaId) {
          localDisplayedAtByChat[chatJid] = message.timestamp;
        }
      }
    });
  }

  /// Mirrors opening a chat: `markMessagesRead` (sets the per-message flag)
  /// plus `_publishDisplayedState`/`_sendDisplayedForChat` (publishes the
  /// MDS marker for the latest stanza to the server).
  void markChatReadAndPublish(String chatJid) {
    final list = chats[chatJid];
    if (list == null || list.isEmpty) {
      return;
    }
    for (final message in list) {
      if (!message.outgoing) {
        message.readByMe = true;
      }
    }
    final latest = list.last;
    serverMdsNode[chatJid] = latest.stanzaId;
  }

  /// Mirrors a full "clear cache and exit": wipes local displayed-sync
  /// state and per-message `readByMe` flags (as a fresh MAM reload would
  /// produce brand-new message objects with `readByMe = false`), but leaves
  /// the server-side MDS node untouched.
  void clearCacheAndExit() {
    localDisplayedSync = {};
    localDisplayedAtByChat = {};
    for (final list in chats.values) {
      for (final message in list) {
        message.readByMe = false;
      }
    }
  }

  /// Mirrors `XmppService.isMessageUnseen`.
  bool isMessageUnseen(String chatJid, _FakeMessage message) {
    if (message.outgoing) {
      return false;
    }
    if (message.readByMe) {
      return false;
    }
    final displayedAt = localDisplayedAtByChat[chatJid];
    if (displayedAt == null) {
      return true;
    }
    return message.timestamp.isAfter(displayedAt);
  }
}

void main() {
  group('Cold-start MDS read-state persistence (manual QA routine)', () {
    test(
      'clear cache -> cold start -> mark all read -> clear cache -> cold '
      'start again: everything previously marked read stays read',
      () {
        final chatJid = 'alice@example.com';
        final base = DateTime(2026, 1, 1, 12, 0, 0);
        final messages = [
          _FakeMessage(
            stanzaId: 'sid-1',
            timestamp: base,
          ),
          _FakeMessage(
            stanzaId: 'sid-2',
            timestamp: base.add(const Duration(minutes: 1)),
          ),
          _FakeMessage(
            stanzaId: 'sid-3',
            timestamp: base.add(const Duration(minutes: 2)),
          ),
        ];
        final model = _ColdStartModel(chats: {chatJid: messages});

        // Step 1+2: clear cache and exit, then cold start #1. The server
        // has no MDS state yet for a brand-new account, so nothing is
        // marked read and everything is unseen.
        model.coldStart();
        for (final message in messages) {
          expect(model.isMessageUnseen(chatJid, message), isTrue);
        }

        // Step 3: mark everything read (open the chat). This sets the
        // local readByMe flags and publishes the MDS marker for the
        // newest message to the server.
        model.markChatReadAndPublish(chatJid);
        for (final message in messages) {
          expect(model.isMessageUnseen(chatJid, message), isFalse);
        }
        expect(model.serverMdsNode[chatJid], 'sid-3');

        // Step 4: clear cache and exit again. The local readByMe flags and
        // displayed-sync cutoff are gone, but the server-side MDS node
        // still has the marker published in step 3.
        model.clearCacheAndExit();
        expect(model.localDisplayedSync, isEmpty);
        expect(model.localDisplayedAtByChat, isEmpty);
        for (final message in messages) {
          expect(message.readByMe, isFalse);
        }

        // Step 5: cold start #2. The bootstrap IQ-GET restores the marker
        // from the server, re-establishing the displayed-at cutoff, so
        // every message up to and including it must read as seen again —
        // "everything should stay read".
        model.coldStart();
        for (final message in messages) {
          expect(
            model.isMessageUnseen(chatJid, message),
            isFalse,
            reason:
                'message ${message.stanzaId} should still be read after '
                'the second cold start',
          );
        }
      },
    );

    test(
      'a message that arrives after the last clear-cache/mark-read cycle '
      'is still reported unseen post cold-start',
      () {
        final chatJid = 'alice@example.com';
        final base = DateTime(2026, 1, 1, 12, 0, 0);
        final messages = [
          _FakeMessage(stanzaId: 'sid-1', timestamp: base),
          _FakeMessage(
            stanzaId: 'sid-2',
            timestamp: base.add(const Duration(minutes: 1)),
          ),
        ];
        final model = _ColdStartModel(chats: {chatJid: messages});

        model.coldStart();
        // Only mark the chat read up to sid-1 (simulate the user viewing
        // the chat before sid-2 ever arrived), publishing only up to sid-1
        // instead of the latest known stanza.
        messages[0].readByMe = true;
        model.serverMdsNode[chatJid] = 'sid-1';

        model.clearCacheAndExit();
        model.coldStart();

        expect(model.isMessageUnseen(chatJid, messages[0]), isFalse);
        expect(model.isMessageUnseen(chatJid, messages[1]), isTrue);
      },
    );

    test(
      'an account with no prior MDS state on the server (true first-ever '
      'cold start) reports every incoming message as unseen',
      () {
        final chatJid = 'bob@example.com';
        final messages = [
          _FakeMessage(stanzaId: 'sid-1', timestamp: DateTime(2026, 1, 1)),
        ];
        final model = _ColdStartModel(chats: {chatJid: messages});

        model.coldStart();

        expect(model.isMessageUnseen(chatJid, messages[0]), isTrue);
      },
    );
  });
}
