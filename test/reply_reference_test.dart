import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

/// Builds a minimal [ChatMessage] suitable for reply-reference tests.
ChatMessage _mucMessage({
  required String from,
  required String messageId,
  String? stanzaId,
}) {
  return ChatMessage(
    from: from,
    to: 'room@conference.example',
    body: 'hello',
    timestamp: DateTime.utc(2024, 1, 1),
    outgoing: false,
    messageId: messageId,
    stanzaId: stanzaId,
    rawXml: '<message/>',
  );
}

ChatMessage _chatMessage({
  required String from,
  required String messageId,
  String? stanzaId,
}) {
  return ChatMessage(
    from: from,
    to: 'bob@example.com',
    body: 'hello',
    timestamp: DateTime.utc(2024, 1, 1),
    outgoing: false,
    messageId: messageId,
    stanzaId: stanzaId,
    rawXml: '<message/>',
  );
}

void main() {
  group('buildReplyReference MUC', () {
    final service = XmppService();

    test('uses chatroom stanza-id (XEP-0359) for MUC reply', () {
      final message = _mucMessage(
        from: 'alice',
        messageId: 'stanza-own-id',
        stanzaId: 'room-applied-stanza-id',
      );

      final ref = service.buildReplyReference(
        chatJid: 'room@conference.example',
        message: message,
        isRoom: true,
      );

      expect(ref, isNotNull,
          reason: 'should produce a reference when stanzaId is set');
      expect(ref!.id, 'room-applied-stanza-id',
          reason: 'MUC reply must use the room-applied stanza-id per XEP-0461');
    });

    test('returns null for MUC reply when no room stanza-id is available', () {
      // When the room has not assigned a stanza-id the client cannot build
      // a valid XEP-0461 reply reference; returning null is the correct
      // behaviour (no <reply> element will be included in the outgoing stanza).
      final message = _mucMessage(
        from: 'alice',
        messageId: 'stanza-own-id',
        stanzaId: null,
      );

      final ref = service.buildReplyReference(
        chatJid: 'room@conference.example',
        message: message,
        isRoom: true,
      );

      expect(ref, isNull,
          reason:
              'must not fall back to the stanza own id for a MUC reply per XEP-0461');
    });
  });

  group('buildReplyReference 1:1 chat', () {
    final service = XmppService();

    test('ignores stanzaId when available for 1:1 chat reply', () {
      final message = _chatMessage(
        from: 'alice@example.com',
        messageId: 'msg-id',
        stanzaId: 'server-stanza-id',
      );

      final ref = service.buildReplyReference(
        chatJid: 'alice@example.com',
        message: message,
        isRoom: false,
      );

      expect(ref, isNotNull);
      expect(ref!.id, 'msg-id');
    });

    test('falls back to messageId for 1:1 chat reply when stanzaId is absent',
        () {
      final message = _chatMessage(
        from: 'alice@example.com',
        messageId: 'msg-id',
        stanzaId: null,
      );

      final ref = service.buildReplyReference(
        chatJid: 'alice@example.com',
        message: message,
        isRoom: false,
      );

      expect(ref, isNotNull);
      expect(ref!.id, 'msg-id');
    });
  });
}
