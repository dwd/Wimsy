import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal self-contained model of the "don't replay a stale cached MDS
// publish on reconnect" guard extracted from
// XmppService._replayControlMessageOutbox / _retryPendingMdsPublish.
//
// The production code lives in xmpp_service.dart:
//   - `_replayControlMessageOutbox()` used to resend the frozen
//     `operation.referencedId` that was cached in the control-message
//     outbox at the moment a XEP-0490 "displayed" publish failed, for
//     *every* pending chat, immediately on every reconnect - before any
//     MAM catch-up for that reconnect could possibly have run. Since the
//     MDS node is a single, per-user PEP item per chat shared by every one
//     of the account's devices, republishing a stale, possibly long-ago
//     cached snapshot on every reconnect risked asserting a *regressed*
//     "displayed" position - making an already-read chat look unread again
//     on other devices (wimsy.log showed a burst of a dozen-plus chats
//     getting an MDS publish on literally every single reconnect).
//   - `_retryPendingMdsPublish()` now only retries a pending MDS operation
//     once that chat's MAM history is known to be fully caught up (so the
//     local message list is authoritative, not behind what other devices
//     may have already advanced to), and even then it recomputes the
//     "displayed" stanza-id fresh from the current local message list
//     rather than trusting the value cached in the outbox.
// ---------------------------------------------------------------------------

class _InboundMessage {
  const _InboundMessage(this.stanzaId);
  final String stanzaId;
}

class _MdsReplayModel {
  final Map<String, String> pendingOutbox = {};
  final Map<String, bool> catchUpCompleteByChat = {};
  final Map<String, List<_InboundMessage>> messagesByChat = {};
  final List<String> publishCalls = [];

  void queuePending(String chat, String stanzaId) {
    pendingOutbox[chat] = stanzaId;
  }

  void setCatchUpComplete(String chat, bool complete) {
    catchUpCompleteByChat[chat] = complete;
  }

  void seedMessages(String chat, List<_InboundMessage> messages) {
    messagesByChat[chat] = messages;
  }

  /// Mirrors `_replayControlMessageOutbox` -> `_retryPendingMdsPublish`.
  void replayControlMessageOutbox() {
    for (final chat in pendingOutbox.keys.toList(growable: false)) {
      _retryPendingMdsPublish(chat);
    }
  }

  void _retryPendingMdsPublish(String chat) {
    if (catchUpCompleteByChat[chat] != true) {
      // Not confirmed current yet - leave pending, do not publish.
      return;
    }
    final messages = messagesByChat[chat];
    if (messages == null || messages.isEmpty) {
      return;
    }
    final latest = messages.last;
    publishCalls.add('$chat:${latest.stanzaId}');
    pendingOutbox[chat] = latest.stanzaId;
  }
}

void main() {
  group('MDS outbox replay on reconnect', () {
    test(
      'a pending publish for a chat whose MAM catch-up is not complete is '
      'not replayed',
      () {
        final model = _MdsReplayModel();
        model.queuePending('alice@example.com', 'stale-stanza-id');
        model.setCatchUpComplete('alice@example.com', false);
        model.seedMessages('alice@example.com', [
          const _InboundMessage('stale-stanza-id'),
        ]);

        model.replayControlMessageOutbox();

        expect(model.publishCalls, isEmpty);
      },
    );

    test(
      'a pending publish for a caught-up chat is replayed using the '
      'current local message list, not the frozen cached stanza-id',
      () {
        final model = _MdsReplayModel();
        // The outbox still remembers the old, now-superseded stanza-id from
        // when the original publish failed.
        model.queuePending('alice@example.com', 'stale-stanza-id');
        model.setCatchUpComplete('alice@example.com', true);
        // Since that failed attempt, the local history has moved on.
        model.seedMessages('alice@example.com', [
          const _InboundMessage('stale-stanza-id'),
          const _InboundMessage('fresh-stanza-id'),
        ]);

        model.replayControlMessageOutbox();

        expect(model.publishCalls, ['alice@example.com:fresh-stanza-id']);
      },
    );

    test(
      'a chat with no local messages yet is skipped even if caught up',
      () {
        final model = _MdsReplayModel();
        model.queuePending('bob@example.com', 'stale-stanza-id');
        model.setCatchUpComplete('bob@example.com', true);

        model.replayControlMessageOutbox();

        expect(model.publishCalls, isEmpty);
      },
    );

    test(
      'multiple pending chats are each gated independently on their own '
      'catch-up status',
      () {
        final model = _MdsReplayModel();
        model.queuePending('caught-up@example.com', 'old-1');
        model.setCatchUpComplete('caught-up@example.com', true);
        model.seedMessages('caught-up@example.com', [
          const _InboundMessage('old-1'),
        ]);

        model.queuePending('not-caught-up@example.com', 'old-2');
        model.setCatchUpComplete('not-caught-up@example.com', false);
        model.seedMessages('not-caught-up@example.com', [
          const _InboundMessage('old-2'),
        ]);

        model.replayControlMessageOutbox();

        expect(model.publishCalls, ['caught-up@example.com:old-1']);
      },
    );
  });
}
