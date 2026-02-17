import 'package:test/test.dart';
import 'package:xmpp_stone/src/muc/MucManager.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/stanzas/MessageStanza.dart';

void main() {
  group('MUC parsing', () {
    test('Parses MAM groupchat message with forwarded stanza-id', () {
      final stanza = _mamGroupchatStanza(
        roomJid: 'room@example.com',
        nick: 'tester',
        body: 'hello',
        mamId: 'mam-7',
        stanzaId: 'stanza-9',
        stamp: '2024-08-09T10:11:12Z',
      );

      final parsed = parseMucGroupMessage(stanza);

      expect(parsed, isNotNull);
      expect(parsed!.message, isNotNull);
      expect(parsed.subject, isNull);
      expect(parsed.message!.roomJid, 'room@example.com');
      expect(parsed.message!.nick, 'tester');
      expect(parsed.message!.body, 'hello');
      expect(parsed.message!.mamResultId, 'mam-7');
      expect(parsed.message!.stanzaId, 'stanza-9');
      expect(parsed.message!.timestamp, DateTime.parse('2024-08-09T10:11:12Z'));
    });

    test('Subject-only message returns subject update', () {
      final stanza = MessageStanza('root', MessageStanzaType.GROUPCHAT);
      final result = XmppElement()..name = 'result';
      final forwarded = XmppElement()..name = 'forwarded';
      forwarded.addChild(_forwardedMessage(
        from: 'room@example.com/mod',
        body: '',
        stanzaId: 'stanza-1',
        subject: 'New topic',
      ));
      result.addChild(forwarded);
      stanza.addChild(result);

      final parsed = parseMucGroupMessage(stanza);

      expect(parsed, isNotNull);
      expect(parsed!.subject, isNotNull);
      expect(parsed.message, isNull);
      expect(parsed.subject!.roomJid, 'room@example.com');
      expect(parsed.subject!.subject, 'New topic');
    });

    test('Direct history stanza uses stanza-id for de-dupe', () {
      final stanza = MessageStanza('root', MessageStanzaType.GROUPCHAT);
      stanza.fromJid = Jid.fromFullJid('room@example.com/alice');
      stanza.body = 'history';
      stanza.addChild(XmppElement()
        ..name = 'stanza-id'
        ..addAttribute(XmppAttribute('id', 'stanza-55')));

      final parsed = parseMucGroupMessage(stanza);

      expect(parsed, isNotNull);
      expect(parsed!.message, isNotNull);
      expect(parsed.message!.stanzaId, 'stanza-55');
    });
  });
}

MessageStanza _mamGroupchatStanza({
  required String roomJid,
  required String nick,
  required String body,
  required String mamId,
  required String stanzaId,
  required String stamp,
}) {
  final stanza = MessageStanza('root', MessageStanzaType.GROUPCHAT);
  final result = XmppElement()
    ..name = 'result'
    ..addAttribute(XmppAttribute('id', mamId));
  final forwarded = XmppElement()..name = 'forwarded';
  forwarded.addChild(_delay(stamp));
  forwarded.addChild(_forwardedMessage(
    from: '$roomJid/$nick',
    body: body,
    stanzaId: stanzaId,
  ));
  result.addChild(forwarded);
  stanza.addChild(result);
  return stanza;
}

XmppElement _forwardedMessage({
  required String from,
  required String body,
  required String stanzaId,
  String? subject,
}) {
  final message = XmppElement()
    ..name = 'message'
    ..addAttribute(XmppAttribute('from', from));
  message.addChild(XmppElement()
    ..name = 'body'
    ..textValue = body);
  if (subject != null) {
    message.addChild(XmppElement()
      ..name = 'subject'
      ..textValue = subject);
  }
  message.addChild(XmppElement()
    ..name = 'stanza-id'
    ..addAttribute(XmppAttribute('id', stanzaId)));
  return message;
}

XmppElement _delay(String stamp) {
  return XmppElement()
    ..name = 'delay'
    ..addAttribute(XmppAttribute('stamp', stamp));
}
