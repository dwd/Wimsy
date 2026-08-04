import '../models/chat_message.dart';

/// Pure helper used to determine which message should be scrolled into
/// view when a chat is opened: the earliest incoming message that hasn't
/// been read by the local user yet.
class UnreadMessageFinder {
  /// Returns the earliest incoming message in [messages] that hasn't been
  /// read by the local user yet, or `null` if every message is already
  /// read (or there are no incoming messages at all).
  ///
  /// [messages] must be a snapshot taken *before* the chat is marked as
  /// read, since marking a chat as read flips every message's [readByMe]
  /// flag to `true`, which would make every message look "read" here.
  ///
  /// [displayedAt] and [localReadAt] are used as a fallback for messages
  /// that were loaded from the archive before the per-message [readByMe]
  /// flag existed: such a message is treated as read if its timestamp is
  /// not after the later of the two cutoffs.
  static ChatMessage? firstUnread(
    List<ChatMessage> messages, {
    DateTime? displayedAt,
    DateTime? localReadAt,
  }) {
    if (messages.isEmpty) {
      return null;
    }
    final lastReadAt = displayedAt == null
        ? localReadAt
        : (localReadAt == null || displayedAt.isAfter(localReadAt)
              ? displayedAt
              : localReadAt);
    for (final message in messages) {
      if (message.outgoing || message.readByMe) {
        continue;
      }
      // Fall back to timestamp comparison for messages loaded before
      // readByMe was introduced.
      if (lastReadAt != null && !message.timestamp.isAfter(lastReadAt)) {
        continue;
      }
      return message;
    }
    return null;
  }
}
