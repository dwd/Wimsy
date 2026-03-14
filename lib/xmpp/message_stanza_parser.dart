import 'package:xmpp_stone/xmpp_stone.dart';

import 'message_intent_builder.dart';

class MessageStanzaParser {
  const MessageStanzaParser();

  bool hasReceiptRequest(MessageStanza stanza) {
    return _hasChildWithXmlns(stanza, 'request', 'urn:xmpp:receipts');
  }

  bool hasMarkable(MessageStanza stanza) {
    return _hasChildWithXmlns(stanza, 'markable', 'urn:xmpp:chat-markers:0');
  }

  String? extractReceiptsId(MessageStanza stanza) {
    final element = _findChildWithXmlns(
      stanza,
      'received',
      'urn:xmpp:receipts',
    );
    return element?.getAttribute('id')?.value;
  }

  String? extractMarkerId(MessageStanza stanza, String name) {
    final element = _findChildWithXmlns(
      stanza,
      name,
      'urn:xmpp:chat-markers:0',
    );
    return element?.getAttribute('id')?.value;
  }

  OobInfo? extractOobInfo(XmppElement stanza) {
    for (final candidate in _candidateMessages(stanza)) {
      for (final child in candidate.children) {
        if (child.name != 'x') {
          continue;
        }
        if (child.getAttribute('xmlns')?.value != 'jabber:x:oob') {
          continue;
        }
        final url = child.getChild('url')?.textValue?.trim();
        if (url == null || url.isEmpty) {
          continue;
        }
        final description = child.getChild('desc')?.textValue?.trim();
        return OobInfo(url: url, description: description);
      }
    }
    return null;
  }

  ReactionUpdate? extractReactionUpdate(XmppElement stanza) {
    for (final candidate in _candidateMessages(stanza)) {
      for (final child in candidate.children) {
        if (child.name != 'reactions' ||
            child.getAttribute('xmlns')?.value != 'urn:xmpp:reactions:0') {
          continue;
        }
        final targetId = child.getAttribute('id')?.value ?? '';
        if (targetId.isEmpty) {
          return null;
        }
        final reactions = child.children
            .where((reaction) => reaction.name == 'reaction')
            .map((reaction) => reaction.textValue?.trim() ?? '')
            .where((value) => value.isNotEmpty)
            .toList();
        return ReactionUpdate(targetId, reactions);
      }
    }
    return null;
  }

  String? extractReplaceId(XmppElement stanza) {
    for (final candidate in _candidateMessages(stanza)) {
      for (final child in candidate.children) {
        if (child.name != 'replace' ||
            child.getAttribute('xmlns')?.value !=
                'urn:xmpp:message-correct:0') {
          continue;
        }
        final id = child.getAttribute('id')?.value;
        if (id != null && id.isNotEmpty) {
          return id;
        }
      }
    }
    return null;
  }

  bool _hasChildWithXmlns(XmppElement stanza, String name, String xmlns) {
    return _findChildWithXmlns(stanza, name, xmlns) != null;
  }

  XmppElement? _findChildWithXmlns(
    XmppElement stanza,
    String name,
    String xmlns,
  ) {
    for (final child in stanza.children) {
      if (child.name == name && child.getAttribute('xmlns')?.value == xmlns) {
        return child;
      }
    }
    return null;
  }

  List<XmppElement> _candidateMessages(XmppElement stanza) {
    final candidates = <XmppElement>[stanza];
    for (final child in stanza.children) {
      if (child.name != 'result' &&
          child.name != 'sent' &&
          child.name != 'received') {
        continue;
      }
      final forwarded = child.getChild('forwarded');
      final message = forwarded?.getChild('message');
      if (message != null) {
        candidates.add(message);
      }
    }
    final directForwarded = stanza.getChild('forwarded');
    final forwardedMessage = directForwarded?.getChild('message');
    if (forwardedMessage != null) {
      candidates.add(forwardedMessage);
    }
    return candidates;
  }
}
