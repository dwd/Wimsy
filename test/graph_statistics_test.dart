import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/utils/graph_statistics.dart';

void main() {
  group('graphAverage', () {
    test('averages every sample in the displayed graph window', () {
      expect(graphAverage([0, 2, 0, 1]), 0.75);
    });

    test('returns null for an empty graph', () {
      expect(graphAverage(const []), isNull);
    });
  });

  group('formatGraphAverage', () {
    test('retains fractional sparse loss', () {
      expect(formatGraphAverage(1 / 60), '0.02');
    });

    test('does not add decimals to whole values', () {
      expect(formatGraphAverage(2), '2');
    });
  });

  group('packetLossPercentage', () {
    test('calculates loss from packet totals across the window', () {
      expect(packetLossPercentage([1, 0], [10, 90]), 1);
    });

    test('returns null when no packets were sent', () {
      expect(packetLossPercentage([0], [0]), isNull);
    });
  });
}
