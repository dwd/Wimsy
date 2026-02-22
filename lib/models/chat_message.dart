class ChatMessage {
  ChatMessage({
    required this.from,
    required this.to,
    required this.body,
    required this.timestamp,
    required this.outgoing,
    this.messageId,
    this.mamId,
    this.stanzaId,
    this.oobUrl,
    this.oobDescription,
    this.rawXml,
    this.inviteRoomJid,
    this.inviteReason,
    this.invitePassword,
    this.fileTransferId,
    this.fileName,
    this.fileSize,
    this.fileMime,
    this.fileBytes,
    this.fileState,
    this.edited = false,
    this.editedAt,
    this.reactions,
    this.acked = false,
    this.receiptReceived = false,
    this.displayed = false,
  });

  final String from;
  final String to;
  final String body;
  final DateTime timestamp;
  final bool outgoing;
  final String? messageId;
  final String? mamId;
  final String? stanzaId;
  final String? oobUrl;
  final String? oobDescription;
  final String? rawXml;
  final String? inviteRoomJid;
  final String? inviteReason;
  final String? invitePassword;
  final String? fileTransferId;
  final String? fileName;
  final int? fileSize;
  final String? fileMime;
  final int? fileBytes;
  final String? fileState;
  final bool edited;
  final DateTime? editedAt;
  final Map<String, List<String>>? reactions;
  final bool acked;
  final bool receiptReceived;
  final bool displayed;

  Map<String, dynamic> toMap() {
    return {
      'from': from,
      'to': to,
      'body': body,
      'timestamp': timestamp.toIso8601String(),
      'outgoing': outgoing,
      'messageId': messageId,
      'mamId': mamId,
      'stanzaId': stanzaId,
      'oobUrl': oobUrl,
      'oobDescription': oobDescription,
      'rawXml': rawXml,
      'inviteRoomJid': inviteRoomJid,
      'inviteReason': inviteReason,
      'invitePassword': invitePassword,
      'fileTransferId': fileTransferId,
      'fileName': fileName,
      'fileSize': fileSize,
      'fileMime': fileMime,
      'fileBytes': fileBytes,
      'fileState': fileState,
      'edited': edited,
      'editedAt': editedAt?.toIso8601String(),
      'reactions': reactions ?? const {},
      'acked': acked,
      'receiptReceived': receiptReceived,
      'displayed': displayed,
    };
  }

  static ChatMessage? fromMap(Map<String, dynamic>? map) {
    if (map == null) {
      return null;
    }
    final from = map['from']?.toString() ?? '';
    final to = map['to']?.toString() ?? '';
    final body = map['body']?.toString() ?? '';
    final ts = map['timestamp']?.toString() ?? '';
    final outgoing = map['outgoing'] == true;
    final messageId = map['messageId']?.toString();
    final mamId = map['mamId']?.toString();
    final stanzaId = map['stanzaId']?.toString();
    final oobUrl = map['oobUrl']?.toString();
    final oobDescription = map['oobDescription']?.toString();
    final rawXml = map['rawXml']?.toString();
    final inviteRoomJid = map['inviteRoomJid']?.toString();
    final inviteReason = map['inviteReason']?.toString();
    final invitePassword = map['invitePassword']?.toString();
    final fileTransferId = map['fileTransferId']?.toString();
    final fileName = map['fileName']?.toString();
    final fileSizeRaw = map['fileSize'];
    final fileBytesRaw = map['fileBytes'];
    final fileMime = map['fileMime']?.toString();
    final fileState = map['fileState']?.toString();
    final edited = map['edited'] == true;
    final editedAtRaw = map['editedAt']?.toString();
    final reactions = _parseReactions(map['reactions']);
    final acked = map['acked'] == true;
    final receiptReceived = map['receiptReceived'] == true;
    final displayed = map['displayed'] == true;
    final fileSize = fileSizeRaw is int ? fileSizeRaw : int.tryParse(fileSizeRaw?.toString() ?? '');
    final fileBytes = fileBytesRaw is int ? fileBytesRaw : int.tryParse(fileBytesRaw?.toString() ?? '');
    final hasBody = body.isNotEmpty;
    final hasOobUrl = oobUrl != null && oobUrl.isNotEmpty;
    final hasRawXml = rawXml != null && rawXml.isNotEmpty;
    final hasInvite = inviteRoomJid != null && inviteRoomJid.isNotEmpty;
    final hasFileTransfer = fileTransferId != null && fileTransferId.isNotEmpty;
    if (from.isEmpty ||
        to.isEmpty ||
        ts.isEmpty ||
        !hasRawXml ||
        (!hasBody && !hasOobUrl && !hasInvite && !hasFileTransfer)) {
      return null;
    }
    final timestamp = DateTime.tryParse(ts);
    if (timestamp == null) {
      return null;
    }
    final editedAt = editedAtRaw == null ? null : DateTime.tryParse(editedAtRaw);
    return ChatMessage(
      from: from,
      to: to,
      body: body,
      timestamp: timestamp,
      outgoing: outgoing,
      messageId: messageId,
      mamId: mamId,
      stanzaId: stanzaId,
      oobUrl: oobUrl,
      oobDescription: oobDescription,
      rawXml: rawXml,
      inviteRoomJid: inviteRoomJid,
      inviteReason: inviteReason,
      invitePassword: invitePassword,
      fileTransferId: fileTransferId,
      fileName: fileName,
      fileSize: fileSize,
      fileMime: fileMime,
      fileBytes: fileBytes,
      fileState: fileState,
      edited: edited,
      editedAt: editedAt,
      reactions: reactions,
      acked: acked,
      receiptReceived: receiptReceived,
      displayed: displayed,
    );
  }

  static Map<String, List<String>> _parseReactions(dynamic raw) {
    if (raw is! Map) {
      return const {};
    }
    final result = <String, List<String>>{};
    for (final entry in raw.entries) {
      final emoji = entry.key?.toString() ?? '';
      if (emoji.isEmpty) {
        continue;
      }
      final value = entry.value;
      if (value is List) {
        final senders = value.map((item) => item.toString()).where((item) => item.isNotEmpty).toList();
        if (senders.isNotEmpty) {
          result[emoji] = senders;
        }
      }
    }
    return result.isEmpty ? const {} : result;
  }
}
