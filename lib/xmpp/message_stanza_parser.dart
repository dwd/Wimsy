import 'package:xmpp_stone/xmpp_stone.dart';

import 'message_intent_builder.dart';

class MessageStanzaParser {
  const MessageStanzaParser();

  static const _replyNs = 'urn:xmpp:reply:0';
  // XEP-0428 renamed its namespace from `urn:xmpp:feature-fallback:0` to
  // `urn:xmpp:fallback:0`. We send the current one but must keep accepting
  // the legacy one, which is still emitted by deployed clients and servers
  // (and by our own MUC handling) — otherwise the quoted fallback text is
  // not stripped and the quote is shown twice.
  static const _fallbackNamespaces = <String>{
    'urn:xmpp:fallback:0',
    'urn:xmpp:feature-fallback:0',
  };

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

  ReplyPayload? extractReplyPayload(XmppElement stanza, {String? body}) {
    for (final candidate in _candidateMessages(stanza)) {
      for (final child in candidate.children) {
        if (child.name != 'reply' ||
            child.getAttribute('xmlns')?.value != _replyNs) {
          continue;
        }
        final id = child.getAttribute('id')?.value?.trim() ?? '';
        if (id.isEmpty) {
          return null;
        }
        final to = child.getAttribute('to')?.value?.trim();
        final fallbackRange = _extractReplyFallbackRange(candidate);
        String? fallbackBody;
        String? cleanedBody = body;
        if (body != null &&
            fallbackRange != null &&
            fallbackRange.end > fallbackRange.start) {
          fallbackBody = _substringByRunes(
            body,
            fallbackRange.start,
            fallbackRange.end,
          )?.trimRight();
          cleanedBody = _removeRuneRange(
            body,
            fallbackRange.start,
            fallbackRange.end,
          );
        }
        return ReplyPayload(
          replyToId: id,
          replyToJid: (to == null || to.isEmpty) ? null : to,
          fallbackBody: (fallbackBody == null || fallbackBody.isEmpty)
              ? null
              : fallbackBody,
          cleanedBody: cleanedBody,
        );
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

  _FallbackRange? _extractReplyFallbackRange(XmppElement stanza) {
    for (final child in stanza.children) {
      if (child.name != 'fallback') {
        continue;
      }
      final xmlns = child.getAttribute('xmlns')?.value;
      if (!_fallbackNamespaces.contains(xmlns)) {
        continue;
      }
      final forNamespace = child.getAttribute('for')?.value?.trim();
      if (forNamespace != null &&
          forNamespace.isNotEmpty &&
          forNamespace != _replyNs) {
        continue;
      }
      final body = child.children.firstWhere(
        (element) => element.name == 'body',
        orElse: () => XmppElement(),
      );
      if (body.name != 'body') {
        continue;
      }
      final start = int.tryParse(body.getAttribute('start')?.value ?? '0') ?? 0;
      final endRaw = body.getAttribute('end')?.value;
      final end = int.tryParse(endRaw ?? '') ?? start;
      if (start < 0 || end < start) {
        continue;
      }
      return _FallbackRange(start, end);
    }
    return null;
  }

  String? _substringByRunes(String input, int start, int end) {
    final runes = input.runes.toList();
    if (start < 0 || end < start || start > runes.length) {
      return null;
    }
    final safeEnd = end > runes.length ? runes.length : end;
    return String.fromCharCodes(runes.sublist(start, safeEnd));
  }

  String _removeRuneRange(String input, int start, int end) {
    final runes = input.runes.toList();
    if (start < 0 || end < start || start > runes.length) {
      return input;
    }
    final safeEnd = end > runes.length ? runes.length : end;
    if (safeEnd <= start) {
      return input;
    }
    final before = runes.sublist(0, start);
    final after = runes.sublist(safeEnd);
    return String.fromCharCodes(before.followedBy(after));
  }
}

class _FallbackRange {
  const _FallbackRange(this.start, this.end);

  final int start;
  final int end;
}
