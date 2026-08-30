import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/quic_write_tracker.dart';

void main() {
  test('completes once only after the entire range is acknowledged', () {
    final tracker = QuicWriteTracker();
    final id = tracker.queue(generation: 3, messageId: 'message-1');
    tracker.assignRange(
      writeId: id,
      generation: 3,
      streamId: 7,
      startOffset: 10,
      endOffset: 30,
    );

    expect(
      tracker.updateStream(generation: 3, streamId: 7, acknowledgedOffset: 9),
      isEmpty,
    );
    expect(
      tracker
          .updateStream(generation: 3, streamId: 7, acknowledgedOffset: 18)
          .single
          .phase,
      QuicWritePhase.progress,
    );
    final delivered = tracker.updateStream(
      generation: 3,
      streamId: 7,
      acknowledgedOffset: 30,
    );
    expect(delivered.single.phase, QuicWritePhase.transportDelivered);
    expect(delivered.single.acknowledgedBytes, 20);
    expect(
      tracker.updateStream(generation: 3, streamId: 7, acknowledgedOffset: 30),
      isEmpty,
    );
  });

  test('coalesced writes complete according to their own ranges', () {
    final tracker = QuicWriteTracker();
    final first = tracker.queue(generation: 1, messageId: 'a');
    final second = tracker.queue(generation: 1, messageId: 'b');
    tracker.assignRange(
      writeId: first,
      generation: 1,
      streamId: 2,
      startOffset: 0,
      endOffset: 5,
    );
    tracker.assignRange(
      writeId: second,
      generation: 1,
      streamId: 2,
      startOffset: 5,
      endOffset: 12,
    );

    final events = tracker.updateStream(
      generation: 1,
      streamId: 2,
      acknowledgedOffset: 8,
    );
    expect(events.map((event) => event.phase), [
      QuicWritePhase.transportDelivered,
      QuicWritePhase.progress,
    ]);
    expect(tracker.outstandingBytes, 4);
  });

  test('late acknowledgement from an old generation is ignored', () {
    final tracker = QuicWriteTracker();
    final old = tracker.queue(generation: 4, messageId: 'same-id');
    tracker.assignRange(
      writeId: old,
      generation: 4,
      streamId: 1,
      startOffset: 0,
      endOffset: 4,
    );
    expect(
      tracker.failGeneration(4, 'connection replaced').single.phase,
      QuicWritePhase.failed,
    );
    expect(
      tracker.updateStream(generation: 4, streamId: 1, acknowledgedOffset: 4),
      isEmpty,
    );
  });

  test('terminal retention is bounded', () {
    final tracker = QuicWriteTracker(maxTerminalEntries: 1);
    for (var generation = 1; generation <= 2; generation++) {
      tracker.queue(generation: generation);
      tracker.failGeneration(generation, 'closed');
    }
    expect(tracker.outstandingWriteCount, 0);
  });

  test('stream failure terminates one write without affecting its peers', () {
    final tracker = QuicWriteTracker();
    final failed = tracker.queue(generation: 1, messageId: 'failed');
    tracker.queue(generation: 1, messageId: 'still-active');

    final event = tracker.failWrite(
      writeId: failed,
      generation: 1,
      reason: 'STOP_SENDING',
    );

    expect(event?.phase, QuicWritePhase.failed);
    expect(event?.failure, 'STOP_SENDING');
    expect(tracker.outstandingWriteCount, 1);
  });
}
