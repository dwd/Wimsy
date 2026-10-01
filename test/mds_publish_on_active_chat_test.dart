import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal self-contained model of the "publish XEP-0490 MDS displayed state
// while a chat is actively open" logic extracted from XmppService, so it can
// be tested without a real XMPP stack.
//
// The production code lives in xmpp_service.dart:
//   - `selectChat()` calls `_publishDisplayedState(bareJid)` once, when the
//     chat is first opened in the UI.
//   - `_addMessage()` (DMs) and `_addRoomMessage()` (MUC) now also call
//     `_publishDisplayedState(bareJid)` whenever a *live* incoming message
//     (not a MAM-replayed/backfilled one) arrives for whichever chat is
//     currently `_activeChatBareJid`. Without this, the MDS state on the
//     server would only ever record a single "displayed" marker per chat —
//     the one sent the moment the chat was opened — and would never advance
//     as further messages arrived while the chat stayed open.
//   - `_publishDisplayedState` itself is idempotent: it tracks the last
//     stanza-id it published per chat and skips re-publishing when nothing
//     changed.
// ---------------------------------------------------------------------------

class _DisplayedStateModel {
  String? activeChatBareJid;
  final Map<String, String> lastPublishedStanzaIdByChat = {};
  final List<String> publishCalls = [];

  void selectChat(String? bareJid) {
    activeChatBareJid = bareJid;
    if (bareJid != null) {
      _publishDisplayedState(bareJid, latestStanzaId: 'seed-stanza-id');
    }
  }

  /// Mirrors the live-message branch added to `_addMessage`/
  /// `_addRoomMessage`: only live (non-MAM-backfill) incoming messages for
  /// the currently active chat trigger a fresh publish.
  void receiveLiveIncomingMessage(
    String bareJid, {
    required String stanzaId,
    bool outgoing = false,
    bool hasMamId = false,
    bool catchUpComplete = true,
  }) {
    if (!outgoing && !hasMamId && catchUpComplete && bareJid == activeChatBareJid) {
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

        model.receiveLiveIncomingMessage(
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

        model.receiveLiveIncomingMessage(
          'bob@example.com',
          stanzaId: 'live-stanza-1',
        );

        expect(model.publishCalls, ['alice@example.com:seed-stanza-id']);
      },
    );

    test('outgoing messages never trigger a publish', () {
      final model = _DisplayedStateModel();
      model.selectChat('alice@example.com');

      model.receiveLiveIncomingMessage(
        'alice@example.com',
        stanzaId: 'live-stanza-1',
        outgoing: true,
      );

      expect(model.publishCalls, ['alice@example.com:seed-stanza-id']);
    });

    test(
      'MAM-backfilled messages (not yet caught up, or carrying a mam id) do '
      'not trigger a publish even for the active chat',
      () {
        final model = _DisplayedStateModel();
        model.selectChat('alice@example.com');

        model.receiveLiveIncomingMessage(
          'alice@example.com',
          stanzaId: 'mam-stanza-1',
          hasMamId: true,
        );
        model.receiveLiveIncomingMessage(
          'alice@example.com',
          stanzaId: 'catchup-stanza-1',
          catchUpComplete: false,
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

        model.receiveLiveIncomingMessage(
          'alice@example.com',
          stanzaId: 'live-stanza-1',
        );
        model.receiveLiveIncomingMessage(
          'alice@example.com',
          stanzaId: 'live-stanza-1',
        );
        model.receiveLiveIncomingMessage(
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
