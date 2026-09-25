import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/room_entry.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

XmppElement _securityLabelElement({
  required String displayMarkingText,
  String? fgColor,
}) {
  final securityLabel = XmppElement()..name = 'securitylabel';
  securityLabel.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sec-label:0'));
  final displayMarking = XmppElement()..name = 'displaymarking';
  if (fgColor != null) {
    displayMarking.addAttribute(XmppAttribute('fgcolor', fgColor));
  }
  displayMarking.textValue = displayMarkingText;
  securityLabel.addChild(displayMarking);
  return securityLabel;
}

void main() {
  group('1:1 chats', () {
    const toBareJid = 'bob@example.com';
    late XmppService service;

    setUp(() {
      service = XmppService();
      service.seedConnectedChatForTesting(toBareJid);
      addTearDown(service.dispose);
    });

    test(
      'pendingSecurityLabelFor previews a staged label before sending',
      () {
        expect(service.pendingSecurityLabelFor(toBareJid), isNull);

        final element = _securityLabelElement(
          displayMarkingText: 'SECRET',
          fgColor: 'red',
        );
        service.setPendingSecurityLabel(toBareJid, element);

        final info = service.pendingSecurityLabelFor(toBareJid);
        expect(info, isNotNull);
        expect(info!.text, 'SECRET');
        expect(info.fgColor, 'red');
      },
    );

    test('setPendingSecurityLabel(null) clears a staged label', () {
      final element = _securityLabelElement(displayMarkingText: 'SECRET');
      service.setPendingSecurityLabel(toBareJid, element);
      expect(service.pendingSecurityLabelFor(toBareJid), isNotNull);

      service.setPendingSecurityLabel(toBareJid, null);
      expect(service.pendingSecurityLabelFor(toBareJid), isNull);
    });

    test(
      'sending a message attaches the staged label and clears the pending '
      'state, and the sender sees their own label chip',
      () {
        final element = _securityLabelElement(
          displayMarkingText: 'SECRET',
          fgColor: 'red',
        );
        service.setPendingSecurityLabel(toBareJid, element);

        service.sendMessage(toBareJid: toBareJid, text: 'hello');

        // Pending state is per-outgoing-message, not sticky.
        expect(service.pendingSecurityLabelFor(toBareJid), isNull);

        final message = service.messagesFor(toBareJid).single;
        expect(message.securityLabelText, 'SECRET');
        expect(message.securityLabelFgColor, 'red');
        expect(message.securityLabelIsFallback, isFalse);
      },
    );

    test('sending a message without a staged label attaches none', () {
      service.sendMessage(toBareJid: toBareJid, text: 'hello');

      final message = service.messagesFor(toBareJid).single;
      expect(message.securityLabelText, isNull);
    });

    test('a second message needs its own re-picked label', () {
      final element = _securityLabelElement(displayMarkingText: 'SECRET');
      service.setPendingSecurityLabel(toBareJid, element);
      service.sendMessage(toBareJid: toBareJid, text: 'first');

      service.sendMessage(toBareJid: toBareJid, text: 'second');

      final messages = service.messagesFor(toBareJid);
      expect(messages, hasLength(2));
      expect(messages[0].securityLabelText, 'SECRET');
      expect(messages[1].securityLabelText, isNull);
    });
  });

  group('MUC rooms', () {
    const roomJid = 'room@conference.example';
    late XmppService service;

    setUp(() {
      service = XmppService();
      service.seedConnectedRoomForTesting(
        RoomEntry(roomJid: roomJid, nick: 'alice', joined: true),
      );
      addTearDown(service.dispose);
    });

    test(
      'sending a room message attaches the staged label and clears the '
      'pending state, and the sender sees their own label chip',
      () {
        final element = _securityLabelElement(
          displayMarkingText: 'DEMO-UK OFFICIAL',
          fgColor: 'blue',
        );
        service.setPendingSecurityLabel(roomJid, element);

        service.sendRoomMessage(roomJid, 'hello room');

        expect(service.pendingSecurityLabelFor(roomJid), isNull);

        final message = service.roomMessagesFor(roomJid).single;
        expect(message.securityLabelText, 'DEMO-UK OFFICIAL');
        expect(message.securityLabelFgColor, 'blue');
        expect(message.securityLabelIsFallback, isFalse);
      },
    );

    test('sending a room message without a staged label attaches none', () {
      service.sendRoomMessage(roomJid, 'hello room');

      final message = service.roomMessagesFor(roomJid).single;
      expect(message.securityLabelText, isNull);
    });
  });
}
