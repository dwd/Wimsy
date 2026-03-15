import 'mam_cursor_store.dart';
import 'mam_query_planner.dart';

abstract class MamQueryAdapter {
  void queryDm(String bareJid, MamQueryPlan plan);
  void queryRoom(String roomJid, MamQueryPlan plan);
}

class CallbackMamQueryAdapter implements MamQueryAdapter {
  CallbackMamQueryAdapter(this._query);

  final void Function({
    required bool isRoom,
    required String jid,
    required MamQueryPlan plan,
  })
  _query;

  @override
  void queryDm(String bareJid, MamQueryPlan plan) {
    _query(isRoom: false, jid: bareJid, plan: plan);
  }

  @override
  void queryRoom(String roomJid, MamQueryPlan plan) {
    _query(isRoom: true, jid: roomJid, plan: plan);
  }
}

class MamCoordinator {
  MamCoordinator({
    required MamCursorStore cursorStore,
    required MamQueryAdapter adapter,
  }) : _cursorStore = cursorStore,
       _adapter = adapter;

  final MamCursorStore _cursorStore;
  final MamQueryAdapter _adapter;

  void requestOlder({
    required String bareJid,
    required bool isRoom,
    required bool seeded,
    required String? oldestMamId,
    required void Function() onDmInitialFallback,
  }) {
    if (_cursorStore.shouldThrottlePageRequest(bareJid)) {
      return;
    }
    _cursorStore.markPageRequest(bareJid);
    final plan = MamQueryPlanner.older(
      isRoom: isRoom,
      seeded: seeded,
      oldestMamId: oldestMamId,
    );
    if (plan == null) {
      if (isRoom) {
        _adapter.queryRoom(bareJid, MamQueryPlanner.initial(isRoom: true));
      } else {
        onDmInitialFallback();
      }
      return;
    }
    _cursorStore.startPrepend(bareJid);
    if (isRoom) {
      _adapter.queryRoom(bareJid, plan);
    } else {
      _adapter.queryDm(bareJid, plan);
    }
  }

  void requestDmInitial({required String bareJid, required bool hasMessages}) {
    if (hasMessages || _cursorStore.shouldThrottleBackfill(bareJid)) {
      return;
    }
    _cursorStore.markBackfill(bareJid);
    _adapter.queryDm(bareJid, MamQueryPlanner.initial(isRoom: false));
  }

  String? requestCatchUpStep({
    required String bareJid,
    required bool isRoom,
    required bool seeded,
    required String? latestMamId,
    required String scopeKey,
    required void Function() onFallback,
  }) {
    final plan = MamQueryPlanner.catchUp(
      isRoom: isRoom,
      seeded: seeded,
      latestMamId: latestMamId,
    );
    if (plan == null) {
      onFallback();
      return null;
    }
    if (_cursorStore.shouldThrottleCatchUp(scopeKey)) {
      return null;
    }
    _cursorStore.markCatchUp(scopeKey);
    if (isRoom) {
      _adapter.queryRoom(bareJid, plan);
    } else {
      _adapter.queryDm(bareJid, plan);
    }
    return latestMamId;
  }
}
