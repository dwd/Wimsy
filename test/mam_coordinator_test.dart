import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/mam_coordinator.dart';
import 'package:wimsy/xmpp/mam_cursor_store.dart';
import 'package:wimsy/xmpp/mam_query_planner.dart';

class _RecordedQuery {
  const _RecordedQuery({
    required this.isRoom,
    required this.jid,
    required this.plan,
  });

  final bool isRoom;
  final String jid;
  final MamQueryPlan plan;
}

class _FakeAdapter implements MamQueryAdapter {
  final List<_RecordedQuery> queries = [];

  @override
  void queryDm(String bareJid, MamQueryPlan plan) {
    queries.add(_RecordedQuery(isRoom: false, jid: bareJid, plan: plan));
  }

  @override
  void queryRoom(String roomJid, MamQueryPlan plan) {
    queries.add(_RecordedQuery(isRoom: true, jid: roomJid, plan: plan));
  }
}

class _FakeScheduler {
  final List<void Function()> callbacks = [];

  MamScheduledTask schedule(Duration _, void Function() callback) {
    callbacks.add(callback);
    return _NoopTask();
  }
}

class _NoopTask implements MamScheduledTask {
  @override
  void cancel() {}
}

void main() {
  test('older DM request uses planner and starts prepend window', () {
    final scheduler = _FakeScheduler();
    final store = MamCursorStore(
      now: () => DateTime.utc(2026, 1, 1),
      schedule: scheduler.schedule,
    );
    final adapter = _FakeAdapter();
    final coordinator = MamCoordinator(cursorStore: store, adapter: adapter);
    var fallbackCalled = false;

    coordinator.requestOlder(
      bareJid: 'alice@example.com',
      isRoom: false,
      seeded: true,
      oldestMamId: 'm-1',
      onDmInitialFallback: () => fallbackCalled = true,
    );

    expect(fallbackCalled, isFalse);
    expect(adapter.queries, hasLength(1));
    expect(adapter.queries.single.isRoom, isFalse);
    expect(adapter.queries.single.plan.beforeId, 'm-1');
    expect(store.prependOffsetFor('alice@example.com'), 0);
  });

  test('older room request falls back to initial when no oldest anchor', () {
    final store = MamCursorStore(
      now: () => DateTime.utc(2026, 1, 1),
      schedule: _FakeScheduler().schedule,
    );
    final adapter = _FakeAdapter();
    final coordinator = MamCoordinator(cursorStore: store, adapter: adapter);
    var fallbackCalled = false;

    coordinator.requestOlder(
      bareJid: 'room@example.com',
      isRoom: true,
      seeded: false,
      oldestMamId: null,
      onDmInitialFallback: () => fallbackCalled = true,
    );

    expect(fallbackCalled, isFalse);
    expect(adapter.queries, hasLength(1));
    expect(adapter.queries.single.isRoom, isTrue);
    expect(adapter.queries.single.plan.before, '');
    expect(store.prependOffsetFor('room@example.com'), isNull);
  });

  test('older DM request without anchor delegates to DM initial fallback', () {
    final store = MamCursorStore(
      now: () => DateTime.utc(2026, 1, 1),
      schedule: _FakeScheduler().schedule,
    );
    final adapter = _FakeAdapter();
    final coordinator = MamCoordinator(cursorStore: store, adapter: adapter);
    var fallbackCalled = false;

    coordinator.requestOlder(
      bareJid: 'bob@example.com',
      isRoom: false,
      seeded: false,
      oldestMamId: '',
      onDmInitialFallback: () => fallbackCalled = true,
    );

    expect(fallbackCalled, isTrue);
    expect(adapter.queries, isEmpty);
  });

  test('requestOlder is skipped when archive is exhausted', () {
    final store = MamCursorStore(
      now: () => DateTime.utc(2026, 1, 1),
      schedule: _FakeScheduler().schedule,
    );
    final adapter = _FakeAdapter();
    final coordinator = MamCoordinator(cursorStore: store, adapter: adapter);

    // Mark the archive exhausted before requesting older messages.
    coordinator.markArchiveExhausted('alice@example.com');

    coordinator.requestOlder(
      bareJid: 'alice@example.com',
      isRoom: false,
      seeded: true,
      oldestMamId: 'm-1',
      onDmInitialFallback: () {},
    );

    // No query should have been issued.
    expect(adapter.queries, isEmpty);
  });

  test('requestOlder proceeds after clearArchiveExhausted', () {
    final scheduler = _FakeScheduler();
    final store = MamCursorStore(
      now: () => DateTime.utc(2026, 1, 1),
      schedule: scheduler.schedule,
    );
    final adapter = _FakeAdapter();
    final coordinator = MamCoordinator(cursorStore: store, adapter: adapter);

    coordinator.markArchiveExhausted('alice@example.com');
    store.clearArchiveExhausted('alice@example.com');

    coordinator.requestOlder(
      bareJid: 'alice@example.com',
      isRoom: false,
      seeded: true,
      oldestMamId: 'm-1',
      onDmInitialFallback: () {},
    );

    expect(adapter.queries, hasLength(1));
    expect(adapter.queries.single.plan.beforeId, 'm-1');
  });

  test('isArchiveExhausted reflects markArchiveExhausted', () {
    final store = MamCursorStore(
      now: () => DateTime.utc(2026, 1, 1),
      schedule: _FakeScheduler().schedule,
    );
    final adapter = _FakeAdapter();
    final coordinator = MamCoordinator(cursorStore: store, adapter: adapter);

    expect(coordinator.isArchiveExhausted('room@example.com'), isFalse);
    coordinator.markArchiveExhausted('room@example.com');
    expect(coordinator.isArchiveExhausted('room@example.com'), isTrue);
  });

  test('catch-up emits query and returns requested anchor', () {
    final store = MamCursorStore(
      now: () => DateTime.utc(2026, 1, 1),
      schedule: _FakeScheduler().schedule,
    );
    final adapter = _FakeAdapter();
    final coordinator = MamCoordinator(cursorStore: store, adapter: adapter);
    var fallbackCalled = false;

    final requested = coordinator.requestCatchUpStep(
      bareJid: 'alice@example.com',
      isRoom: false,
      seeded: false,
      latestMamId: 'm-99',
      scopeKey: 'alice@example.com',
      onFallback: () => fallbackCalled = true,
    );

    expect(fallbackCalled, isFalse);
    expect(requested, 'm-99');
    expect(adapter.queries, hasLength(1));
    expect(adapter.queries.single.plan.after, 'm-99');
    expect(adapter.queries.single.plan.useWithJid, isFalse);
  });

  test('catch-up fallback is invoked when no latest anchor exists', () {
    final store = MamCursorStore(
      now: () => DateTime.utc(2026, 1, 1),
      schedule: _FakeScheduler().schedule,
    );
    final adapter = _FakeAdapter();
    final coordinator = MamCoordinator(cursorStore: store, adapter: adapter);
    var fallbackCalled = false;

    final requested = coordinator.requestCatchUpStep(
      bareJid: 'room@example.com',
      isRoom: true,
      seeded: true,
      latestMamId: null,
      scopeKey: 'room:room@example.com',
      onFallback: () => fallbackCalled = true,
    );

    expect(fallbackCalled, isTrue);
    expect(requested, isNull);
    expect(adapter.queries, isEmpty);
  });
}
