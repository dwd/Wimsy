import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/xmpp/unread_message_finder.dart';

ChatMessage _message({
  required String id,
  required DateTime timestamp,
  bool outgoing = false,
  bool readByMe = false,
}) {
  return ChatMessage(
    from: outgoing ? 'me@example.com' : 'friend@example.com',
    to: outgoing ? 'friend@example.com' : 'me@example.com',
    body: id,
    timestamp: timestamp,
    outgoing: outgoing,
    messageId: id,
    readByMe: readByMe,
  );
}

void main() {
  final t1 = DateTime(2024, 1, 1, 10, 0);
  final t2 = DateTime(2024, 1, 1, 10, 1);
  final t3 = DateTime(2024, 1, 1, 10, 2);

  group('UnreadMessageFinder.firstUnread', () {
    test('returns null for an empty message list', () {
      expect(UnreadMessageFinder.firstUnread(const []), isNull);
    });

    test('returns null when every message has been read', () {
      final messages = [
        _message(id: '1', timestamp: t1, readByMe: true),
        _message(id: '2', timestamp: t2, readByMe: true),
      ];
      expect(UnreadMessageFinder.firstUnread(messages), isNull);
    });

    test('returns null when all messages are outgoing', () {
      final messages = [
        _message(id: '1', timestamp: t1, outgoing: true),
        _message(id: '2', timestamp: t2, outgoing: true),
      ];
      expect(UnreadMessageFinder.firstUnread(messages), isNull);
    });

    test(
      'returns the earliest unread incoming message, skipping read and '
      'outgoing ones',
      () {
        final messages = [
          _message(id: '1', timestamp: t1, readByMe: true),
          _message(id: '2', timestamp: t2, outgoing: true),
          _message(id: '3', timestamp: t3),
        ];
        final result = UnreadMessageFinder.firstUnread(messages);
        expect(result?.messageId, '3');
      },
    );

    test(
      'falls back to the read timestamp when readByMe is not set, treating '
      'messages at or before it as read',
      () {
        final messages = [
          _message(id: '1', timestamp: t1),
          _message(id: '2', timestamp: t2),
          _message(id: '3', timestamp: t3),
        ];
        final result = UnreadMessageFinder.firstUnread(
          messages,
          localReadAt: t2,
        );
        expect(result?.messageId, '3');
      },
    );

    test('uses the later of displayedAt and localReadAt as the cutoff', () {
      final messages = [
        _message(id: '1', timestamp: t1),
        _message(id: '2', timestamp: t2),
        _message(id: '3', timestamp: t3),
      ];
      final result = UnreadMessageFinder.firstUnread(
        messages,
        displayedAt: t1,
        localReadAt: t2,
      );
      expect(result?.messageId, '3');
    });

    test(
      'returns null when the fallback cutoff covers every message '
      'timestamp',
      () {
        final messages = [
          _message(id: '1', timestamp: t1),
          _message(id: '2', timestamp: t2),
        ];
        final result = UnreadMessageFinder.firstUnread(
          messages,
          localReadAt: t3,
        );
        expect(result, isNull);
      },
    );

    test(
      'skips a message marked readByMe even though its timestamp is after '
      'the fallback cutoff',
      () {
        final messages = [
          // Marked read explicitly even though its timestamp is after the
          // fallback cutoff - readByMe should still win.
          _message(id: '1', timestamp: t3, readByMe: true),
        ];
        final result = UnreadMessageFinder.firstUnread(
          messages,
          localReadAt: t1,
        );
        expect(result, isNull);
      },
    );
  });
}
