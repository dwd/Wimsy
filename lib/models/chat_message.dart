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
    this.replyToId,
    this.replyToJid,
    this.replyFallback,
    this.acked = false,
    this.receiptReceived = false,
    this.displayed = false,
    this.readByMe = false,
    this.markerSent = false,
    this.receiptSent = false,
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
  final String? replyToId;
  final String? replyToJid;
  final String? replyFallback;
  final bool acked;
  final bool receiptReceived;
  final bool displayed;
  // Whether the local user has read this incoming message.
  final bool readByMe;
  // Whether a XEP-0333 displayed marker has been sent for this message.
  final bool markerSent;
  // Whether a XEP-0184 delivery receipt has been sent for this message.
  final bool receiptSent;

  // Sentinel object used to distinguish "caller passed null explicitly" from
  // "caller did not pass this parameter" in copyWith.
  static const Object _absent = Object();

  ChatMessage copyWith({
    String? from,
    String? to,
    String? body,
    DateTime? timestamp,
    bool? outgoing,
    Object? messageId = _absent,
    Object? mamId = _absent,
    Object? stanzaId = _absent,
    Object? oobUrl = _absent,
    Object? oobDescription = _absent,
    Object? rawXml = _absent,
    Object? inviteRoomJid = _absent,
    Object? inviteReason = _absent,
    Object? invitePassword = _absent,
    Object? fileTransferId = _absent,
    Object? fileName = _absent,
    Object? fileSize = _absent,
    Object? fileMime = _absent,
    Object? fileBytes = _absent,
    Object? fileState = _absent,
    bool? edited,
    Object? editedAt = _absent,
    Object? reactions = _absent,
    Object? replyToId = _absent,
    Object? replyToJid = _absent,
    Object? replyFallback = _absent,
    bool? acked,
    bool? receiptReceived,
    bool? displayed,
    bool? readByMe,
    bool? markerSent,
    bool? receiptSent,
  }) {
    return ChatMessage(
      from: from ?? this.from,
      to: to ?? this.to,
      body: body ?? this.body,
      timestamp: timestamp ?? this.timestamp,
      outgoing: outgoing ?? this.outgoing,
      messageId: identical(messageId, _absent)
          ? this.messageId
          : messageId as String?,
      mamId: identical(mamId, _absent) ? this.mamId : mamId as String?,
      stanzaId: identical(stanzaId, _absent)
          ? this.stanzaId
          : stanzaId as String?,
      oobUrl: identical(oobUrl, _absent) ? this.oobUrl : oobUrl as String?,
      oobDescription: identical(oobDescription, _absent)
          ? this.oobDescription
          : oobDescription as String?,
      rawXml: identical(rawXml, _absent) ? this.rawXml : rawXml as String?,
      inviteRoomJid: identical(inviteRoomJid, _absent)
          ? this.inviteRoomJid
          : inviteRoomJid as String?,
      inviteReason: identical(inviteReason, _absent)
          ? this.inviteReason
          : inviteReason as String?,
      invitePassword: identical(invitePassword, _absent)
          ? this.invitePassword
          : invitePassword as String?,
      fileTransferId: identical(fileTransferId, _absent)
          ? this.fileTransferId
          : fileTransferId as String?,
      fileName: identical(fileName, _absent)
          ? this.fileName
          : fileName as String?,
      fileSize: identical(fileSize, _absent)
          ? this.fileSize
          : fileSize as int?,
      fileMime: identical(fileMime, _absent)
          ? this.fileMime
          : fileMime as String?,
      fileBytes: identical(fileBytes, _absent)
          ? this.fileBytes
          : fileBytes as int?,
      fileState: identical(fileState, _absent)
          ? this.fileState
          : fileState as String?,
      edited: edited ?? this.edited,
      editedAt: identical(editedAt, _absent)
          ? this.editedAt
          : editedAt as DateTime?,
      reactions: identical(reactions, _absent)
          ? this.reactions
          : reactions as Map<String, List<String>>?,
      replyToId: identical(replyToId, _absent)
          ? this.replyToId
          : replyToId as String?,
      replyToJid: identical(replyToJid, _absent)
          ? this.replyToJid
          : replyToJid as String?,
      replyFallback: identical(replyFallback, _absent)
          ? this.replyFallback
          : replyFallback as String?,
      acked: acked ?? this.acked,
      receiptReceived: receiptReceived ?? this.receiptReceived,
      displayed: displayed ?? this.displayed,
      readByMe: readByMe ?? this.readByMe,
      markerSent: markerSent ?? this.markerSent,
      receiptSent: receiptSent ?? this.receiptSent,
    );
  }

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
      'replyToId': replyToId,
      'replyToJid': replyToJid,
      'replyFallback': replyFallback,
      'acked': acked,
      'receiptReceived': receiptReceived,
      'displayed': displayed,
      'readByMe': readByMe,
      'markerSent': markerSent,
      'receiptSent': receiptSent,
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
    final replyToId = map['replyToId']?.toString();
    final replyToJid = map['replyToJid']?.toString();
    final replyFallback = map['replyFallback']?.toString();
    final acked = map['acked'] == true;
    // Older cache records predate persisted tick state. An outgoing message
    // restored without that state is necessarily historical, so treat it as
    // delivered instead of regressing it to the pending/no-tick state.
    final receiptReceived = map.containsKey('receiptReceived')
        ? map['receiptReceived'] == true
        : outgoing;
    final displayed = map['displayed'] == true;
    final readByMe = map['readByMe'] == true;
    final markerSent = map['markerSent'] == true;
    final receiptSent = map['receiptSent'] == true;
    final fileSize = fileSizeRaw is int
        ? fileSizeRaw
        : int.tryParse(fileSizeRaw?.toString() ?? '');
    final fileBytes = fileBytesRaw is int
        ? fileBytesRaw
        : int.tryParse(fileBytesRaw?.toString() ?? '');
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
    final editedAt = editedAtRaw == null
        ? null
        : DateTime.tryParse(editedAtRaw);
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
      replyToId: replyToId,
      replyToJid: replyToJid,
      replyFallback: replyFallback,
      acked: acked,
      receiptReceived: receiptReceived,
      displayed: displayed,
      readByMe: readByMe,
      markerSent: markerSent,
      receiptSent: receiptSent,
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
        final senders = value
            .map((item) => item.toString())
            .where((item) => item.isNotEmpty)
            .toList();
        if (senders.isNotEmpty) {
          result[emoji] = senders;
        }
      }
    }
    return result.isEmpty ? const {} : result;
  }
}
