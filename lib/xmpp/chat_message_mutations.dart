import '../models/chat_message.dart';
import 'message_intent_builder.dart';

class ChatMessageMutations {
  static bool applyCorrectionInList(
    List<ChatMessage> list, {
    required String sender,
    required String replaceId,
    required String newBody,
    required String rawXml,
    required DateTime timestamp,
    required bool matchSenderBare,
    required String Function(String jid) bareJid,
    String? oobUrl,
    String? oobDescription,
  }) {
    for (var i = list.length - 1; i >= 0; i--) {
      final existing = list[i];
      if (existing.messageId != replaceId) {
        continue;
      }
      if (matchSenderBare) {
        if (bareJid(existing.from) != bareJid(sender)) {
          continue;
        }
      } else {
        if (existing.from != sender) {
          continue;
        }
      }
      final nextOobUrl = (oobUrl != null && oobUrl.isNotEmpty)
          ? oobUrl
          : existing.oobUrl;
      final nextRawXml = rawXml.isNotEmpty ? rawXml : existing.rawXml;
      final nextOobDescription =
          (oobDescription != null && oobDescription.isNotEmpty)
          ? oobDescription
          : existing.oobDescription;
      final nextEditedAt = timestamp;
      if (existing.body == newBody &&
          existing.oobUrl == nextOobUrl &&
          existing.oobDescription == nextOobDescription &&
          existing.rawXml == nextRawXml &&
          existing.edited &&
          existing.editedAt == nextEditedAt) {
        return true;
      }
      list[i] = ChatMessage(
        from: existing.from,
        to: existing.to,
        body: newBody,
        outgoing: existing.outgoing,
        timestamp: existing.timestamp,
        messageId: existing.messageId,
        mamId: existing.mamId,
        stanzaId: existing.stanzaId,
        oobUrl: nextOobUrl,
        oobDescription: nextOobDescription,
        rawXml: nextRawXml,
        inviteRoomJid: existing.inviteRoomJid,
        inviteReason: existing.inviteReason,
        invitePassword: existing.invitePassword,
        fileTransferId: existing.fileTransferId,
        fileName: existing.fileName,
        fileSize: existing.fileSize,
        fileMime: existing.fileMime,
        fileBytes: existing.fileBytes,
        fileState: existing.fileState,
        edited: true,
        editedAt: nextEditedAt,
        reactions: existing.reactions ?? const {},
        replyToId: existing.replyToId,
        replyToJid: existing.replyToJid,
        replyFallback: existing.replyFallback,
        acked: existing.acked,
        receiptReceived: existing.receiptReceived,
        displayed: existing.displayed,
      );
      return true;
    }
    return false;
  }

  static bool updateReactionsInList(
    List<ChatMessage> list,
    String sender,
    ReactionUpdate update,
  ) {
    if (sender.isEmpty || update.targetId.isEmpty) {
      return false;
    }
    for (var i = list.length - 1; i >= 0; i--) {
      final existing = list[i];
      if (existing.stanzaId != update.targetId &&
          existing.messageId != update.targetId) {
        continue;
      }
      final nextReactions = _nextReactions(
        existing.reactions ?? const {},
        sender,
        update.reactions,
      );
      if (_reactionsEqual(existing.reactions ?? const {}, nextReactions)) {
        return true;
      }
      list[i] = ChatMessage(
        from: existing.from,
        to: existing.to,
        body: existing.body,
        outgoing: existing.outgoing,
        timestamp: existing.timestamp,
        messageId: existing.messageId,
        mamId: existing.mamId,
        stanzaId: existing.stanzaId,
        oobUrl: existing.oobUrl,
        oobDescription: existing.oobDescription,
        rawXml: existing.rawXml,
        fileTransferId: existing.fileTransferId,
        fileName: existing.fileName,
        fileSize: existing.fileSize,
        fileMime: existing.fileMime,
        fileBytes: existing.fileBytes,
        fileState: existing.fileState,
        edited: existing.edited,
        editedAt: existing.editedAt,
        reactions: nextReactions,
        replyToId: existing.replyToId,
        replyToJid: existing.replyToJid,
        replyFallback: existing.replyFallback,
        acked: existing.acked,
        receiptReceived: existing.receiptReceived,
        displayed: existing.displayed,
      );
      return true;
    }
    return false;
  }

  static Map<String, List<String>> _nextReactions(
    Map<String, List<String>> existing,
    String sender,
    List<String> reactions,
  ) {
    final next = <String, Set<String>>{};
    existing.forEach((emoji, senders) {
      final filtered = senders
          .where((value) => value.isNotEmpty && value != sender)
          .toSet();
      if (filtered.isNotEmpty) {
        next[emoji] = filtered;
      }
    });
    for (final reaction in reactions) {
      if (reaction.isEmpty) {
        continue;
      }
      final set = next.putIfAbsent(reaction, () => <String>{});
      set.add(sender);
    }
    final result = <String, List<String>>{};
    for (final entry in next.entries) {
      final senders = entry.value.toList()..sort();
      if (senders.isNotEmpty) {
        result[entry.key] = senders;
      }
    }
    return result;
  }

  static bool _reactionsEqual(
    Map<String, List<String>> a,
    Map<String, List<String>> b,
  ) {
    if (a.length != b.length) {
      return false;
    }
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || other.length != entry.value.length) {
        return false;
      }
      final sortedA = List<String>.from(entry.value)..sort();
      final sortedB = List<String>.from(other)..sort();
      for (var i = 0; i < sortedA.length; i += 1) {
        if (sortedA[i] != sortedB[i]) {
          return false;
        }
      }
    }
    return true;
  }
}
