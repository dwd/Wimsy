import 'package:xmpp_stone/xmpp_stone.dart';

import 'jmi.dart';
import 'webxdc.dart';

class ReactionUpdate {
  ReactionUpdate(this.targetId, this.reactions);

  final String targetId;
  final List<String> reactions;
}

class OobInfo {
  const OobInfo({required this.url, this.description});

  final String url;
  final String? description;
}

/// The human-readable marking of a XEP-0258 `<securitylabel/>` envelope.
///
/// [text]/[fgColor]/[bgColor] are either derived by actually parsing the
/// `<label/>` against a known security policy (SPIF) — the preferred,
/// policy-accurate path — or, when that isn't possible (no policy known,
/// unsupported/undecodable label format, ...), taken from the server's
/// pre-rendered `<displaymarking/>` as a fallback. [isFallback] tells the
/// UI which of the two happened, so it can warn the user that the shown
/// marking hasn't been policy-verified.
class SecurityLabelInfo {
  const SecurityLabelInfo({
    required this.text,
    this.fgColor,
    this.bgColor,
    this.isFallback = false,
  });

  final String text;
  final String? fgColor;
  final String? bgColor;
  final bool isFallback;
}

class ReplyPayload {
  const ReplyPayload({
    required this.replyToId,
    this.replyToJid,
    this.fallbackBody,
    this.cleanedBody,
  });

  final String replyToId;
  final String? replyToJid;
  final String? fallbackBody;
  final String? cleanedBody;
}

class MessageScopedId {
  const MessageScopedId({required this.scopeJid, required this.id});

  final String scopeJid;
  final String id;
}

typedef ReplyPayloadExtractor =
    ReplyPayload? Function(XmppElement stanza, {String? body});

abstract class MessageIntent {
  const MessageIntent();
}

class HandleJmiIntent extends MessageIntent {
  const HandleJmiIntent({required this.action, required this.archived});

  final JmiAction action;
  final bool archived;
}

class ApplyReceiptIntent extends MessageIntent {
  const ApplyReceiptIntent({required this.scopedId});

  final MessageScopedId scopedId;
}

class ApplyDisplayedIntent extends MessageIntent {
  const ApplyDisplayedIntent({required this.scopedId});

  final MessageScopedId scopedId;
}

class ApplyReactionIntent extends MessageIntent {
  const ApplyReactionIntent({
    required this.targetBareJid,
    required this.senderBareJid,
    required this.update,
  });

  final String targetBareJid;
  final String senderBareJid;
  final ReactionUpdate update;
}

class SendReceiptIntent extends MessageIntent {
  const SendReceiptIntent({required this.toBareJid, required this.scopedId});

  final String toBareJid;
  final MessageScopedId scopedId;
}

class SendMarkerIntent extends MessageIntent {
  const SendMarkerIntent({
    required this.toBareJid,
    required this.scopedId,
    required this.name,
  });

  final String toBareJid;
  final MessageScopedId scopedId;
  final String name;
}

class AddMessageIntent extends MessageIntent {
  const AddMessageIntent({
    required this.bareJid,
    required this.from,
    required this.to,
    required this.body,
    required this.timestamp,
    required this.messageId,
    required this.rawXml,
    this.oobUrl,
    this.oobDescription,
    this.replyToId,
    this.replyToJid,
    this.replyFallback,
    this.securityLabelText,
    this.securityLabelFgColor,
    this.securityLabelBgColor,
    this.securityLabelIsFallback = false,
  });

  final String bareJid;
  final String from;
  final String to;
  final String body;
  final DateTime timestamp;
  final String messageId;
  final String rawXml;
  final String? oobUrl;
  final String? oobDescription;
  final String? replyToId;
  final String? replyToJid;
  final String? replyFallback;
  final String? securityLabelText;
  final String? securityLabelFgColor;
  final String? securityLabelBgColor;
  final bool securityLabelIsFallback;
}

class UnhandledMessageIntent extends MessageIntent {
  const UnhandledMessageIntent({required this.reason});

  final String reason;
}

// XEP-0491: applies a WebXDC widget update - either the initial
// widget-sharing offer (see [isOffer]) or a later state update reusing
// the same [threadId].
class ApplyWebxdcUpdateIntent extends MessageIntent {
  const ApplyWebxdcUpdateIntent({
    required this.targetBareJid,
    required this.threadId,
    required this.update,
    this.info,
    required this.isOffer,
    this.fileTransferOobUrl,
    this.fileName,
  });

  final String targetBareJid;
  final String threadId;
  final WebxdcUpdatePayload update;
  final String? info;
  final bool isOffer;
  final String? fileTransferOobUrl;
  final String? fileName;
}

class MessageIntentBuilder {
  MessageIntentBuilder({
    required this.currentUserBareJid,
    required this.activeChatBareJid,
    required this.parseJmiAction,
    required this.extractReceiptsId,
    required this.extractMarkerId,
    required this.extractReactionUpdate,
    required this.reactionChatTarget,
    required this.extractOobInfoFromStanza,
    this.extractReplyPayload,
    this.extractSecurityLabel,
    required this.isArchivedStanza,
    required this.bareJid,
    required this.hasReceiptRequest,
    required this.hasMarkable,
    required this.serializeStanza,
    required this.now,
    required this.extractThread,
    required this.extractWebxdcUpdate,
    required this.isWebxdcWidgetOffer,
  });

  final String? Function() currentUserBareJid;
  final String? Function() activeChatBareJid;
  final JmiAction? Function(MessageStanza stanza) parseJmiAction;
  final String? Function(MessageStanza stanza) extractReceiptsId;
  final String? Function(MessageStanza stanza, String name) extractMarkerId;
  final ReactionUpdate? Function(MessageStanza stanza) extractReactionUpdate;
  final String Function(String fromBare, String toBare) reactionChatTarget;
  final OobInfo? Function(XmppElement stanza) extractOobInfoFromStanza;
  final ReplyPayloadExtractor? extractReplyPayload;
  // XEP-0258: extracts the `<displaymarking/>` of a `<securitylabel/>`
  // envelope, when present.
  final SecurityLabelInfo? Function(XmppElement stanza)? extractSecurityLabel;
  final bool Function(MessageStanza stanza) isArchivedStanza;
  final String Function(String jid) bareJid;
  final bool Function(MessageStanza stanza) hasReceiptRequest;
  final bool Function(MessageStanza stanza) hasMarkable;
  final String Function(XmppElement stanza) serializeStanza;
  final DateTime Function() now;
  // XEP-0491: extracts the `<thread/>` id linking a widget offer message
  // and its subsequent updates.
  final String? Function(MessageStanza stanza) extractThread;
  // XEP-0491: extracts the `<x xmlns='urn:xmpp:webxdc:0'>` payload of a
  // widget update message, when present.
  final WebxdcUpdatePayload? Function(MessageStanza stanza)
  extractWebxdcUpdate;
  // XEP-0491: whether this stanza is the initial widget-sharing offer.
  final bool Function(MessageStanza stanza, String? oobUrl)
  isWebxdcWidgetOffer;

  List<MessageIntent> build(MessageStanza stanza) {
    final fromBare = stanza.fromJid?.userAtDomain ?? '';
    if (fromBare.isEmpty) {
      return const [UnhandledMessageIntent(reason: 'missing-from')];
    }
    final jmiAction = parseJmiAction(stanza);
    if (jmiAction != null) {
      return [
        HandleJmiIntent(action: jmiAction, archived: isArchivedStanza(stanza)),
      ];
    }
    final receiptId = extractReceiptsId(stanza);
    if (receiptId != null) {
      return [
        ApplyReceiptIntent(
          scopedId: MessageScopedId(scopeJid: fromBare, id: receiptId),
        ),
      ];
    }
    final displayedId = extractMarkerId(stanza, 'displayed');
    if (displayedId != null) {
      return [
        ApplyDisplayedIntent(
          scopedId: MessageScopedId(scopeJid: fromBare, id: displayedId),
        ),
      ];
    }
    final reaction = extractReactionUpdate(stanza);
    if (reaction != null) {
      final targetBare = reactionChatTarget(
        fromBare,
        stanza.toJid?.userAtDomain ?? '',
      );
      if (targetBare.isEmpty) {
        return const [UnhandledMessageIntent(reason: 'reaction-target-empty')];
      }
      return [
        ApplyReactionIntent(
          targetBareJid: targetBare,
          senderBareJid: fromBare,
          update: reaction,
        ),
      ];
    }
    ReplyPayload? reply;
    final replyExtractor = extractReplyPayload;
    if (replyExtractor != null) {
      reply = replyExtractor(stanza, body: stanza.body);
    }
    final body = reply?.cleanedBody ?? stanza.body ?? '';
    final oobInfo = extractOobInfoFromStanza(stanza);
    final oobUrl = oobInfo?.url;
    final securityLabel = extractSecurityLabel?.call(stanza);
    if (isArchivedStanza(stanza)) {
      return const [UnhandledMessageIntent(reason: 'archived')];
    }
    final selfBare = currentUserBareJid();
    if (selfBare != null && bareJid(fromBare) == selfBare) {
      return const [UnhandledMessageIntent(reason: 'self-message')];
    }
    // XEP-0491: widget offers/updates can carry an empty body and/or no
    // oob attachment, so they must be recognised before the generic
    // empty-body bail-out below.
    final threadId = extractThread(stanza);
    final webxdcUpdate = extractWebxdcUpdate(stanza);
    final isOffer = isWebxdcWidgetOffer(stanza, oobUrl);
    final isWebxdcMessage =
        webxdcUpdate != null || (threadId != null && isOffer);
    if (!isWebxdcMessage &&
        body.trim().isEmpty &&
        (oobUrl == null || oobUrl.isEmpty)) {
      return const [UnhandledMessageIntent(reason: 'empty-body')];
    }
    final messageId = stanza.id;
    if (messageId == null || messageId.isEmpty) {
      return const [UnhandledMessageIntent(reason: 'missing-message-id')];
    }
    final intents = <MessageIntent>[];
    if (hasReceiptRequest(stanza)) {
      intents.add(
        SendReceiptIntent(
          toBareJid: fromBare,
          scopedId: MessageScopedId(scopeJid: fromBare, id: messageId),
        ),
      );
    }
    if (hasMarkable(stanza)) {
      intents.add(
        SendMarkerIntent(
          toBareJid: fromBare,
          scopedId: MessageScopedId(scopeJid: fromBare, id: messageId),
          name: 'received',
        ),
      );
      final activeBare = activeChatBareJid();
      if (activeBare != null && bareJid(activeBare) == bareJid(fromBare)) {
        intents.add(
          SendMarkerIntent(
            toBareJid: fromBare,
            scopedId: MessageScopedId(scopeJid: fromBare, id: messageId),
            name: 'displayed',
          ),
        );
      }
    }
    if (isWebxdcMessage) {
      intents.add(
        ApplyWebxdcUpdateIntent(
          targetBareJid: fromBare,
          threadId: threadId ?? '',
          update: webxdcUpdate ?? const WebxdcUpdatePayload(),
          info: body.trim().isEmpty ? null : body,
          isOffer: isOffer,
          fileTransferOobUrl: isOffer ? oobUrl : null,
          fileName: isOffer ? _deriveWebxdcFileName(oobInfo) : null,
        ),
      );
    } else {
      intents.add(
        AddMessageIntent(
          bareJid: fromBare,
          from: fromBare,
          to: stanza.toJid?.userAtDomain ?? '',
          body: body,
          timestamp: now(),
          messageId: messageId,
          rawXml: serializeStanza(stanza),
          oobUrl: oobUrl,
          oobDescription: oobInfo?.description,
          replyToId: reply?.replyToId,
          replyToJid: reply?.replyToJid,
          replyFallback: reply?.fallbackBody,
          securityLabelText: securityLabel?.text,
          securityLabelFgColor: securityLabel?.fgColor,
          securityLabelBgColor: securityLabel?.bgColor,
          securityLabelIsFallback: securityLabel?.isFallback ?? false,
        ),
      );
    }
    if (intents.isEmpty) {
      return const [UnhandledMessageIntent(reason: 'no-action')];
    }
    return intents;
  }
}

// XEP-0491: derives a simple display filename for a widget offer's `.xdc`
// attachment - the oob `<desc/>` if present, otherwise the last path
// segment of the oob URL.
String? _deriveWebxdcFileName(OobInfo? oobInfo) {
  final description = oobInfo?.description;
  if (description != null && description.isNotEmpty) {
    return description;
  }
  final url = oobInfo?.url;
  if (url == null || url.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(url);
  final segments = uri?.pathSegments ?? const <String>[];
  for (final segment in segments.reversed) {
    if (segment.isNotEmpty) {
      return segment;
    }
  }
  return null;
}
