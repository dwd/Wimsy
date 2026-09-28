import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';
import 'package:wimsy/xmpp/message_intent_builder.dart';
import 'package:wimsy/xmpp/message_stanza_parser.dart';
import 'package:wimsy/xmpp/webxdc.dart';
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

// Builds a MessageIntentBuilder using the real MessageStanzaParser for the
// XEP-0491 extraction callbacks, and simple stand-in behaviour for
// everything else, so the webxdc branch of `build()` can be exercised in
// isolation like the rest of this file's direct-builder tests.
MessageIntentBuilder _webxdcTestBuilder({
  String? currentUserBareJid,
  String? activeChatBareJid,
  bool archived = false,
}) {
  const parser = MessageStanzaParser();
  return MessageIntentBuilder(
    currentUserBareJid: () => currentUserBareJid,
    activeChatBareJid: () => activeChatBareJid,
    parseJmiAction: (_) => null,
    extractReceiptsId: (_) => null,
    extractMarkerId: (_, _) => null,
    extractReactionUpdate: (_) => null,
    reactionChatTarget: (from, _) => from,
    extractOobInfoFromStanza: parser.extractOobInfo,
    extractReplyPayload: null,
    isArchivedStanza: (_) => archived,
    bareJid: (jid) => jid,
    hasReceiptRequest: (_) => false,
    hasMarkable: (_) => false,
    serializeStanza: (_) => '<message/>',
    now: DateTime.now,
    extractThread: parser.extractThread,
    extractWebxdcUpdate: parser.extractWebxdcUpdate,
    isWebxdcWidgetOffer: (stanza, oobUrl) =>
        parser.isWebxdcWidgetOffer(stanza, oobUrl: oobUrl),
  );
}

void main() {
  test('MessageIntentBuilder tolerates missing reply extractor', () {
    final builder = MessageIntentBuilder(
      currentUserBareJid: () => null,
      activeChatBareJid: () => null,
      parseJmiAction: (_) => null,
      extractReceiptsId: (_) => null,
      extractMarkerId: (_, _) => null,
      extractReactionUpdate: (_) => null,
      reactionChatTarget: (from, _) => from,
      extractOobInfoFromStanza: (_) => null,
      extractReplyPayload: null,
      isArchivedStanza: (_) => false,
      bareJid: (jid) => jid,
      hasReceiptRequest: (_) => false,
      hasMarkable: (_) => false,
      serializeStanza: (_) => '<message/>',
      now: DateTime.now,
      extractThread: (_) => null,
      extractWebxdcUpdate: (_) => null,
      isWebxdcWidgetOffer: (_, _) => false,
    );
    final stanza = _chatStanza(
      id: 'm0',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
      body: 'hello',
    );
    final intents = builder.build(stanza);
    expect(intents.length, 1);
    expect(intents.first, isA<AddMessageIntent>());
    final add = intents.first as AddMessageIntent;
    expect(add.body, 'hello');
    expect(add.replyToId, isNull);
  });

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
    expect(intent.archived, isFalse);
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

  test('buildMessageIntents includes reply payload and stripped body', () {
    final service = XmppService();
    final stanza = _chatStanza(
      id: 'm8',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
      body: '> quote\n\nnew body',
    );
    final reply = XmppElement()..name = 'reply';
    reply.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:reply:0'));
    reply.addAttribute(XmppAttribute('id', 'orig-99'));
    reply.addAttribute(XmppAttribute('to', 'alice@example.com'));
    stanza.addChild(reply);
    final fallback = XmppElement()..name = 'fallback';
    fallback.addAttribute(
      XmppAttribute('xmlns', 'urn:xmpp:feature-fallback:0'),
    );
    fallback.addAttribute(XmppAttribute('for', 'urn:xmpp:reply:0'));
    final body = XmppElement()..name = 'body';
    body.addAttribute(XmppAttribute('start', '0'));
    body.addAttribute(XmppAttribute('end', '9'));
    fallback.addChild(body);
    stanza.addChild(fallback);

    final intents = service.buildMessageIntentsForTesting(stanza);

    expect(intents.length, 1);
    final intent = intents.first as AddMessageIntent;
    expect(intent.body, 'new body');
    expect(intent.replyToId, 'orig-99');
    expect(intent.replyToJid, 'alice@example.com');
    expect(intent.replyFallback, '> quote');
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

  // ── XEP-0491: WebXDC ─────────────────────────────────────────────────────

  test(
    'build returns ApplyWebxdcUpdateIntent for the initial widget offer',
    () {
      final builder = _webxdcTestBuilder();
      final stanza = _chatStanza(
        id: 'wxm1',
        from: 'alice@example.com/phone',
        to: 'bob@example.com/desktop',
        body: 'Juliet has shared a calendar widget.',
      );
      final thread = XmppElement()..name = 'thread';
      thread.textValue = '018fe972-ea89-7f4b-90f8-729b85b7f32d';
      stanza.addChild(thread);
      final oob = XmppElement()..name = 'x';
      oob.addAttribute(XmppAttribute('xmlns', 'jabber:x:oob'));
      final url = XmppElement()..name = 'url';
      url.textValue = 'https://example.com/widgets/calendar.xdc';
      oob.addChild(url);
      stanza.addChild(oob);

      final intents = builder.build(stanza);

      expect(intents.length, 1);
      expect(intents.first, isA<ApplyWebxdcUpdateIntent>());
      final intent = intents.first as ApplyWebxdcUpdateIntent;
      expect(intent.targetBareJid, 'alice@example.com');
      expect(intent.threadId, '018fe972-ea89-7f4b-90f8-729b85b7f32d');
      expect(intent.isOffer, isTrue);
      expect(
        intent.fileTransferOobUrl,
        'https://example.com/widgets/calendar.xdc',
      );
      expect(intent.fileName, 'calendar.xdc');
      expect(intent.info, 'Juliet has shared a calendar widget.');
      expect(intent.update.document, isNull);
    },
  );

  test(
    'build returns ApplyWebxdcUpdateIntent for a follow-up state update',
    () {
      final builder = _webxdcTestBuilder();
      final stanza = _chatStanza(
        id: 'wxm2',
        from: 'alice@example.com/phone',
        to: 'bob@example.com/desktop',
      );
      final thread = XmppElement()..name = 'thread';
      thread.textValue = '018fe972-ea89-7f4b-90f8-729b85b7f32d';
      stanza.addChild(thread);
      final x = XmppElement()..name = 'x';
      x.addAttribute(XmppAttribute('xmlns', webxdcNamespace));
      final document = XmppElement()..name = 'document';
      document.textValue = 'Our Calendar';
      final summary = XmppElement()..name = 'summary';
      summary.textValue = '12 events';
      final json = XmppElement()..name = 'json';
      json.addAttribute(XmppAttribute('xmlns', webxdcJsonNamespace));
      json.textValue = '{"foo":1}';
      x.addChild(document);
      x.addChild(summary);
      x.addChild(json);
      stanza.addChild(x);

      final intents = builder.build(stanza);

      expect(intents.length, 1);
      expect(intents.first, isA<ApplyWebxdcUpdateIntent>());
      final intent = intents.first as ApplyWebxdcUpdateIntent;
      expect(intent.targetBareJid, 'alice@example.com');
      expect(intent.threadId, '018fe972-ea89-7f4b-90f8-729b85b7f32d');
      expect(intent.isOffer, isFalse);
      expect(intent.fileTransferOobUrl, isNull);
      expect(intent.fileName, isNull);
      expect(intent.info, isNull);
      expect(intent.update.document, 'Our Calendar');
      expect(intent.update.summary, '12 events');
      expect(intent.update.json, '{"foo":1}');
    },
  );

  test(
    'build returns ApplyWebxdcUpdateIntent with info for an info-only update',
    () {
      final builder = _webxdcTestBuilder();
      final stanza = _chatStanza(
        id: 'wxm3',
        from: 'alice@example.com/phone',
        to: 'bob@example.com/desktop',
        body: 'Juliet has added an event.',
      );
      final x = XmppElement()..name = 'x';
      x.addAttribute(XmppAttribute('xmlns', webxdcNamespace));
      stanza.addChild(x);

      final intents = builder.build(stanza);

      expect(intents.length, 1);
      expect(intents.first, isA<ApplyWebxdcUpdateIntent>());
      final intent = intents.first as ApplyWebxdcUpdateIntent;
      expect(intent.isOffer, isFalse);
      expect(intent.info, 'Juliet has added an event.');
      expect(intent.update.document, isNull);
      expect(intent.update.summary, isNull);
      expect(intent.update.json, isNull);
    },
  );

  test('build suppresses webxdc updates from archived stanzas', () {
    final builder = _webxdcTestBuilder(archived: true);
    final stanza = _chatStanza(
      id: 'wxm4',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
    );
    final thread = XmppElement()..name = 'thread';
    thread.textValue = '018fe972-ea89-7f4b-90f8-729b85b7f32d';
    stanza.addChild(thread);
    final x = XmppElement()..name = 'x';
    x.addAttribute(XmppAttribute('xmlns', webxdcNamespace));
    stanza.addChild(x);

    final intents = builder.build(stanza);

    expect(intents.length, 1);
    expect(intents.first, isA<UnhandledMessageIntent>());
    final intent = intents.first as UnhandledMessageIntent;
    expect(intent.reason, 'archived');
  });

  test('build suppresses webxdc updates sent by the current user', () {
    final builder = _webxdcTestBuilder(
      currentUserBareJid: 'alice@example.com',
    );
    final stanza = _chatStanza(
      id: 'wxm5',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
    );
    final thread = XmppElement()..name = 'thread';
    thread.textValue = '018fe972-ea89-7f4b-90f8-729b85b7f32d';
    stanza.addChild(thread);
    final x = XmppElement()..name = 'x';
    x.addAttribute(XmppAttribute('xmlns', webxdcNamespace));
    stanza.addChild(x);

    final intents = builder.build(stanza);

    expect(intents.length, 1);
    expect(intents.first, isA<UnhandledMessageIntent>());
    final intent = intents.first as UnhandledMessageIntent;
    expect(intent.reason, 'self-message');
  });
}
