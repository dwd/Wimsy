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
      list[i] = ChatMessage(
        from: existing.from,
        to: existing.to,
        body: existing.body,
        outgoing: existing.outgoing,
        timestamp: existing.timestamp,
        messageId: existing.messageId,
        mamId: (mamId != null && mamId.isNotEmpty) ? mamId : existing.mamId,
        stanzaId: (stanzaId != null && stanzaId.isNotEmpty)
            ? stanzaId
            : existing.stanzaId,
        oobUrl: existing.oobUrl,
        oobDescription: nextOobDescription,
        rawXml: nextRawXml,
        fileTransferId: existing.fileTransferId,
        fileName: existing.fileName,
        fileSize: existing.fileSize,
        fileMime: existing.fileMime,
        fileBytes: existing.fileBytes,
        fileState: existing.fileState,
        edited: existing.edited,
        editedAt: existing.editedAt,
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
    list[i] = ChatMessage(
      from: existing.from,
      to: existing.to,
      body: existing.body,
      outgoing: existing.outgoing,
      timestamp: existing.timestamp,
      mamId: (mamId != null && mamId.isNotEmpty) ? mamId : existing.mamId,
      stanzaId: (stanzaId != null && stanzaId.isNotEmpty)
          ? stanzaId
          : existing.stanzaId,
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
