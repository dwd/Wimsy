class MamQueryPlan {
  const MamQueryPlan({
    required this.max,
    this.before,
    this.after,
    this.beforeId,
    this.afterId,
    this.useWithJid = true,
  });

  final int max;
  final String? before;
  final String? after;
  final String? beforeId;
  final String? afterId;
  final bool useWithJid;
}

class MamQueryPlanner {
  const MamQueryPlanner._();

  static MamQueryPlan initial({required bool isRoom}) {
    return MamQueryPlan(max: isRoom ? 25 : 50, before: '');
  }

  static MamQueryPlan? older({
    required bool isRoom,
    required bool seeded,
    required String? oldestMamId,
  }) {
    if (oldestMamId == null || oldestMamId.isEmpty) {
      return null;
    }
    return MamQueryPlan(
      max: isRoom ? 25 : 50,
      before: oldestMamId,
      beforeId: seeded ? oldestMamId : null,
    );
  }

  static MamQueryPlan? catchUp({
    required bool isRoom,
    required bool seeded,
    required String? latestMamId,
  }) {
    if (latestMamId == null || latestMamId.isEmpty) {
      return null;
    }
    return MamQueryPlan(
      max: isRoom ? 50 : 50,
      afterId: seeded ? latestMamId : null,
      after: seeded ? null : latestMamId,
      // For DMs, avoid the MAM `with` filter during catch-up to prevent
      // cursor gaps when local per-chat anchors drift from archive ordering.
      useWithJid: isRoom,
    );
  }
}
