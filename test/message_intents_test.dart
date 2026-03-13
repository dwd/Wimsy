import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';
import 'package:wimsy/xmpp/message_intent_builder.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';
import 'package:wimsy/xmpp/jmi.dart';

MessageStanza _chatStanza({
  required String id,
  required String from,
  required String to,
  String? body,
}) {
  final stanza = MessageStanza(id, MessageStanzaType.CHAT);
  stanza.fromJid = Jid.fromFullJid(from);
  stanza.toJid = Jid.fromFullJid(to);
  if (body != null) {
    stanza.body = body;
  }
  return stanza;
}

void main() {
  test('buildMessageIntents applies receipt with scoped id', () {
    final service = XmppService();
    final stanza = _chatStanza(
      id: 'm1',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
    );
    final received = XmppElement()..name = 'received';
    received.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:receipts'));
    received.addAttribute(XmppAttribute('id', 'r1'));
    stanza.addChild(received);

    final intents = service.buildMessageIntentsForTesting(stanza);

    expect(intents.length, 1);
    expect(intents.first, isA<ApplyReceiptIntent>());
    final intent = intents.first as ApplyReceiptIntent;
    expect(intent.scopedId.scopeJid, 'alice@example.com');
    expect(intent.scopedId.id, 'r1');
  });

  test('buildMessageIntents emits receipt and marker intents', () {
    final service = XmppService();
    final stanza = _chatStanza(
      id: 'm2',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
      body: 'hi',
    );
    final request = XmppElement()..name = 'request';
    request.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:receipts'));
    stanza.addChild(request);
    final markable = XmppElement()..name = 'markable';
    markable.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:chat-markers:0'));
    stanza.addChild(markable);

    final intents = service.buildMessageIntentsForTesting(stanza);

    expect(intents.length, 3);
    expect(intents[0], isA<SendReceiptIntent>());
    expect(intents[1], isA<SendMarkerIntent>());
    expect(intents[2], isA<AddMessageIntent>());
    final receipt = intents[0] as SendReceiptIntent;
    final marker = intents[1] as SendMarkerIntent;
    final add = intents[2] as AddMessageIntent;
    expect(receipt.scopedId.scopeJid, 'alice@example.com');
    expect(receipt.scopedId.id, 'm2');
    expect(marker.name, 'received');
    expect(marker.scopedId.id, 'm2');
    expect(add.body, 'hi');
  });

  test('buildMessageIntents returns JMI handle intent', () {
    final service = XmppService();
    final stanza = _chatStanza(
      id: 'm3',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
    );
    stanza.addChild(buildJmiProceedElement(sid: 'sid1'));

    final intents = service.buildMessageIntentsForTesting(stanza);

    expect(intents.length, 1);
    expect(intents.first, isA<HandleJmiIntent>());
    final intent = intents.first as HandleJmiIntent;
    expect(intent.action, JmiAction.proceed);
  });

  test('buildMessageIntents applies displayed marker intent', () {
    final service = XmppService();
    final stanza = _chatStanza(
      id: 'm4',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
    );
    final displayed = XmppElement()..name = 'displayed';
    displayed.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:chat-markers:0'));
    displayed.addAttribute(XmppAttribute('id', 'd1'));
    stanza.addChild(displayed);

    final intents = service.buildMessageIntentsForTesting(stanza);

    expect(intents.length, 1);
    expect(intents.first, isA<ApplyDisplayedIntent>());
    final intent = intents.first as ApplyDisplayedIntent;
    expect(intent.scopedId.scopeJid, 'alice@example.com');
    expect(intent.scopedId.id, 'd1');
  });

  test('buildMessageIntents applies reaction intent', () {
    final service = XmppService();
    final stanza = _chatStanza(
      id: 'm5',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
    );
    final reactions = XmppElement()..name = 'reactions';
    reactions.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:reactions:0'));
    reactions.addAttribute(XmppAttribute('id', 'target1'));
    final reaction = XmppElement()..name = 'reaction';
    reaction.textValue = '👍';
    reactions.addChild(reaction);
    stanza.addChild(reactions);

    final intents = service.buildMessageIntentsForTesting(stanza);

    expect(intents.length, 1);
    expect(intents.first, isA<ApplyReactionIntent>());
    final intent = intents.first as ApplyReactionIntent;
    expect(intent.targetBareJid, 'alice@example.com');
    expect(intent.senderBareJid, 'alice@example.com');
    expect(intent.update.targetId, 'target1');
    expect(intent.update.reactions, ['👍']);
  });

  test('buildMessageIntents returns add message intent for body', () {
    final service = XmppService();
    final stanza = _chatStanza(
      id: 'm6',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
      body: 'hello',
    );

    final intents = service.buildMessageIntentsForTesting(stanza);

    expect(intents.length, 1);
    expect(intents.first, isA<AddMessageIntent>());
    final intent = intents.first as AddMessageIntent;
    expect(intent.bareJid, 'alice@example.com');
    expect(intent.from, 'alice@example.com');
    expect(intent.to, 'bob@example.com');
    expect(intent.body, 'hello');
    expect(intent.messageId, 'm6');
  });

  test('buildMessageIntents returns no-action intent for no body', () {
    final service = XmppService();
    final stanza = _chatStanza(
      id: 'm7',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
    );

    final intents = service.buildMessageIntentsForTesting(stanza);

    expect(intents.length, 1);
    expect(intents.first, isA<UnhandledMessageIntent>());
    final intent = intents.first as UnhandledMessageIntent;
    expect(intent.reason, 'empty-body');
  });
}
