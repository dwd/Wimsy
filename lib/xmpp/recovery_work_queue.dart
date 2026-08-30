import 'dart:async';
import 'dart:collection';

enum RecoveryPriority { session, messages, bulk }

/// Bounded, pausable work queue for post-Ready recovery traffic.
class RecoveryWorkQueue {
  RecoveryWorkQueue({this.maxConcurrent = 2});

  final int maxConcurrent;
  final SplayTreeMap<int, Queue<Future<void> Function()>> _pending =
      SplayTreeMap<int, Queue<Future<void> Function()>>();
  int _running = 0;
  bool _paused = false;

  bool get isPaused => _paused;
  int get pendingCount =>
      _pending.values.fold(0, (count, queue) => count + queue.length);
  int get runningCount => _running;

  void add(RecoveryPriority priority, Future<void> Function() task) {
    _pending
        .putIfAbsent(priority.index, Queue<Future<void> Function()>.new)
        .add(task);
    _drain();
  }

  void pause() => _paused = true;

  void resume() {
    _paused = false;
    _drain();
  }

  /// Drops pending work from the prior connection. Running tasks are allowed
  /// to unwind before newly queued work consumes their concurrency slots.
  void reset({bool paused = false}) {
    _pending.clear();
    _paused = paused;
  }

  void _drain() {
    if (_paused || maxConcurrent < 1) return;
    while (_running < maxConcurrent) {
      final entry = _pending.entries
          .where((candidate) => candidate.value.isNotEmpty)
          .firstOrNull;
      if (entry == null) return;
      final task = entry.value.removeFirst();
      if (entry.value.isEmpty) _pending.remove(entry.key);
      _running++;
      Future<void>.sync(task).whenComplete(() {
        _running--;
        _drain();
      });
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
