import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/main.dart';
import 'package:wimsy/models/chat_message.dart';

ChatMessage _message(String id) {
  return ChatMessage(
    from: 'bob@example.com',
    to: 'alice@example.com',
    body: id,
    timestamp: DateTime.utc(2024),
    outgoing: false,
    messageId: id,
  );
}

void main() {
  group('messageWindow', () {
    test('returns the whole list when it fits within the window', () {
      final messages = List.generate(5, (i) => _message('m$i'));

      final result = messageWindow(messages, 10);

      expect(result, same(messages));
    });

    test('returns the whole list when it exactly fills the window', () {
      final messages = List.generate(10, (i) => _message('m$i'));

      final result = messageWindow(messages, 10);

      expect(result, same(messages));
    });

    test('keeps only the most recent messages when over the window size', () {
      final messages = List.generate(100, (i) => _message('m$i'));

      final result = messageWindow(messages, 10);

      expect(result.length, 10);
      expect(result.first.messageId, 'm90');
      expect(result.last.messageId, 'm99');
    });

    test('returns an empty list unchanged', () {
      final result = messageWindow(const [], 10);

      expect(result, isEmpty);
    });

    test('returns the whole list for a non-positive window size', () {
      final messages = List.generate(5, (i) => _message('m$i'));

      final result = messageWindow(messages, 0);

      expect(result, same(messages));
    });
  });

  group('scrollOffsetAfterPrepend', () {
    test('shifts the offset by however much content was added above it', () {
      final offset = scrollOffsetAfterPrepend(
        previousPixels: 0,
        previousMaxScrollExtent: 1000,
        newMaxScrollExtent: 1300,
      );

      expect(offset, 300);
    });

    test('preserves a non-zero offset while shifting it', () {
      final offset = scrollOffsetAfterPrepend(
        previousPixels: 120,
        previousMaxScrollExtent: 1000,
        newMaxScrollExtent: 1250,
      );

      expect(offset, 370);
    });

    test('leaves the offset unchanged when nothing was added', () {
      final offset = scrollOffsetAfterPrepend(
        previousPixels: 50,
        previousMaxScrollExtent: 1000,
        newMaxScrollExtent: 1000,
      );

      expect(offset, 50);
    });

    test('leaves the offset unchanged if the extent shrank', () {
      final offset = scrollOffsetAfterPrepend(
        previousPixels: 50,
        previousMaxScrollExtent: 1000,
        newMaxScrollExtent: 900,
      );

      expect(offset, 50);
    });
  });

  group('scrollOffsetForPinnedLowerEdge', () {
    test('keeps the same distance from the bottom when viewport shrinks', () {
      final offset = scrollOffsetForPinnedLowerEdge(
        previousDistanceFromBottom: 180,
        newMinScrollExtent: 0,
        newMaxScrollExtent: 1400,
      );

      expect(offset, 1220);
    });

    test('keeps the same distance from the bottom when viewport expands', () {
      final offset = scrollOffsetForPinnedLowerEdge(
        previousDistanceFromBottom: 180,
        newMinScrollExtent: 0,
        newMaxScrollExtent: 900,
      );

      expect(offset, 720);
    });

    test('keeps a view at the latest message pinned to the bottom', () {
      final offset = scrollOffsetForPinnedLowerEdge(
        previousDistanceFromBottom: 0,
        newMinScrollExtent: 0,
        newMaxScrollExtent: 1400,
      );

      expect(offset, 1400);
    });

    test('clamps when the restored viewport has too little history', () {
      final offset = scrollOffsetForPinnedLowerEdge(
        previousDistanceFromBottom: 1200,
        newMinScrollExtent: 0,
        newMaxScrollExtent: 900,
      );

      expect(offset, 0);
    });
  });
}
