import 'package:test/test.dart';
import 'package:xmpp_stone/src/chat/Message.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/stanzas/MessageStanza.dart';

void main() {
  group('Message parsing', () {
    test('Archived MAM result captures ids and delay', () {
      final stanza = MessageStanza('root', MessageStanzaType.CHAT);
      final result = XmppElement()
        ..name = 'result'
        ..addAttribute(XmppAttribute('id', 'mam-123'))
        ..addAttribute(XmppAttribute('queryId', 'query-1'));
      final forwarded = XmppElement()..name = 'forwarded';
      forwarded.addChild(_delay('2024-01-02T03:04:05Z'));
      forwarded.addChild(_forwardedMessage(
        from: 'juliet@example.com',
        to: 'romeo@example.com',
        messageId: 'msg-42',
        stanzaId: 'stanza-7',
        body: 'Wherefore art thou?',
      ));
      result.addChild(forwarded);
      stanza.addChild(result);

      final message = Message.fromStanza(stanza);

      expect(message.isForwarded, isTrue);
      expect(message.isDelayed, isTrue);
      expect(message.mamResultId, 'mam-123');
      expect(message.queryId, 'query-1');
      expect(message.messageId, 'msg-42');
      expect(message.stanzaId, 'stanza-7');
      expect(message.from?.userAtDomain, 'juliet@example.com');
      expect(message.to?.userAtDomain, 'romeo@example.com');
      expect(message.text, 'Wherefore art thou?');
      expect(message.time, DateTime.parse('2024-01-02T03:04:05Z'));
      expect(message.source, 'mam');
      // The inner message stanza (not the <result>/<forwarded> wrapper)
      // must be what gets persisted/displayed as rawXml.
      final innerXml = message.innerMessageStanza.buildXmlString();
      expect(innerXml, isNot(contains('<result')));
      expect(innerXml, isNot(contains('<forwarded')));
      expect(innerXml, contains('Wherefore art thou?'));
    });

    test('Carbon forwarded message parses metadata', () {
      final stanza = MessageStanza('root', MessageStanzaType.CHAT);
      final sent = XmppElement()..name = 'sent';
      final forwarded = XmppElement()..name = 'forwarded';
      forwarded.addChild(_delay('2024-05-06T07:08:09Z'));
      forwarded.addChild(_forwardedMessage(
        from: 'romeo@example.com',
        to: 'juliet@example.com',
        messageId: 'msg-99',
        stanzaId: 'stanza-99',
        body: 'O Romeo, Romeo!',
        type: 'chat',
      ));
      sent.addChild(forwarded);
      stanza.addChild(sent);

      final message = Message.fromStanza(stanza);

      expect(message.isForwarded, isTrue);
      expect(message.isDelayed, isTrue);
      expect(message.messageId, 'msg-99');
      expect(message.from?.userAtDomain, 'romeo@example.com');
      expect(message.to?.userAtDomain, 'juliet@example.com');
      expect(message.text, 'O Romeo, Romeo!');
      expect(message.time, DateTime.parse('2024-05-06T07:08:09Z'));
      // Carbons mirror a live send/receive on another resource - they are
      // not an archived MAM result, so the source stays 'live'.
      expect(message.source, 'live');
      final innerXml = message.innerMessageStanza.buildXmlString();
      expect(innerXml, isNot(contains('<sent')));
      expect(innerXml, isNot(contains('<forwarded')));
    });

    test('Regular message parsing keeps body and jid', () {
      final stanza = MessageStanza('root', MessageStanzaType.CHAT)
        ..body = 'Ping';
      stanza.fromJid = Jid.fromFullJid('mercutio@example.com');
      stanza.toJid = Jid.fromFullJid('romeo@example.com');

      final message = Message.fromStanza(stanza);

      expect(message.text, 'Ping');
      expect(message.from?.userAtDomain, 'mercutio@example.com');
      expect(message.to?.userAtDomain, 'romeo@example.com');
      expect(message.source, 'live');
      expect(message.innerMessageStanza, same(stanza));
    });
  });
}

XmppElement _forwardedMessage({
  required String from,
  required String to,
  required String messageId,
  required String stanzaId,
  required String body,
  String? type,
}) {
  final message = XmppElement()
    ..name = 'message'
    ..addAttribute(XmppAttribute('from', from))
    ..addAttribute(XmppAttribute('to', to))
    ..addAttribute(XmppAttribute('id', messageId));
  if (type != null) {
    message.addAttribute(XmppAttribute('type', type));
  }
  message.addChild(XmppElement()
    ..name = 'body'
    ..textValue = body);
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
