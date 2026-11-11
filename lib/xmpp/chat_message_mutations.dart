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
      list[i] = existing.copyWith(
        body: newBody,
        oobUrl: nextOobUrl,
        oobDescription: nextOobDescription,
        rawXml: nextRawXml,
        edited: true,
        editedAt: nextEditedAt,
      );
      return true;
    }
    return false;
  }

  // XEP-0424: finds the message in [list] whose [messageId] (origin-id)
  // matches [retractId] and marks it retracted. This only covers "live
  // retractions" - i.e. observing the `<retract/>` request itself - and
  // deliberately keeps the original body so the UI can render it struck
  // through rather than clearing it. Returns true when a matching message
  // was found (whether or not it was already marked retracted).
  //
  // Authorisation: a retraction is only honoured when [sender] (and, for
  // MUC, [senderOccupantId]) matches the identity that sent the original
  // message - otherwise any occupant/contact could forge a retraction for
  // someone else's message. For 1:1 chats ([matchSenderBare] is true) the
  // bare JID of the retraction's sender must match the bare JID of the
  // original message's sender. For MUC ([matchSenderBare] is false), when
  // both the original message and the retraction request disclose a
  // XEP-0421 occupant-id, those must match (robust against nickname
  // changes); otherwise this falls back to an exact nickname (full JID)
  // match, as recommended by XEP-0424 when occupant-id is unavailable.
  static bool applyRetractionInList(
    List<ChatMessage> list, {
    required String sender,
    required String retractId,
    required DateTime timestamp,
    required bool matchSenderBare,
    required String Function(String jid) bareJid,
    String? senderOccupantId,
  }) {
    for (var i = list.length - 1; i >= 0; i--) {
      final existing = list[i];
      if (existing.messageId != retractId) {
        continue;
      }
      if (matchSenderBare) {
        if (bareJid(existing.from) != bareJid(sender)) {
          continue;
        }
      } else {
        final existingOccupantId = existing.senderOccupantId;
        if (existingOccupantId != null &&
            existingOccupantId.isNotEmpty &&
            senderOccupantId != null &&
            senderOccupantId.isNotEmpty) {
          if (existingOccupantId != senderOccupantId) {
            continue;
          }
        } else if (existing.from != sender) {
          continue;
        }
      }
      if (existing.retracted && existing.retractedAt == timestamp) {
        return true;
      }
      list[i] = existing.copyWith(retracted: true, retractedAt: timestamp);
      return true;
    }
    return false;
  }

  // XEP-0425: finds the message in [list] whose [stanzaId] (the XEP-0359
  // archive id assigned by the MUC service) matches [applyToId] and marks
  // it as moderated: struck through (like a XEP-0424 retraction), but
  // flagged distinctly via [ChatMessage.moderated] so the UI can show a
  // "Moderated" chip instead of "Retracted". When [reason] is supplied by
  // the moderator, it replaces the message's body entirely.
  //
  // Authorisation: unlike [applyRetractionInList], no sender/occupant
  // check is needed here - this is only ever called for moderation
  // notices that the MUC service itself sent from the room's bare JID
  // (the room has already verified the moderator's authority before
  // generating and broadcasting the notice), not from an arbitrary
  // occupant.
  static bool applyModerationInList(
    List<ChatMessage> list, {
    required String applyToId,
    required DateTime timestamp,
    String? reason,
  }) {
    if (applyToId.isEmpty) {
      return false;
    }
    for (var i = list.length - 1; i >= 0; i--) {
      final existing = list[i];
      if (existing.stanzaId != applyToId) {
        continue;
      }
      if (existing.moderated && existing.retractedAt == timestamp) {
        return true;
      }
      final hasReason = reason != null && reason.isNotEmpty;
      list[i] = existing.copyWith(
        retracted: true,
        retractedAt: timestamp,
        moderated: true,
        moderationReason: hasReason ? reason : null,
        body: hasReason ? reason : existing.body,
      );
      return true;
    }
    return false;
  }

  // XEP-0491: finds the last message in [list] with a matching
  // [webxdcThreadId] and merges any non-null/non-empty document, summary,
  // and json payload into it. Returns true when a matching message was
  // found (whether or not any field actually changed).
  static bool applyWebxdcUpdateInList(
    List<ChatMessage> list, {
    required String threadId,
    String? document,
    String? summary,
    String? jsonPayload,
  }) {
    if (threadId.isEmpty) {
      return false;
    }
    for (var i = list.length - 1; i >= 0; i--) {
      final existing = list[i];
      if (existing.webxdcThreadId != threadId) {
        continue;
      }
      final nextDocument = (document != null && document.isNotEmpty)
          ? document
          : existing.webxdcDocument;
      final nextSummary = (summary != null && summary.isNotEmpty)
          ? summary
          : existing.webxdcSummary;
      final nextJsonPayload = (jsonPayload != null && jsonPayload.isNotEmpty)
          ? jsonPayload
          : existing.webxdcJsonPayload;
      if (existing.webxdcDocument == nextDocument &&
          existing.webxdcSummary == nextSummary &&
          existing.webxdcJsonPayload == nextJsonPayload) {
        return true;
      }
      list[i] = existing.copyWith(
        webxdcDocument: nextDocument,
        webxdcSummary: nextSummary,
        webxdcJsonPayload: nextJsonPayload,
      );
      return true;
    }
    return false;
  }

  static bool updateReactionsInList(
    List<ChatMessage> list,
    String sender,
    ReactionUpdate update, {
    required bool isRoom,
  }) {
    if (sender.isEmpty || update.targetId.isEmpty) {
      return false;
    }
    for (var i = list.length - 1; i >= 0; i--) {
      final existing = list[i];
      final matchesTarget = isRoom
          ? existing.stanzaId == update.targetId ||
                existing.mamId == update.targetId
          : existing.messageId == update.targetId;
      if (!matchesTarget) {
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
      list[i] = existing.copyWith(reactions: nextReactions);
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
