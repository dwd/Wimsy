import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/mam_query_planner.dart';

void main() {
  test('seeded older query includes before-id and RSM before empty cursor', () {
    final plan = MamQueryPlanner.older(
      isRoom: false,
      seeded: true,
      oldestMamId: 'm-older',
    );

    expect(plan, isNotNull);
    expect(plan!.beforeId, 'm-older');
    expect(plan.before, '');
  });

  test('unseeded older query keeps explicit before anchor', () {
    final plan = MamQueryPlanner.older(
      isRoom: true,
      seeded: false,
      oldestMamId: 'm-room-older',
    );

    expect(plan, isNotNull);
    expect(plan!.before, 'm-room-older');
    expect(plan.beforeId, isNull);
  });
}
