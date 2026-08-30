import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/recovery_work_queue.dart';

void main() {
  test('bounds concurrency and starts queued work by priority', () async {
    final queue = RecoveryWorkQueue(maxConcurrent: 1)..pause();
    final order = <String>[];
    queue.add(RecoveryPriority.bulk, () async => order.add('bulk'));
    queue.add(RecoveryPriority.messages, () async => order.add('messages'));
    queue.add(RecoveryPriority.session, () async => order.add('session'));

    queue.resume();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(order, ['session', 'messages', 'bulk']);
  });

  test('pause prevents pending work and resume continues it', () async {
    final first = Completer<void>();
    final queue = RecoveryWorkQueue(maxConcurrent: 1);
    var secondRan = false;
    queue.add(RecoveryPriority.session, () => first.future);
    queue.add(RecoveryPriority.bulk, () async => secondRan = true);
    queue.pause();
    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(secondRan, isFalse);

    queue.resume();
    await Future<void>.delayed(Duration.zero);
    expect(secondRan, isTrue);
  });

  test('reset drops pending work from the old generation', () async {
    final first = Completer<void>();
    final queue = RecoveryWorkQueue(maxConcurrent: 1);
    var staleRan = false;
    queue.add(RecoveryPriority.session, () => first.future);
    queue.add(RecoveryPriority.bulk, () async => staleRan = true);

    queue.reset();
    first.complete();
    await Future<void>.delayed(Duration.zero);

    expect(staleRan, isFalse);
    expect(queue.pendingCount, 0);
  });
}
