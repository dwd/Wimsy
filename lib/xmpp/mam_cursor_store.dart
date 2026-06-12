import 'dart:async';

typedef MamNow = DateTime Function();
typedef MamSchedule =
    MamScheduledTask Function(Duration delay, void Function() callback);

abstract class MamScheduledTask {
  void cancel();
}

class MamCursorStore {
  MamCursorStore({MamNow? now, MamSchedule? schedule})
    : _now = now ?? DateTime.now,
      _schedule = schedule ?? _defaultSchedule;

  final MamNow _now;
  final MamSchedule _schedule;

  final Map<String, DateTime> _backfillAt = {};
  final Map<String, DateTime> _pageRequestAt = {};
  final Map<String, DateTime> _catchUpAt = {};
  final Set<String> _catchUpPending = {};
  final Map<String, int> _prependOffset = {};
  final Map<String, MamScheduledTask> _prependReset = {};
  // JIDs for which MAM returned complete=true on a backwards page request,
  // meaning there are no older messages in the archive.
  final Set<String> _archiveExhausted = {};

  /// Returns true if a previous backwards MAM page for [key] returned
  /// complete=true, meaning there are no older messages to fetch.
  bool isArchiveExhausted(String key) => _archiveExhausted.contains(key);

  /// Records that the MAM archive for [key] is exhausted (complete=true).
  void markArchiveExhausted(String key) {
    _archiveExhausted.add(key);
  }

  /// Clears the archive-exhausted flag for [key], e.g. when new messages
  /// arrive that extend the archive or when the cache is cleared.
  void clearArchiveExhausted(String key) {
    _archiveExhausted.remove(key);
  }

  bool shouldThrottleBackfill(
    String key, {
    Duration window = const Duration(seconds: 30),
  }) {
    final last = _backfillAt[key];
    if (last == null) {
      return false;
    }
    return _now().difference(last).inMilliseconds < window.inMilliseconds;
  }

  void markBackfill(String key) {
    _backfillAt[key] = _now();
  }

  bool shouldThrottlePageRequest(
    String key, {
    Duration window = const Duration(seconds: 5),
  }) {
    final last = _pageRequestAt[key];
    if (last == null) {
      return false;
    }
    return _now().difference(last).inMilliseconds < window.inMilliseconds;
  }

  void markPageRequest(String key) {
    _pageRequestAt[key] = _now();
  }

  bool shouldThrottleCatchUp(
    String key, {
    Duration window = const Duration(seconds: 5),
  }) {
    final last = _catchUpAt[key];
    if (last == null) {
      return false;
    }
    return _now().difference(last).inMilliseconds < window.inMilliseconds;
  }

  void markCatchUp(String key) {
    _catchUpAt[key] = _now();
  }

  bool isCatchUpComplete(String scopeKey) {
    return !_catchUpPending.contains(scopeKey);
  }

  bool markCatchUpPending(String scopeKey) {
    return _catchUpPending.add(scopeKey);
  }

  bool clearCatchUpPending(String scopeKey) {
    return _catchUpPending.remove(scopeKey);
  }

  int? prependOffsetFor(String key) {
    return _prependOffset[key];
  }

  void startPrepend(
    String key, {
    Duration window = const Duration(seconds: 2),
  }) {
    _prependOffset[key] = 0;
    _prependReset[key]?.cancel();
    _prependReset[key] = _schedule(window, () {
      _prependOffset.remove(key);
      _prependReset.remove(key);
    });
  }

  void incrementPrependOffset(String key) {
    final offset = _prependOffset[key];
    if (offset == null) {
      return;
    }
    _prependOffset[key] = offset + 1;
  }

  void clear() {
    _backfillAt.clear();
    _pageRequestAt.clear();
    _catchUpAt.clear();
    _catchUpPending.clear();
    _prependOffset.clear();
    for (final task in _prependReset.values) {
      task.cancel();
    }
    _prependReset.clear();
    _archiveExhausted.clear();
  }
}

MamScheduledTask _defaultSchedule(Duration delay, void Function() callback) {
  return _TimerScheduledTask(Timer(delay, callback));
}

class _TimerScheduledTask implements MamScheduledTask {
  _TimerScheduledTask(this._timer);

  final Timer _timer;

  @override
  void cancel() {
    _timer.cancel();
  }
}
