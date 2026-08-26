import 'package:test/test.dart';
import 'package:xmpp_stone/src/chat/Chat.dart';
import 'package:xmpp_stone/src/chat/Message.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('bodyless direct MUC invitation is renderable chat content', () {
    final stanza = MessageStanza('invite-1', MessageStanzaType.CHAT);
    final invite = XmppElement()..name = 'x';
    invite.addAttribute(XmppAttribute('xmlns', 'jabber:x:conference'));
    invite.addAttribute(XmppAttribute('jid', 'room@example.com'));
    stanza.addChild(invite);
    final message = Message(
      stanza,
      Jid.fromFullJid('romeo@example.com'),
      Jid.fromFullJid('juliet@example.com'),
      null,
      DateTime.utc(2026),
      type: MessageStanzaType.CHAT,
    );

    expect(isRenderableChatMessage(message), isTrue);
  });

  test('bodyless ordinary chat message remains non-renderable', () {
    final stanza = MessageStanza('empty-1', MessageStanzaType.CHAT);
    final message = Message(
      stanza,
      Jid.fromFullJid('romeo@example.com'),
      Jid.fromFullJid('juliet@example.com'),
      null,
      DateTime.utc(2026),
      type: MessageStanzaType.CHAT,
    );

    expect(isRenderableChatMessage(message), isFalse);
  });
}
