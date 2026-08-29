/// Returns the arithmetic mean of the samples displayed by a graph.
///
/// An empty graph has no meaningful average, so callers receive `null` rather
/// than a value that could be mistaken for a measured zero.
double? graphAverage(Iterable<int> samples) {
  var count = 0;
  var total = 0;
  for (final sample in samples) {
    total += sample;
    count++;
  }
  return count == 0 ? null : total / count;
}

/// Formats an average without hiding sparse, non-zero samples through rounding.
String formatGraphAverage(double value) {
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toStringAsFixed(2);
}

/// Returns outbound packet loss as a percentage for matching sample windows.
double? packetLossPercentage(
  Iterable<int> lostPacketSamples,
  Iterable<int> sentPacketSamples,
) {
  final lostPackets = lostPacketSamples.fold<int>(
    0,
    (sum, value) => sum + value,
  );
  final sentPackets = sentPacketSamples.fold<int>(
    0,
    (sum, value) => sum + value,
  );
  if (sentPackets == 0) return null;
  return lostPackets / sentPackets * 100;
}
