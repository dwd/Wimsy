import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/room_entry.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

// XEP-0491: verifies that widget offers and state updates arriving in a
// MUC room are recognised the same way they already are for 1:1 chats
// (see message_intents_test.dart for the underlying stanza-parsing/intent
// coverage), by driving XmppService._handleRoomMessage directly via
// handleRoomMessageForTesting.
void main() {
  const roomJid = 'room@conference.example';
  late XmppService service;

  setUp(() {
    service = XmppService();
    service.seedConnectedRoomForTesting(
      RoomEntry(roomJid: roomJid, nick: 'alice', joined: true),
    );
    addTearDown(service.dispose);
  });

  MessageStanza offerStanza({
    required String id,
    required String threadId,
    required String oobUrl,
  }) {
    final stanza = MessageStanza(id, MessageStanzaType.GROUPCHAT);
    stanza.fromJid = Jid.fromFullJid('$roomJid/bob');
    final thread = XmppElement()..name = 'thread';
    thread.textValue = threadId;
    stanza.addChild(thread);
    final oob = XmppElement()..name = 'x';
    oob.addAttribute(XmppAttribute('xmlns', 'jabber:x:oob'));
    final url = XmppElement()..name = 'url';
    url.textValue = oobUrl;
    oob.addChild(url);
    stanza.addChild(oob);
    return stanza;
  }

  MessageStanza updateStanza({
    required String id,
    required String threadId,
    String? document,
    String? summary,
    String? json,
    String? body,
  }) {
    final stanza = MessageStanza(id, MessageStanzaType.GROUPCHAT);
    stanza.fromJid = Jid.fromFullJid('$roomJid/bob');
    final thread = XmppElement()..name = 'thread';
    thread.textValue = threadId;
    stanza.addChild(thread);
    final x = XmppElement()..name = 'x';
    x.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:webxdc:0'));
    if (document != null) {
      final documentElement = XmppElement()..name = 'document';
      documentElement.textValue = document;
      x.addChild(documentElement);
    }
    if (summary != null) {
      final summaryElement = XmppElement()..name = 'summary';
      summaryElement.textValue = summary;
      x.addChild(summaryElement);
    }
    if (json != null) {
      final jsonElement = XmppElement()..name = 'json';
      jsonElement.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:json:0'));
      jsonElement.textValue = json;
      x.addChild(jsonElement);
    }
    stanza.addChild(x);
    if (body != null) {
      stanza.body = body;
    }
    return stanza;
  }

  test('a widget offer arriving in a room is recognised', () {
    final stanza = offerStanza(
      id: 'offer-1',
      threadId: 'thread-1',
      oobUrl: 'https://upload.example/calendar.xdc',
    );
    service.handleRoomMessageForTesting(
      MucMessage(
        roomJid: roomJid,
        nick: 'bob',
        body: '',
        messageId: 'offer-1',
        timestamp: DateTime.utc(2026, 1, 1),
        oobUrl: 'https://upload.example/calendar.xdc',
        rawStanza: stanza,
      ),
    );

    final message = service.roomMessagesFor(roomJid).single;
    expect(message.isWebxdcWidget, isTrue);
    expect(message.webxdcThreadId, 'thread-1');
    expect(message.oobUrl, 'https://upload.example/calendar.xdc');
    expect(message.oobDescription, 'calendar.xdc');
  });

  test(
    'a follow-up state update merges into the stored offer and adds an '
    'info bubble',
    () {
      final offer = offerStanza(
        id: 'offer-2',
        threadId: 'thread-2',
        oobUrl: 'https://upload.example/calendar.xdc',
      );
      service.handleRoomMessageForTesting(
        MucMessage(
          roomJid: roomJid,
          nick: 'bob',
          body: '',
          messageId: 'offer-2',
          timestamp: DateTime.utc(2026, 1, 1),
          oobUrl: 'https://upload.example/calendar.xdc',
          rawStanza: offer,
        ),
      );

      final update = updateStanza(
        id: 'update-1',
        threadId: 'thread-2',
        document: 'Our Calendar',
        summary: '12 events',
        json: '{"foo":1}',
        body: 'Juliet has added an event.',
      );
      service.handleRoomMessageForTesting(
        MucMessage(
          roomJid: roomJid,
          nick: 'bob',
          body: 'Juliet has added an event.',
          messageId: 'update-1',
          timestamp: DateTime.utc(2026, 1, 1, 0, 1),
          rawStanza: update,
        ),
      );

      final messages = service.roomMessagesFor(roomJid);
      expect(messages, hasLength(2));
      final offerMessage = messages.firstWhere(
        (message) => message.isWebxdcWidget,
      );
      expect(offerMessage.webxdcDocument, 'Our Calendar');
      expect(offerMessage.webxdcSummary, '12 events');
      expect(offerMessage.webxdcJsonPayload, '{"foo":1}');
      final infoMessage = messages.firstWhere(
        (message) => !message.isWebxdcWidget,
      );
      expect(infoMessage.body, 'Juliet has added an event.');
    },
  );

  test(
    'a room with a known occupant-id uses it as the WebXDC selfAddr '
    '(XEP-0421)',
    () {
      service.seedRoomSelfOccupantIdForTesting(roomJid, 'hth5wgnhw5wg');
      final selfAddr = service.webxdcSelfAddrForTesting(
        chatBareJid: roomJid,
        isRoom: true,
        selfBare: 'tester@example.com',
      );
      expect(selfAddr, 'hth5wgnhw5wg');
    },
  );

  test(
    'a room without a known occupant-id falls back to the 1:1 selfAddr '
    'form',
    () {
      final selfAddr = service.webxdcSelfAddrForTesting(
        chatBareJid: roomJid,
        isRoom: true,
        selfBare: 'tester@example.com',
      );
      expect(selfAddr, 'xmpp:tester@example.com');
    },
  );

  test('a 1:1 chat always uses the xmpp:<bare jid> selfAddr form', () {
    service.seedRoomSelfOccupantIdForTesting(roomJid, 'hth5wgnhw5wg');
    final selfAddr = service.webxdcSelfAddrForTesting(
      chatBareJid: roomJid,
      isRoom: false,
      selfBare: 'tester@example.com',
    );
    expect(selfAddr, 'xmpp:tester@example.com');
  });

  test(
    'the in-memory update log records every incoming update in order '
    '(for full history replay, not just the latest merged state)',
    () {
      final offer = offerStanza(
        id: 'offer-3',
        threadId: 'thread-3',
        oobUrl: 'https://upload.example/game.xdc',
      );
      service.handleRoomMessageForTesting(
        MucMessage(
          roomJid: roomJid,
          nick: 'bob',
          body: '',
          messageId: 'offer-3',
          timestamp: DateTime.utc(2026, 1, 1),
          oobUrl: 'https://upload.example/game.xdc',
          rawStanza: offer,
        ),
      );
      service.handleRoomMessageForTesting(
        MucMessage(
          roomJid: roomJid,
          nick: 'bob',
          body: '',
          messageId: 'update-3a',
          timestamp: DateTime.utc(2026, 1, 1, 0, 1),
          rawStanza: updateStanza(
            id: 'update-3a',
            threadId: 'thread-3',
            json: '{"move":1}',
          ),
        ),
      );
      service.handleRoomMessageForTesting(
        MucMessage(
          roomJid: roomJid,
          nick: 'bob',
          body: '',
          messageId: 'update-3b',
          timestamp: DateTime.utc(2026, 1, 1, 0, 2),
          rawStanza: updateStanza(
            id: 'update-3b',
            threadId: 'thread-3',
            json: '{"move":2}',
          ),
        ),
      );

      final log = service.webxdcUpdateLogForTesting('thread-3');
      expect(log, hasLength(2));
      expect(log[0]['payload'], {'move': 1});
      expect(log[1]['payload'], {'move': 2});
    },
  );

  test('an update for an unknown thread does not crash and is ignored', () {
    final update = updateStanza(
      id: 'update-2',
      threadId: 'thread-unknown',
      json: '{"foo":1}',
    );
    service.handleRoomMessageForTesting(
      MucMessage(
        roomJid: roomJid,
        nick: 'bob',
        body: '',
        messageId: 'update-2',
        timestamp: DateTime.utc(2026, 1, 1),
        rawStanza: update,
      ),
    );

    expect(service.roomMessagesFor(roomJid), isEmpty);
  });
}
