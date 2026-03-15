import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/mam_cursor_store.dart';

class _FakeClock {
  _FakeClock(this.now);
  DateTime now;

  void advance(Duration duration) {
    now = now.add(duration);
  }
}

class _FakeScheduledTask implements MamScheduledTask {
  _FakeScheduledTask(this._onCancel);

  final void Function() _onCancel;
  bool cancelled = false;

  @override
  void cancel() {
    cancelled = true;
    _onCancel();
  }
}

class _FakeScheduler {
  final List<void Function()> _callbacks = [];

  MamScheduledTask schedule(Duration _, void Function() callback) {
    _callbacks.add(callback);
    return _FakeScheduledTask(() {
      _callbacks.remove(callback);
    });
  }

  void fireAll() {
    final callbacks = List<void Function()>.from(_callbacks);
    _callbacks.clear();
    for (final callback in callbacks) {
      callback();
    }
  }
}

void main() {
  test('backfill/page/catch-up throttles respect configured windows', () {
    final clock = _FakeClock(DateTime.utc(2026, 1, 1, 0, 0, 0));
    final scheduler = _FakeScheduler();
    final store = MamCursorStore(
      now: () => clock.now,
      schedule: scheduler.schedule,
    );

    expect(store.shouldThrottleBackfill('chat'), isFalse);
    store.markBackfill('chat');
    expect(store.shouldThrottleBackfill('chat'), isTrue);
    clock.advance(const Duration(seconds: 31));
    expect(store.shouldThrottleBackfill('chat'), isFalse);

    expect(store.shouldThrottlePageRequest('chat'), isFalse);
    store.markPageRequest('chat');
    expect(store.shouldThrottlePageRequest('chat'), isTrue);
    clock.advance(const Duration(seconds: 6));
    expect(store.shouldThrottlePageRequest('chat'), isFalse);

    expect(store.shouldThrottleCatchUp('scope'), isFalse);
    store.markCatchUp('scope');
    expect(store.shouldThrottleCatchUp('scope'), isTrue);
    clock.advance(const Duration(seconds: 6));
    expect(store.shouldThrottleCatchUp('scope'), isFalse);
  });

  test(
    'prepend offset increments and resets when scheduled callback fires',
    () {
      final scheduler = _FakeScheduler();
      final store = MamCursorStore(
        now: () => DateTime.utc(2026, 1, 1),
        schedule: scheduler.schedule,
      );

      store.startPrepend('chat');
      expect(store.prependOffsetFor('chat'), 0);
      store.incrementPrependOffset('chat');
      expect(store.prependOffsetFor('chat'), 1);

      scheduler.fireAll();
      expect(store.prependOffsetFor('chat'), isNull);
    },
  );

  test('catch-up pending markers transition completion state', () {
    final store = MamCursorStore();
    expect(store.isCatchUpComplete('scope'), isTrue);
    expect(store.markCatchUpPending('scope'), isTrue);
    expect(store.isCatchUpComplete('scope'), isFalse);
    expect(store.markCatchUpPending('scope'), isFalse);
    expect(store.clearCatchUpPending('scope'), isTrue);
    expect(store.isCatchUpComplete('scope'), isTrue);
    expect(store.clearCatchUpPending('scope'), isFalse);
  });
}
