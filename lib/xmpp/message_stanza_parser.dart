import 'dart:convert';

import 'package:spiffing/spiffing.dart' as spiffing;
import 'package:xmpp_stone/xmpp_stone.dart';

import 'message_intent_builder.dart';
import 'webxdc.dart';

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

  // XEP-0258: extracts the human-readable marking of a `<securitylabel/>`
  // envelope. We first try to actually parse the primary `<label/>`
  // against a security policy (SPIF) we know about, which is the only way
  // to get a marking that's guaranteed to match the label's real meaning.
  // When that isn't possible (no policy known, unsupported/undecodable
  // label format, empty `<label/>`, ...) we fall back to the server's
  // pre-rendered `<displaymarking/>`, flagging the result as a fallback so
  // the UI can warn that it hasn't been policy-verified.
  SecurityLabelInfo? extractSecurityLabel(XmppElement stanza) {
    for (final candidate in _candidateMessages(stanza)) {
      for (final child in candidate.children) {
        if (child.name != 'securitylabel' ||
            child.getAttribute('xmlns')?.value != 'urn:xmpp:sec-label:0') {
          continue;
        }
        return parseSecurityLabelElement(child);
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

  // XEP-0491: extracts the top-level `<thread/>` id linking a widget
  // offer message and its subsequent updates. Only looked up on the
  // stanza (or its forwarded candidates) directly, matching how
  // `<thread/>` is a top-level message child.
  String? extractThread(XmppElement stanza) {
    for (final candidate in _candidateMessages(stanza)) {
      for (final child in candidate.children) {
        if (child.name != 'thread') {
          continue;
        }
        final id = child.textValue?.trim();
        if (id != null && id.isNotEmpty) {
          return id;
        }
      }
    }
    return null;
  }

  // XEP-0491: extracts the `<x xmlns='urn:xmpp:webxdc:0'>` payload of a
  // widget update message, if present. An empty `<x/>` (no children)
  // still yields a non-null [WebxdcUpdatePayload] with all fields null,
  // since its mere presence signals "this is a widget update".
  WebxdcUpdatePayload? extractWebxdcUpdate(XmppElement stanza) {
    for (final candidate in _candidateMessages(stanza)) {
      for (final child in candidate.children) {
        if (child.name != 'x' ||
            child.getAttribute('xmlns')?.value != webxdcNamespace) {
          continue;
        }
        final document = child.getChild('document')?.textValue?.trim();
        final summary = child.getChild('summary')?.textValue?.trim();
        final json = child.getChild('json')?.textValue?.trim();
        return WebxdcUpdatePayload(
          document: (document == null || document.isEmpty)
              ? null
              : document,
          summary: (summary == null || summary.isEmpty) ? null : summary,
          json: (json == null || json.isEmpty) ? null : json,
        );
      }
    }
    return null;
  }

  // XEP-0491: whether this stanza is the initial widget-sharing offer
  // (as opposed to a plain file/oob attachment, or a later widget
  // update). This requires a `<thread/>` id together with either an oob
  // URL ending in `.xdc`, or a XEP-0385 `<sims/>` (media-sharing) child
  // whose nested `<file/>` descriptor declares [webxdcMediaType].
  bool isWebxdcWidgetOffer(XmppElement stanza, {String? oobUrl}) {
    if (extractThread(stanza) == null) {
      return false;
    }
    if (oobUrl != null && oobUrl.toLowerCase().endsWith('.xdc')) {
      return true;
    }
    for (final candidate in _candidateMessages(stanza)) {
      for (final child in candidate.children) {
        if (child.name != 'sims' &&
            child.name != 'media-sharing') {
          continue;
        }
        if (child.getAttribute('xmlns')?.value != 'urn:xmpp:sims:1') {
          continue;
        }
        final file = child.getChild('file');
        final mediaType = file
            ?.getChild('media-type')
            ?.textValue
            ?.trim();
        if (mediaType == webxdcMediaType) {
          return true;
        }
      }
    }
    return false;
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

// XEP-0258: parses a `<securitylabel xmlns="urn:xmpp:sec-label:0"/>`
// element into its human-readable marking. Shared by
// [MessageStanzaParser.extractSecurityLabel] (inline labels on a message)
// and `parseSecurityLabelCatalog` (the `<item/>` entries of a catalogue
// response) since both carry an identically-shaped `<securitylabel/>`.
//
// We first try to actually parse the primary `<label/>` against a security
// policy (SPIF) we know about, which is the only way to get a marking
// that's guaranteed to match the label's real meaning. When that isn't
// possible (no policy known, unsupported/undecodable label format, empty
// `<label/>`, ...) we fall back to the server's pre-rendered
// `<displaymarking/>`, flagging the result as a fallback so the UI can
// warn that it hasn't been policy-verified.
SecurityLabelInfo? parseSecurityLabelElement(XmppElement securityLabel) {
  final parsed = _tryParseLabelMarking(securityLabel);
  if (parsed != null) {
    return parsed;
  }
  final marking = securityLabel.getChild('displaymarking');
  final text = marking?.textValue?.trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  final fgColor = marking?.getAttribute('fgcolor')?.value?.trim();
  final bgColor = marking?.getAttribute('bgcolor')?.value?.trim();
  return SecurityLabelInfo(
    text: text,
    fgColor: (fgColor == null || fgColor.isEmpty) ? null : fgColor,
    bgColor: (bgColor == null || bgColor.isEmpty) ? null : bgColor,
    isFallback: true,
  );
}

// Attempts to parse the `<securitylabel/>`'s `<label/>` child (the
// primary, policy-encoded label) and render its display marking against a
// known SPIF. Returns null (never throws) if the label is empty,
// unsupported, or otherwise cannot be decoded/rendered - callers should
// then fall back to the server-supplied `<displaymarking/>`.
SecurityLabelInfo? _tryParseLabelMarking(XmppElement securityLabel) {
  final labelElement = securityLabel.getChild('label');
  if (labelElement == null || labelElement.children.isEmpty) {
    // An empty <label/> explicitly means "use the default label" per
    // XEP-0258, which we don't currently model - fall back.
    return null;
  }
  final essLabel = labelElement.children.firstWhere(
    (c) =>
        c.name == 'esssecuritylabel' &&
        c.getAttribute('xmlns')?.value == 'urn:xmpp:sec-label:ess:0',
    orElse: () => XmppElement(),
  );
  final base64Data = essLabel.textValue?.trim();
  if (essLabel.name == null || base64Data == null || base64Data.isEmpty) {
    // Only the ESS/BER encoding (the only one shown in XEP-0258 itself)
    // is currently supported.
    return null;
  }
  try {
    final bytes = base64.decode(base64Data);
    final data = latin1.decode(bytes);
    final label = spiffing.Label.parse(data, spiffing.Format.ber);
    final text = label.policy.displayMarking(label);
    if (text.trim().isEmpty) {
      return null;
    }
    final fgColour = label.classification.fgcolour.trim();
    return SecurityLabelInfo(
      text: text,
      fgColor: fgColour.isEmpty ? null : fgColour,
    );
  } catch (_) {
    // No policy known for this label, undecodable data, etc. - fall back
    // to the server-supplied <displaymarking/>.
    return null;
  }
}
