import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spiffing/spiffing.dart' as spiffing;
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
    expect(info.isFallback, isTrue);
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
    expect(info.isFallback, isTrue);
  });

  test(
    'extractSecurityLabel parses the primary label against a known policy',
    () {
      // Register a minimal SPIF so the primary <label/> (ESS/BER-encoded)
      // can actually be decoded and rendered, rather than falling back to
      // the server-supplied <displaymarking/>.
      final site = spiffing.Site();
      final policy = site.load('''
<SPIF>
  <securityPolicyId name="TestPolicy" id="1.2.3.4.5"/>
  <securityClassifications>
    <securityClassification lacv="10" name="SECRET" hierarchy="10" color="red"/>
  </securityClassifications>
</SPIF>
''');
      final label = spiffing.Label.forClassification(policy, 10);
      final berBytes = label.write(spiffing.Format.ber);
      final base64Data = base64.encode(latin1.encode(berBytes));

      final stanza = _chatStanza(
        id: 'm-sl5',
        from: 'alice@example.com/phone',
        to: 'bob@example.com/desktop',
      );

      final securityLabel = XmppElement()..name = 'securitylabel';
      securityLabel.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:sec-label:0'),
      );
      final displayMarking = XmppElement()..name = 'displaymarking';
      // A wrong/irrelevant server-supplied marking, to prove the parsed
      // label — not this fallback — is what gets used.
      displayMarking.textValue = 'SHOULD NOT BE USED';
      securityLabel.addChild(displayMarking);
      final labelElement = XmppElement()..name = 'label';
      final essLabel = XmppElement()..name = 'esssecuritylabel';
      essLabel.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:sec-label:ess:0'),
      );
      essLabel.textValue = base64Data;
      labelElement.addChild(essLabel);
      securityLabel.addChild(labelElement);
      stanza.addChild(securityLabel);

      final info = parser.extractSecurityLabel(stanza);
      expect(info, isNotNull);
      expect(info!.isFallback, isFalse);
      expect(info.text, contains('SECRET'));
      expect(info.fgColor, 'red');
    },
  );

  test(
    'extractSecurityLabel falls back to displaymarking when no policy is known',
    () {
      // A fresh policy id that has never been registered with any Site.
      final stanza = _chatStanza(
        id: 'm-sl6',
        from: 'alice@example.com/phone',
        to: 'bob@example.com/desktop',
      );

      final securityLabel = XmppElement()..name = 'securitylabel';
      securityLabel.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:sec-label:0'),
      );
      final displayMarking = XmppElement()..name = 'displaymarking';
      displayMarking.addAttribute(XmppAttribute('fgcolor', 'black'));
      displayMarking.addAttribute(XmppAttribute('bgcolor', 'red'));
      displayMarking.textValue = 'SECRET';
      securityLabel.addChild(displayMarking);
      final labelElement = XmppElement()..name = 'label';
      final essLabel = XmppElement()..name = 'esssecuritylabel';
      essLabel.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:sec-label:ess:0'),
      );
      // Not valid BER for any known policy - decoding must fail cleanly.
      essLabel.textValue = base64.encode(latin1.encode('not a real label'));
      labelElement.addChild(essLabel);
      securityLabel.addChild(labelElement);
      stanza.addChild(securityLabel);

      final info = parser.extractSecurityLabel(stanza);
      expect(info, isNotNull);
      expect(info!.isFallback, isTrue);
      expect(info.text, 'SECRET');
      expect(info.fgColor, 'black');
      expect(info.bgColor, 'red');
    },
  );

  test(
    'extractSecurityLabel falls back to displaymarking for an empty <label/>',
    () {
      final stanza = _chatStanza(
        id: 'm-sl7',
        from: 'alice@example.com/phone',
        to: 'bob@example.com/desktop',
      );

      final securityLabel = XmppElement()..name = 'securitylabel';
      securityLabel.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:sec-label:0'),
      );
      final displayMarking = XmppElement()..name = 'displaymarking';
      displayMarking.textValue = 'DEFAULT';
      securityLabel.addChild(displayMarking);
      securityLabel.addChild(XmppElement()..name = 'label');
      stanza.addChild(securityLabel);

      final info = parser.extractSecurityLabel(stanza);
      expect(info, isNotNull);
      expect(info!.isFallback, isTrue);
      expect(info.text, 'DEFAULT');
    },
  );

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
