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
    this.rawXml,
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
  final String? rawXml;
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
      'rawXml': rawXml,
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
    final rawXml = map['rawXml']?.toString();
    final acked = map['acked'] == true;
    final receiptReceived = map['receiptReceived'] == true;
    final displayed = map['displayed'] == true;
    final hasBody = body.isNotEmpty;
    final hasOobUrl = oobUrl != null && oobUrl.isNotEmpty;
    final hasRawXml = rawXml != null && rawXml.isNotEmpty;
    if (from.isEmpty || to.isEmpty || ts.isEmpty || !hasRawXml || (!hasBody && !hasOobUrl)) {
      return null;
    }
    final timestamp = DateTime.tryParse(ts);
    if (timestamp == null) {
      return null;
    }
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
      rawXml: rawXml,
      acked: acked,
      receiptReceived: receiptReceived,
      displayed: displayed,
    );
  }
}
