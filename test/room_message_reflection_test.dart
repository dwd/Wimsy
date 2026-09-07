import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/models/room_entry.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  const roomJid = 'room@conference.example';
  late XmppService service;
  late List<ChatMessage> persisted;

  setUp(() {
    service = XmppService();
    service.seedConnectedRoomForTesting(
      RoomEntry(roomJid: roomJid, nick: 'alice', joined: true),
    );
    persisted = [];
    service.setRoomMessagePersistor((jid, messages) {
      expect(jid, roomJid);
      persisted = messages;
    });
    addTearDown(service.dispose);
  });

  MucMessage received(String id, String nick, DateTime timestamp) => MucMessage(
    roomJid: roomJid,
    nick: nick,
    body: id,
    messageId: id,
    stanzaId: 'room-$id',
    timestamp: timestamp,
  );

  for (final clockAhead in [false, true]) {
    test('reflection reorders and persists a local message '
        'with the sender clock ${clockAhead ? 'ahead' : 'behind'}', () {
      service.sendRoomMessage(roomJid, 'hello');
      final local = service.roomMessagesFor(roomJid).single;
      final reflectedAt = local.timestamp.add(
        Duration(minutes: clockAhead ? -2 : 2),
      );
      final otherAt = reflectedAt.subtract(const Duration(seconds: 1));
      service.handleRoomMessageForTesting(received('other', 'bob', otherAt));
      expect(
        service.roomMessagesFor(roomJid).map((message) => message.messageId),
        clockAhead ? ['other', local.messageId] : [local.messageId, 'other'],
      );

      service.handleRoomMessageForTesting(
        received(local.messageId!, 'alice', reflectedAt),
      );
      final messages = service.roomMessagesFor(roomJid);
      expect(messages.map((message) => message.messageId), [
        'other',
        local.messageId,
      ]);
      expect(messages.last.timestamp, reflectedAt);
      expect(messages.last.outgoing, isTrue);
      expect(messages.last.receiptReceived, isTrue);
      expect(messages.last.body, 'hello');
      expect(messages.last.stanzaId, 'room-${local.messageId}');
      expect(persisted, messages);

      // A replay with a new receive time must not move a confirmed message.
      service.handleRoomMessageForTesting(
        received('later', 'bob', reflectedAt.add(const Duration(seconds: 1))),
      );
      service.handleRoomMessageForTesting(
        received(
          local.messageId!,
          'alice',
          reflectedAt.add(const Duration(minutes: 1)),
        ),
      );
      expect(
        service.roomMessagesFor(roomJid).map((message) => message.messageId),
        ['other', local.messageId, 'later'],
      );
      expect(service.roomMessagesFor(roomJid)[1].timestamp, reflectedAt);
    });
  }

  test(
    'equal timestamps follow reflection order and stay stable on replay',
    () {
      service.sendRoomMessage(roomJid, 'hello');
      final local = service.roomMessagesFor(roomJid).single;
      service.handleRoomMessageForTesting(
        received('other', 'bob', local.timestamp),
      );
      service.handleRoomMessageForTesting(
        received(local.messageId!, 'alice', local.timestamp),
      );
      service.handleRoomMessageForTesting(
        received('later', 'bob', local.timestamp),
      );
      // Additional archive metadata must not change the established order.
      service.handleRoomMessageForTesting(
        MucMessage(
          roomJid: roomJid,
          nick: 'alice',
          body: 'hello',
          messageId: local.messageId,
          stanzaId: 'room-${local.messageId}',
          mamResultId: 'archive-id',
          timestamp: local.timestamp,
        ),
      );
      expect(
        service.roomMessagesFor(roomJid).map((message) => message.messageId),
        ['other', local.messageId, 'later'],
      );
      expect(service.roomMessagesFor(roomJid)[1].mamId, 'archive-id');
      expect(persisted, service.roomMessagesFor(roomJid));
    },
  );

  test('self-reflection without a local copy is already confirmed', () {
    final timestamp = DateTime.utc(2026, 1, 1);
    service.handleRoomMessageForTesting(received('own', 'alice', timestamp));
    final message = service.roomMessagesFor(roomJid).single;
    expect(message.outgoing, isTrue);
    expect(message.receiptReceived, isTrue);
    expect(message.timestamp, timestamp);
    expect(persisted.single, message);
  });

  test(
    'another occupant with the same ID does not confirm the local message',
    () {
      service.sendRoomMessage(roomJid, 'hello');
      final local = service.roomMessagesFor(roomJid).single;
      service.handleRoomMessageForTesting(
        received(
          local.messageId!,
          'bob',
          local.timestamp.add(const Duration(seconds: 1)),
        ),
      );
      final messages = service.roomMessagesFor(roomJid);
      expect(messages, hasLength(2));
      expect(messages.first.timestamp, local.timestamp);
      expect(messages.first.receiptReceived, isFalse);
      expect(messages.last.outgoing, isFalse);
    },
  );
}
