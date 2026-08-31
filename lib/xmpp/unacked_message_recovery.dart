import '../models/chat_message.dart';

/// Tracks messages whose delivery was uncertain when an XMPP stream was lost.
class UnackedMessageRecovery {
  final Set<({String jid, String messageId, bool isRoom})> _pending = {};

  void capture(
    Map<String, List<ChatMessage>> directMessages,
    Map<String, List<ChatMessage>> roomMessages,
  ) {
    void add(Map<String, List<ChatMessage>> chats, {required bool isRoom}) {
      for (final entry in chats.entries) {
        for (final message in entry.value) {
          final id = message.messageId;
          if (message.outgoing &&
              !message.acked &&
              !message.receiptReceived &&
              (message.mamId == null || message.mamId!.isEmpty) &&
              id != null &&
              id.isNotEmpty) {
            _pending.add((jid: entry.key, messageId: id, isRoom: isRoom));
          }
        }
      }
    }

    add(directMessages, isRoom: false);
    add(roomMessages, isRoom: true);
  }

  /// Removes candidates now proven delivered and returns the rest for resend.
  /// Resends are moved to the bottom with their new effective send time.
  List<({String jid, ChatMessage message, bool isRoom})> reconcile({
    required Map<String, List<ChatMessage>> directMessages,
    required Map<String, List<ChatMessage>> roomMessages,
    required DateTime Function() now,
    String? onlyJid,
    bool? onlyRooms,
  }) {
    final resends = <({String jid, ChatMessage message, bool isRoom})>[];
    final candidates = _pending
        .where((candidate) {
          return (onlyJid == null || candidate.jid == onlyJid) &&
              (onlyRooms == null || candidate.isRoom == onlyRooms);
        })
        .toList(growable: false);

    for (final candidate in candidates) {
      final chats = candidate.isRoom ? roomMessages : directMessages;
      final list = chats[candidate.jid];
      final index =
          list?.indexWhere(
            (message) => message.messageId == candidate.messageId,
          ) ??
          -1;
      _pending.remove(candidate);
      if (list == null || index == -1) continue;
      final message = list[index];
      if (message.acked ||
          message.receiptReceived ||
          (message.mamId != null && message.mamId!.isNotEmpty)) {
        continue;
      }
      final moved = message.copyWith(timestamp: now());
      list.removeAt(index);
      list.add(moved);
      resends.add((
        jid: candidate.jid,
        message: moved,
        isRoom: candidate.isRoom,
      ));
    }
    return resends;
  }
}
