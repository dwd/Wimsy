import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/xmpp/mam_cursor.dart';

ChatMessage _message({required DateTime timestamp, String? mamId}) {
  return ChatMessage(
    from: 'alice@example.com',
    to: 'bob@example.com',
    body: 'hello',
    timestamp: timestamp,
    outgoing: false,
    mamId: mamId,
    rawXml: '<message/>',
  );
}

void main() {
  test('oldestMamIdByTimestamp ignores entries without mamId', () {
    final messages = <ChatMessage>[
      _message(timestamp: DateTime.utc(2026, 1, 2), mamId: ''),
      _message(timestamp: DateTime.utc(2026, 1, 1), mamId: 'm-1'),
      _message(timestamp: DateTime.utc(2026, 1, 3), mamId: 'm-3'),
    ];

    expect(oldestMamIdByTimestamp(messages), 'm-1');
  });

  test('latestMamIdByTimestamp picks latest by timestamp', () {
    final messages = <ChatMessage>[
      _message(timestamp: DateTime.utc(2026, 1, 1), mamId: 'm-1'),
      _message(timestamp: DateTime.utc(2026, 1, 3), mamId: 'm-3'),
      _message(timestamp: DateTime.utc(2026, 1, 2), mamId: 'm-2'),
    ];

    expect(latestMamIdByTimestamp(messages), 'm-3');
  });

  test('cursor selection follows timestamp even if ids are non-monotonic', () {
    final messages = <ChatMessage>[
      _message(timestamp: DateTime.utc(2026, 1, 1), mamId: '200'),
      _message(timestamp: DateTime.utc(2026, 1, 2), mamId: '100'),
    ];

    expect(oldestMamIdByTimestamp(messages), '200');
    expect(latestMamIdByTimestamp(messages), '100');
  });
}
