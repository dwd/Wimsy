import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/message_stanza_parser.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

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

XmppElement _forwardedMessageContainer(String name, XmppElement messageChild) {
  final container = XmppElement()..name = name;
  final forwarded = XmppElement()..name = 'forwarded';
  final message = XmppElement()..name = 'message';
  message.addChild(messageChild);
  forwarded.addChild(message);
  container.addChild(forwarded);
  return container;
}

void main() {
  final parser = MessageStanzaParser();

  test('extractReceiptsId and marker helpers parse top-level markers', () {
    final stanza = _chatStanza(
      id: 'm1',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
    );

    final request = XmppElement()..name = 'request';
    request.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:receipts'));
    stanza.addChild(request);

    final received = XmppElement()..name = 'received';
    received.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:receipts'));
    received.addAttribute(XmppAttribute('id', 'r-1'));
    stanza.addChild(received);

    final displayed = XmppElement()..name = 'displayed';
    displayed.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:chat-markers:0'));
    displayed.addAttribute(XmppAttribute('id', 'd-1'));
    stanza.addChild(displayed);

    expect(parser.hasReceiptRequest(stanza), isTrue);
    expect(parser.extractReceiptsId(stanza), 'r-1');
    expect(parser.extractMarkerId(stanza, 'displayed'), 'd-1');
  });

  test('extractReactionUpdate reads reactions from forwarded message', () {
    final stanza = _chatStanza(
      id: 'm2',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
    );

    final reactions = XmppElement()..name = 'reactions';
    reactions.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:reactions:0'));
    reactions.addAttribute(XmppAttribute('id', 'target-1'));
    final first = XmppElement()..name = 'reaction';
    first.textValue = '👍';
    final second = XmppElement()..name = 'reaction';
    second.textValue = '🔥';
    reactions.addChild(first);
    reactions.addChild(second);

    stanza.addChild(_forwardedMessageContainer('result', reactions));

    final update = parser.extractReactionUpdate(stanza);
    expect(update, isNotNull);
    expect(update!.targetId, 'target-1');
    expect(update.reactions, ['👍', '🔥']);
  });

  test('extractOobInfo reads OOB payload from carbons forwarded message', () {
    final stanza = _chatStanza(
      id: 'm3',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
    );

    final oob = XmppElement()..name = 'x';
    oob.addAttribute(XmppAttribute('xmlns', 'jabber:x:oob'));
    final url = XmppElement()..name = 'url';
    url.textValue = 'https://example.com/file.png';
    final desc = XmppElement()..name = 'desc';
    desc.textValue = 'Preview';
    oob.addChild(url);
    oob.addChild(desc);

    stanza.addChild(_forwardedMessageContainer('received', oob));

    final info = parser.extractOobInfo(stanza);
    expect(info, isNotNull);
    expect(info!.url, 'https://example.com/file.png');
    expect(info.description, 'Preview');
  });

  test('extractSecurityLabel reads displaymarking text and colours', () {
    final stanza = _chatStanza(
      id: 'm-sl1',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
      body: 'Classified content',
    );

    final label = XmppElement()..name = 'securitylabel';
    label.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sec-label:0'));
    final displayMarking = XmppElement()..name = 'displaymarking';
    displayMarking.addAttribute(XmppAttribute('fgcolor', 'black'));
    displayMarking.addAttribute(XmppAttribute('bgcolor', 'red'));
    displayMarking.textValue = 'SECRET';
    label.addChild(displayMarking);
    stanza.addChild(label);

    final info = parser.extractSecurityLabel(stanza);
    expect(info, isNotNull);
    expect(info!.text, 'SECRET');
    expect(info.fgColor, 'black');
    expect(info.bgColor, 'red');
  });

  test('extractSecurityLabel reads displaymarking from forwarded message', () {
    final stanza = _chatStanza(
      id: 'm-sl2',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
    );

    final label = XmppElement()..name = 'securitylabel';
    label.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sec-label:0'));
    final displayMarking = XmppElement()..name = 'displaymarking';
    displayMarking.textValue = 'UNCLASSIFIED';
    label.addChild(displayMarking);

    stanza.addChild(_forwardedMessageContainer('received', label));

    final info = parser.extractSecurityLabel(stanza);
    expect(info, isNotNull);
    expect(info!.text, 'UNCLASSIFIED');
    expect(info.fgColor, isNull);
    expect(info.bgColor, isNull);
  });

  test(
    'extractSecurityLabel returns null when no securitylabel element present',
    () {
      final stanza = _chatStanza(
        id: 'm-sl3',
        from: 'alice@example.com/phone',
        to: 'bob@example.com/desktop',
        body: 'Just a normal message',
      );

      expect(parser.extractSecurityLabel(stanza), isNull);
    },
  );

  test(
    'extractSecurityLabel returns null when displaymarking has no text',
    () {
      final stanza = _chatStanza(
        id: 'm-sl4',
        from: 'alice@example.com/phone',
        to: 'bob@example.com/desktop',
      );

      final label = XmppElement()..name = 'securitylabel';
      label.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sec-label:0'));
      final displayMarking = XmppElement()..name = 'displaymarking';
      label.addChild(displayMarking);
      stanza.addChild(label);

      expect(parser.extractSecurityLabel(stanza), isNull);
    },
  );

  test(
    'extractReplaceId reads message correction from direct forwarded stanza',
    () {
      final stanza = _chatStanza(
        id: 'm4',
        from: 'alice@example.com/phone',
        to: 'bob@example.com/desktop',
      );

      final replace = XmppElement()..name = 'replace';
      replace.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:message-correct:0'),
      );
      replace.addAttribute(XmppAttribute('id', 'orig-123'));

      final forwarded = XmppElement()..name = 'forwarded';
      final message = XmppElement()..name = 'message';
      message.addChild(replace);
      forwarded.addChild(message);
      stanza.addChild(forwarded);

      expect(parser.extractReplaceId(stanza), 'orig-123');
    },
  );

  test('extractReplyPayload strips feature-fallback body range', () {
    final stanza = _chatStanza(
      id: 'm5',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
      body: '> quoted line\n\nhello',
    );
    final reply = XmppElement()..name = 'reply';
    reply.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:reply:0'));
    reply.addAttribute(XmppAttribute('id', 'orig-1'));
    reply.addAttribute(XmppAttribute('to', 'alice@example.com'));
    stanza.addChild(reply);
    final fallback = XmppElement()..name = 'fallback';
    fallback.addAttribute(
      XmppAttribute('xmlns', 'urn:xmpp:feature-fallback:0'),
    );
    fallback.addAttribute(XmppAttribute('for', 'urn:xmpp:reply:0'));
    final body = XmppElement()..name = 'body';
    body.addAttribute(XmppAttribute('start', '0'));
    body.addAttribute(XmppAttribute('end', '15'));
    fallback.addChild(body);
    stanza.addChild(fallback);

    final payload = parser.extractReplyPayload(stanza, body: stanza.body);
    expect(payload, isNotNull);
    expect(payload!.replyToId, 'orig-1');
    expect(payload.replyToJid, 'alice@example.com');
    expect(payload.fallbackBody, '> quoted line');
    expect(payload.cleanedBody, 'hello');
  });

  test('extractReplyPayload strips the current urn:xmpp:fallback:0 range', () {
    // XEP-0428 renamed the namespace; both spellings must be understood.
    final stanza = _chatStanza(
      id: 'm6',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
      body: '> quoted line\n\nhello',
    );
    final reply = XmppElement()..name = 'reply';
    reply.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:reply:0'));
    reply.addAttribute(XmppAttribute('id', 'orig-2'));
    stanza.addChild(reply);
    final fallback = XmppElement()..name = 'fallback';
    fallback.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:fallback:0'));
    fallback.addAttribute(XmppAttribute('for', 'urn:xmpp:reply:0'));
    final body = XmppElement()..name = 'body';
    body.addAttribute(XmppAttribute('start', '0'));
    body.addAttribute(XmppAttribute('end', '15'));
    fallback.addChild(body);
    stanza.addChild(fallback);

    final payload = parser.extractReplyPayload(stanza, body: stanza.body);
    expect(payload, isNotNull);
    expect(payload!.fallbackBody, '> quoted line');
    expect(payload.cleanedBody, 'hello');
  });

  test('extractReplyPayload ignores a fallback for another feature', () {
    final stanza = _chatStanza(
      id: 'm7',
      from: 'alice@example.com/phone',
      to: 'bob@example.com/desktop',
      body: 'unrelated fallback text',
    );
    final reply = XmppElement()..name = 'reply';
    reply.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:reply:0'));
    reply.addAttribute(XmppAttribute('id', 'orig-3'));
    stanza.addChild(reply);
    final fallback = XmppElement()..name = 'fallback';
    fallback.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:fallback:0'));
    fallback.addAttribute(XmppAttribute('for', 'urn:xmpp:sce:0'));
    final body = XmppElement()..name = 'body';
    body.addAttribute(XmppAttribute('start', '0'));
    body.addAttribute(XmppAttribute('end', '9'));
    fallback.addChild(body);
    stanza.addChild(fallback);

    final payload = parser.extractReplyPayload(stanza, body: stanza.body);
    expect(payload, isNotNull);
    expect(payload!.fallbackBody, isNull);
    expect(payload.cleanedBody, 'unrelated fallback text');
  });
}
