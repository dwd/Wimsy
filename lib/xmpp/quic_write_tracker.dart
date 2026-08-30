import 'dart:collection';

enum QuicWritePhase {
  queued,
  rangeAssigned,
  progress,
  transportDelivered,
  failed,
}

class QuicWriteEvent {
  const QuicWriteEvent({
    required this.writeId,
    required this.generation,
    required this.phase,
    required this.messageId,
    this.streamId,
    this.startOffset,
    this.endOffset,
    this.acknowledgedBytes = 0,
    this.failure,
  });

  final int writeId;
  final int generation;
  final QuicWritePhase phase;
  final String? messageId;
  final int? streamId;
  final int? startOffset;
  final int? endOffset;
  final int acknowledgedBytes;
  final String? failure;
}

/// Tracks logical writes by their immutable QUIC stream byte ranges.
///
/// A write becomes transport-delivered only when the stream's contiguous
/// acknowledgement watermark reaches its end offset. Terminal entries are
/// retained in a bounded queue so late UI reconciliation remains possible.
class QuicWriteTracker {
  QuicWriteTracker({this.maxTerminalEntries = 256})
    : assert(maxTerminalEntries >= 0);

  final int maxTerminalEntries;
  final Map<int, _TrackedWrite> _writes = {};
  final Queue<int> _terminalOrder = Queue<int>();
  int _nextWriteId = 1;

  int queue({required int generation, String? messageId}) {
    final id = _nextWriteId++;
    _writes[id] = _TrackedWrite(id, generation, messageId);
    return id;
  }

  QuicWriteEvent eventForQueued(int writeId) => _writes[writeId]!.event();

  QuicWriteEvent assignRange({
    required int writeId,
    required int generation,
    required int streamId,
    required int startOffset,
    required int endOffset,
  }) {
    final write = _active(writeId, generation);
    if (endOffset < startOffset) {
      throw ArgumentError('endOffset must not precede startOffset');
    }
    write
      ..streamId = streamId
      ..startOffset = startOffset
      ..endOffset = endOffset
      ..phase = QuicWritePhase.rangeAssigned;
    return write.event();
  }

  List<QuicWriteEvent> updateStream({
    required int generation,
    required int streamId,
    required int acknowledgedOffset,
  }) {
    final events = <QuicWriteEvent>[];
    for (final write in _writes.values.toList(growable: false)) {
      if (write.terminal ||
          write.generation != generation ||
          write.streamId != streamId ||
          write.endOffset == null) {
        continue;
      }
      final acknowledged = (acknowledgedOffset - write.startOffset!).clamp(
        0,
        write.endOffset! - write.startOffset!,
      );
      if (acknowledged == write.acknowledgedBytes) continue;
      write.acknowledgedBytes = acknowledged;
      if (acknowledgedOffset >= write.endOffset!) {
        write.phase = QuicWritePhase.transportDelivered;
        _retainTerminal(write.id);
      } else {
        write.phase = QuicWritePhase.progress;
      }
      events.add(write.event());
    }
    return events;
  }

  List<QuicWriteEvent> failGeneration(int generation, String reason) {
    final events = <QuicWriteEvent>[];
    for (final write in _writes.values.toList(growable: false)) {
      if (write.generation != generation || write.terminal) continue;
      write
        ..phase = QuicWritePhase.failed
        ..failure = reason;
      _retainTerminal(write.id);
      events.add(write.event());
    }
    return events;
  }

  QuicWriteEvent? failWrite({
    required int writeId,
    required int generation,
    required String reason,
  }) {
    final write = _writes[writeId];
    if (write == null || write.generation != generation || write.terminal) {
      return null;
    }
    write
      ..phase = QuicWritePhase.failed
      ..failure = reason;
    _retainTerminal(write.id);
    return write.event();
  }

  int get outstandingWriteCount =>
      _writes.values.where((write) => !write.terminal).length;

  int get outstandingBytes => _writes.values
      .where((write) => !write.terminal && write.endOffset != null)
      .fold(
        0,
        (sum, write) =>
            sum +
            write.endOffset! -
            write.startOffset! -
            write.acknowledgedBytes,
      );

  _TrackedWrite _active(int id, int generation) {
    final write = _writes[id];
    if (write == null || write.generation != generation || write.terminal) {
      throw StateError('Write $id is not active in generation $generation');
    }
    return write;
  }

  void _retainTerminal(int id) {
    _terminalOrder.addLast(id);
    while (_terminalOrder.length > maxTerminalEntries) {
      _writes.remove(_terminalOrder.removeFirst());
    }
  }
}

class _TrackedWrite {
  _TrackedWrite(this.id, this.generation, this.messageId);

  final int id;
  final int generation;
  final String? messageId;
  QuicWritePhase phase = QuicWritePhase.queued;
  int? streamId;
  int? startOffset;
  int? endOffset;
  int acknowledgedBytes = 0;
  String? failure;

  bool get terminal =>
      phase == QuicWritePhase.transportDelivered ||
      phase == QuicWritePhase.failed;

  QuicWriteEvent event() => QuicWriteEvent(
    writeId: id,
    generation: generation,
    phase: phase,
    messageId: messageId,
    streamId: streamId,
    startOffset: startOffset,
    endOffset: endOffset,
    acknowledgedBytes: acknowledgedBytes,
    failure: failure,
  );
}
