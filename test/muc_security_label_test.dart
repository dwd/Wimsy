import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/room_entry.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

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

  // Builds the raw <message type="groupchat"/> stanza a room sends when a
  // XEP-0258 security label is attached, mirroring what a real server
  // (observed in wimsy.log) produces: a <securitylabel/> envelope carrying
  // both the server-rendered <displaymarking/> and the primary <label/>.
  MessageStanza securityLabelledGroupStanza({required String body}) {
    final stanza = MessageStanza('room-1', MessageStanzaType.GROUPCHAT);
    stanza.fromJid = Jid.fromFullJid('$roomJid/bob');
    stanza.body = body;
    final securityLabel = XmppElement()..name = 'securitylabel';
    securityLabel.addAttribute(
      XmppAttribute('xmlns', 'urn:xmpp:sec-label:0'),
    );
    final displayMarking = XmppElement()..name = 'displaymarking';
    displayMarking.textValue = 'DEMO-UK OFFICIAL';
    securityLabel.addChild(displayMarking);
    final label = XmppElement()..name = 'label';
    final ess = XmppElement()..name = 'esssecuritylabel';
    ess.addAttribute(
      XmppAttribute('xmlns', 'urn:xmpp:sec-label:ess:0'),
    );
    // No security policy is registered in this test, so this undecodable
    // (for our purposes) payload must simply be ignored, causing a fall
    // back to the server-supplied displaymarking below.
    ess.textValue = 'MRACAQoGCyqGOgABg5rFEQAE';
    label.addChild(ess);
    securityLabel.addChild(label);
    stanza.addChild(securityLabel);
    return stanza;
  }

  test(
    'a groupchat message carrying a securitylabel renders the fallback '
    'display marking',
    () {
      final stanza = securityLabelledGroupStanza(body: 'hello');
      service.handleRoomMessageForTesting(
        MucMessage(
          roomJid: roomJid,
          nick: 'bob',
          body: 'hello',
          messageId: 'msg-1',
          timestamp: DateTime.utc(2026, 1, 1),
          rawStanza: stanza,
        ),
      );

      final message = service.roomMessagesFor(roomJid).single;
      expect(message.securityLabelText, 'DEMO-UK OFFICIAL');
      // No policy is known to this session, so the marking must be flagged
      // as an unverified fallback rather than a policy-parsed one.
      expect(message.securityLabelIsFallback, isTrue);
    },
  );

  test('a groupchat message without a securitylabel has no label', () {
    final stanza = MessageStanza('room-2', MessageStanzaType.GROUPCHAT);
    stanza.fromJid = Jid.fromFullJid('$roomJid/bob');
    stanza.body = 'plain message';
    service.handleRoomMessageForTesting(
      MucMessage(
        roomJid: roomJid,
        nick: 'bob',
        body: 'plain message',
        messageId: 'msg-2',
        timestamp: DateTime.utc(2026, 1, 1),
        rawStanza: stanza,
      ),
    );

    final message = service.roomMessagesFor(roomJid).single;
    expect(message.securityLabelText, isNull);
  });
}
