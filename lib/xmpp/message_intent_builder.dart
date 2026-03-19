import 'package:xmpp_stone/xmpp_stone.dart';

import 'jmi.dart';

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
  const HandleJmiIntent({required this.action});

  final JmiAction action;
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
}

class UnhandledMessageIntent extends MessageIntent {
  const UnhandledMessageIntent({required this.reason});

  final String reason;
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
    required this.isArchivedStanza,
    required this.bareJid,
    required this.hasReceiptRequest,
    required this.hasMarkable,
    required this.serializeStanza,
    required this.now,
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
  final bool Function(MessageStanza stanza) isArchivedStanza;
  final String Function(String jid) bareJid;
  final bool Function(MessageStanza stanza) hasReceiptRequest;
  final bool Function(MessageStanza stanza) hasMarkable;
  final String Function(XmppElement stanza) serializeStanza;
  final DateTime Function() now;

  List<MessageIntent> build(MessageStanza stanza) {
    final fromBare = stanza.fromJid?.userAtDomain ?? '';
    if (fromBare.isEmpty) {
      return const [UnhandledMessageIntent(reason: 'missing-from')];
    }
    final jmiAction = parseJmiAction(stanza);
    if (jmiAction != null) {
      return [HandleJmiIntent(action: jmiAction)];
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
    if (body.trim().isEmpty && (oobUrl == null || oobUrl.isEmpty)) {
      return const [UnhandledMessageIntent(reason: 'empty-body')];
    }
    if (isArchivedStanza(stanza)) {
      return const [UnhandledMessageIntent(reason: 'archived')];
    }
    final selfBare = currentUserBareJid();
    if (selfBare != null && bareJid(fromBare) == selfBare) {
      return const [UnhandledMessageIntent(reason: 'self-message')];
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
      ),
    );
    if (intents.isEmpty) {
      return const [UnhandledMessageIntent(reason: 'no-action')];
    }
    return intents;
  }
}
