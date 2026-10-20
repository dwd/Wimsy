import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal self-contained model of the "publish XEP-0490 MDS displayed state
// while a chat is actively open" logic extracted from XmppService, so it can
// be tested without a real XMPP stack.
//
// The production code lives in xmpp_service.dart:
//   - `selectChat()` calls `_publishDisplayedState(bareJid)` once, when the
//     chat is first opened in the UI. This runs *before* any MAM catch-up
//     response for that chat can possibly have arrived.
//   - `_addMessage()` (DMs) and `_addRoomMessage()` (MUC) call
//     `_publishDisplayedState(bareJid)` whenever *any* incoming message
//     (live, or delivered later by a MAM catch-up page) arrives for
//     whichever chat is currently `_activeChatBareJid`. Without this, a
//     device that opens a chat while behind on history would publish a
//     stale marker for the pre-catch-up state and never advance it once the
//     missing messages actually arrived — leaving that chat shown as
//     unread on other devices/desktop even though it had genuinely been
//     opened and viewed (see the "Message Displayed Sync" investigation).
//   - The separate `incomingMessageHandler`/`incomingRoomMessageHandler`
//     notification callbacks are still gated on `!hasMamId && catchUpComplete`
//     (and `shouldNotifyRoom` for MUC) — we don't want to pop a "new
//     message" notification for backfilled history — but that gating must
//     not also suppress the displayed-state republish.
//   - `_publishDisplayedState` itself is idempotent: it tracks the last
//     stanza-id it published per chat and skips re-publishing when nothing
//     changed.
// ---------------------------------------------------------------------------

class _DisplayedStateModel {
  String? activeChatBareJid;
  final Map<String, String> lastPublishedStanzaIdByChat = {};
  final List<String> publishCalls = [];
  final List<String> notificationCalls = [];

  void selectChat(String? bareJid) {
    activeChatBareJid = bareJid;
    if (bareJid != null) {
      _publishDisplayedState(bareJid, latestStanzaId: 'seed-stanza-id');
    }
  }

  /// Mirrors the incoming-message branches in `_addMessage`/
  /// `_addRoomMessage`: the notification handler is only invoked for live
  /// (non-MAM-backfill, caught-up) messages, but the displayed-state publish
  /// fires for *any* incoming message — live or MAM-backfilled — as long as
  /// the chat is the one currently active.
  void receiveIncomingMessage(
    String bareJid, {
    required String stanzaId,
    bool outgoing = false,
    bool hasMamId = false,
    bool catchUpComplete = true,
  }) {
    if (outgoing) {
      return;
    }
    if (!hasMamId && catchUpComplete) {
      notificationCalls.add('$bareJid:$stanzaId');
    }
    if (bareJid == activeChatBareJid) {
      _publishDisplayedState(bareJid, latestStanzaId: stanzaId);
    }
  }

  void _publishDisplayedState(String bareJid, {required String latestStanzaId}) {
    if (lastPublishedStanzaIdByChat[bareJid] == latestStanzaId) {
      return;
    }
    lastPublishedStanzaIdByChat[bareJid] = latestStanzaId;
    publishCalls.add('$bareJid:$latestStanzaId');
  }
}

void main() {
  group('MDS displayed-state publish stays current for the active chat', () {
    test('opening a chat publishes the seed displayed marker once', () {
      final model = _DisplayedStateModel();

      model.selectChat('alice@example.com');

      expect(model.publishCalls, ['alice@example.com:seed-stanza-id']);
    });

    test(
      'a live incoming message to the already-open chat republishes with '
      'the new stanza id',
      () {
        final model = _DisplayedStateModel();
        model.selectChat('alice@example.com');

        model.receiveIncomingMessage(
          'alice@example.com',
          stanzaId: 'live-stanza-1',
        );

        expect(model.publishCalls, [
          'alice@example.com:seed-stanza-id',
          'alice@example.com:live-stanza-1',
        ]);
      },
    );

    test(
      'a live incoming message to a chat that is not currently active does '
      'not publish',
      () {
        final model = _DisplayedStateModel();
        model.selectChat('alice@example.com');

        model.receiveIncomingMessage(
          'bob@example.com',
          stanzaId: 'live-stanza-1',
        );

        expect(model.publishCalls, ['alice@example.com:seed-stanza-id']);
      },
    );

    test('outgoing messages never trigger a publish', () {
      final model = _DisplayedStateModel();
      model.selectChat('alice@example.com');

      model.receiveIncomingMessage(
        'alice@example.com',
        stanzaId: 'live-stanza-1',
        outgoing: true,
      );

      expect(model.publishCalls, ['alice@example.com:seed-stanza-id']);
    });

    test(
      'MAM-backfilled messages for the active chat still republish the '
      'displayed marker, even though they do not fire the notification '
      'handler',
      () {
        final model = _DisplayedStateModel();
        model.selectChat('alice@example.com');

        model.receiveIncomingMessage(
          'alice@example.com',
          stanzaId: 'mam-stanza-1',
          hasMamId: true,
        );
        model.receiveIncomingMessage(
          'alice@example.com',
          stanzaId: 'catchup-stanza-1',
          catchUpComplete: false,
        );

        expect(model.publishCalls, [
          'alice@example.com:seed-stanza-id',
          'alice@example.com:mam-stanza-1',
          'alice@example.com:catchup-stanza-1',
        ]);
        expect(model.notificationCalls, isEmpty);
      },
    );

    test(
      'a MAM-backfilled message for a chat that is not currently active '
      'does not publish',
      () {
        final model = _DisplayedStateModel();
        model.selectChat('alice@example.com');

        model.receiveIncomingMessage(
          'bob@example.com',
          stanzaId: 'mam-stanza-1',
          hasMamId: true,
        );

        expect(model.publishCalls, ['alice@example.com:seed-stanza-id']);
      },
    );

    test(
      'repeated live messages in the same active chat only publish when the '
      'stanza id actually changes',
      () {
        final model = _DisplayedStateModel();
        model.selectChat('alice@example.com');

        model.receiveIncomingMessage(
          'alice@example.com',
          stanzaId: 'live-stanza-1',
        );
        model.receiveIncomingMessage(
          'alice@example.com',
          stanzaId: 'live-stanza-1',
        );
        model.receiveIncomingMessage(
          'alice@example.com',
          stanzaId: 'live-stanza-2',
        );

        expect(model.publishCalls, [
          'alice@example.com:seed-stanza-id',
          'alice@example.com:live-stanza-1',
          'alice@example.com:live-stanza-2',
        ]);
      },
    );
  });
}
