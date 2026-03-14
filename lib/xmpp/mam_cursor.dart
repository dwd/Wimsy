import '../models/chat_message.dart';

String? oldestMamIdByTimestamp(List<ChatMessage> messages) {
  ChatMessage? oldest;
  for (final message in messages) {
    final mamId = message.mamId;
    if (mamId == null || mamId.isEmpty) {
      continue;
    }
    if (oldest == null || message.timestamp.isBefore(oldest.timestamp)) {
      oldest = message;
    }
  }
  return oldest?.mamId;
}

String? latestMamIdByTimestamp(List<ChatMessage> messages) {
  ChatMessage? latest;
  for (final message in messages) {
    final mamId = message.mamId;
    if (mamId == null || mamId.isEmpty) {
      continue;
    }
    if (latest == null || message.timestamp.isAfter(latest.timestamp)) {
      latest = message;
    }
  }
  return latest?.mamId;
}
