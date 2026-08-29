import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/models/contact_entry.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

ChatMessage _message(String id) => ChatMessage(
  from: 'room@example.com',
  to: 'me@example.com',
  body: id,
  timestamp: DateTime.utc(2026, 1, 1),
  outgoing: false,
  messageId: id,
  rawXml: "<message id='$id'><body>$id</body></message>",
);

void main() {
  const jid = 'room@example.com';

  test('removing a contact expunges its direct chat and persisted cache', () {
    final persisted = <String, List<ChatMessage>>{};
    final service = XmppService()
      ..setMessagePersistor((jid, messages) {
        persisted[jid] = List.of(messages);
      })
      ..seedMessages({
        jid: [_message('direct')],
      })
      ..selectChat(jid);

    service.expungeDirectContactDataForTesting(jid);

    expect(service.contacts, isEmpty);
    expect(service.messagesFor(jid), isEmpty);
    expect(service.activeChatBareJid, isNull);
    expect(persisted[jid], isEmpty);
  });

  test('removed person can be re-added as a room without direct history', () {
    final service = XmppService()
      ..seedMessages({
        jid: [_message('direct')],
      })
      ..seedRoomMessages({
        jid: [_message('room')],
      });

    service.expungeDirectContactDataForTesting(jid);
    service.seedBookmarks([
      ContactEntry(jid: jid, isBookmark: true, name: 'The Room'),
    ]);

    expect(service.messagesFor(jid), isEmpty);
    expect(service.roomMessagesFor(jid).single.body, 'room');
    expect(service.contacts, hasLength(1));
    expect(service.contacts.single.isBookmark, isTrue);
  });

  test('expunged direct cache cannot recreate the contact on reseed', () {
    final persisted = <String, List<ChatMessage>>{};
    final service = XmppService()
      ..setMessagePersistor((jid, messages) {
        persisted[jid] = List.of(messages);
      })
      ..seedMessages({
        jid: [_message('direct')],
      });

    service.expungeDirectContactDataForTesting(jid);

    final diskSnapshot = Map<String, List<ChatMessage>>.fromEntries(
      persisted.entries.where((entry) => entry.value.isNotEmpty),
    );
    final restarted = XmppService()..seedMessages(diskSnapshot);
    expect(restarted.contacts, isEmpty);
    expect(restarted.messagesFor(jid), isEmpty);
  });
}
