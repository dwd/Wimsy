import '../models/chat_message.dart';

bool mergeMamIdsIntoExisting(
  List<ChatMessage> list, {
  required String from,
  required String to,
  required String body,
  String? oobUrl,
  String? oobDescription,
  String? rawXml,
  required bool outgoing,
  required DateTime timestamp,
  String? messageId,
  String? mamId,
  String? stanzaId,
}) {
  const mergeWindow = Duration(minutes: 2);
  for (var i = 0; i < list.length; i++) {
    final existing = list[i];
    if (messageId != null &&
        messageId.isNotEmpty &&
        existing.messageId == messageId &&
        ((existing.mamId ?? '').isEmpty || (existing.stanzaId ?? '').isEmpty)) {
      final nextRawXml = (rawXml != null && rawXml.isNotEmpty)
          ? rawXml
          : existing.rawXml;
      final nextOobDescription =
          (oobDescription != null && oobDescription.isNotEmpty)
          ? oobDescription
          : existing.oobDescription;
      list[i] = existing.copyWith(
        mamId: (mamId != null && mamId.isNotEmpty) ? mamId : existing.mamId,
        stanzaId: (stanzaId != null && stanzaId.isNotEmpty)
            ? stanzaId
            : existing.stanzaId,
        oobDescription: nextOobDescription,
        rawXml: nextRawXml,
      );
      return true;
    }
    if (existing.body != body ||
        (existing.oobUrl ?? '') != (oobUrl ?? '') ||
        existing.from != from ||
        existing.to != to ||
        existing.outgoing != outgoing) {
      continue;
    }
    final timeDelta = existing.timestamp.difference(timestamp).abs();
    if (timeDelta > mergeWindow) {
      continue;
    }
    if ((existing.mamId ?? '').isNotEmpty ||
        (existing.stanzaId ?? '').isNotEmpty) {
      continue;
    }
    list[i] = existing.copyWith(
      messageId:
          (existing.messageId ?? '').isEmpty &&
              messageId != null &&
              messageId.isNotEmpty
          ? messageId
          : existing.messageId,
      mamId: (mamId != null && mamId.isNotEmpty) ? mamId : existing.mamId,
      stanzaId: (stanzaId != null && stanzaId.isNotEmpty)
          ? stanzaId
          : existing.stanzaId,
    );
    return true;
  }
  return false;
}
