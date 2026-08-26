import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

ChatMessage _message({String? messageId, String? mamId, String? stanzaId}) {
  return ChatMessage(
    from: 'alice',
    to: 'room@conference.example',
    body: 'hello',
    timestamp: DateTime.utc(2026),
    outgoing: false,
    messageId: messageId,
    mamId: mamId,
    stanzaId: stanzaId,
  );
}

void main() {
  final service = XmppService();

  test('MUC reactions fall back to the room MAM id', () {
    final target = service.reactionTargetIdForMessage(
      _message(messageId: 'forwarded-id', mamId: 'room-archive-id'),
      isRoom: true,
    );

    expect(target, 'room-archive-id');
  });

  test('live MUC reactions prefer the room stanza id', () {
    final target = service.reactionTargetIdForMessage(
      _message(
        messageId: 'message-id',
        mamId: 'archive-id',
        stanzaId: 'room-stanza-id',
      ),
      isRoom: true,
    );

    expect(target, 'room-stanza-id');
  });

  test('direct-message reactions use the message id, not the MAM id', () {
    final target = service.reactionTargetIdForMessage(
      _message(messageId: 'message-id', mamId: 'personal-archive-id'),
      isRoom: false,
    );

    expect(target, 'message-id');
  });
}
