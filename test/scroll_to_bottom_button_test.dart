import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/main.dart';

void main() {
  group('shouldShowScrollToBottomButton', () {
    test('is false when scrolled all the way to the bottom', () {
      expect(
        shouldShowScrollToBottomButton(pixels: 500, maxScrollExtent: 500),
        isFalse,
      );
    });

    test('is false for small offsets from the bottom', () {
      expect(
        shouldShowScrollToBottomButton(pixels: 480, maxScrollExtent: 500),
        isFalse,
      );
    });

    test('is false exactly at the threshold boundary', () {
      expect(
        shouldShowScrollToBottomButton(pixels: 300, maxScrollExtent: 500),
        isFalse,
      );
    });

    test('is true once scrolled beyond the threshold', () {
      expect(
        shouldShowScrollToBottomButton(pixels: 299, maxScrollExtent: 500),
        isTrue,
      );
    });

    test('is true when scrolled far up the message list', () {
      expect(
        shouldShowScrollToBottomButton(pixels: 0, maxScrollExtent: 5000),
        isTrue,
      );
    });

    test('is false when there is nothing to scroll', () {
      expect(
        shouldShowScrollToBottomButton(pixels: 0, maxScrollExtent: 0),
        isFalse,
      );
    });
  });
}
