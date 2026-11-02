import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal self-contained model of the stanza-id/mam-id matching guard
// extracted from `XmppService._applyDisplayedStateForChat`.
//
// Bug (wimsy.log "monday morning" session): a XEP-0490 MDS marker's
// <stanza-id> `by` the room is only guaranteed to equal the message's MAM
// archive id (XEP-0313 `id` attribute on `<result>`) - some MUC services
// don't *also* duplicate that id into a `<stanza-id>` child on every
// archived message. `_applyDisplayedStateForChat` only compared against
// `message.stanzaId`, so for messages lacking an explicit `<stanza-id>`
// element the marker was reported as a "miss" even though the referenced
// message was present locally - leaving the chat's unread cutoff stuck at
// a stale fallback timestamp and causing already-read messages to reappear
// as unread on desktop after being read on mobile.
// ---------------------------------------------------------------------------

class _InboundMessage {
  const _InboundMessage({this.stanzaId, this.mamId});
  final String? stanzaId;
  final String? mamId;
}

class _DisplayedSyncModel {
  final Map<String, List<_InboundMessage>> messagesByChat = {};
  final Set<String> resolvedChats = {};

  void seedMessages(String chat, List<_InboundMessage> messages) {
    messagesByChat[chat] = messages;
  }

  /// Mirrors the matching loop in `_applyDisplayedStateForChat`.
  bool applyDisplayedState(String chat, String markerStanzaId) {
    final messages = messagesByChat[chat];
    if (messages == null || messages.isEmpty) {
      return false;
    }
    _InboundMessage? matched;
    for (final message in messages) {
      if (message.stanzaId == markerStanzaId || message.mamId == markerStanzaId) {
        matched = message;
      }
    }
    if (matched == null) {
      return false;
    }
    resolvedChats.add(chat);
    return true;
  }
}

void main() {
  group('R1.3: displayed-sync marker matches on mam id fallback', () {
    test(
      'marker matches a message that has an explicit <stanza-id>',
      () {
        final model = _DisplayedSyncModel();
        model.seedMessages('xsf@muc.xmpp.org', [
          const _InboundMessage(stanzaId: 'sid-1', mamId: 'mam-1'),
        ]);

        final resolved = model.applyDisplayedState('xsf@muc.xmpp.org', 'sid-1');

        expect(resolved, isTrue);
      },
    );

    test(
      'marker matches a message whose archive omitted <stanza-id>, '
      'falling back to its MAM archive id',
      () {
        final model = _DisplayedSyncModel();
        // Mirrors the gajim@conference.gajim.org case from wimsy.log: the
        // archived message had no <stanza-id> child, only a MAM result id
        // that equals the stanza-id `by` the room referenced in the marker.
        model.seedMessages('gajim@conference.gajim.org', [
          const _InboundMessage(mamId: '01a196b2-e3bf-7557-a02a-cd6fdd2a8aa5'),
        ]);

        final resolved = model.applyDisplayedState(
          'gajim@conference.gajim.org',
          '01a196b2-e3bf-7557-a02a-cd6fdd2a8aa5',
        );

        expect(resolved, isTrue);
        expect(model.resolvedChats, contains('gajim@conference.gajim.org'));
      },
    );

    test(
      'marker referencing a stanza-id that matches neither field is still '
      'a miss',
      () {
        final model = _DisplayedSyncModel();
        model.seedMessages('open_chat@conference.igniterealtime.org', [
          const _InboundMessage(stanzaId: 'sid-old', mamId: 'mam-old'),
        ]);

        final resolved = model.applyDisplayedState(
          'open_chat@conference.igniterealtime.org',
          'sid-unknown',
        );

        expect(resolved, isFalse);
      },
    );
  });
}
