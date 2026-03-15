import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/mam_query_planner.dart';

void main() {
  test('initial plans use expected max and before cursor', () {
    final dm = MamQueryPlanner.initial(isRoom: false);
    expect(dm.max, 50);
    expect(dm.before, '');
    expect(dm.beforeId, isNull);
    expect(dm.after, isNull);
    expect(dm.afterId, isNull);

    final room = MamQueryPlanner.initial(isRoom: true);
    expect(room.max, 25);
    expect(room.before, '');
    expect(room.beforeId, isNull);
    expect(room.after, isNull);
    expect(room.afterId, isNull);
  });

  test('older plans switch between before and beforeId by seeded mode', () {
    final seeded = MamQueryPlanner.older(
      isRoom: false,
      seeded: true,
      oldestMamId: 'm-1',
    );
    expect(seeded, isNotNull);
    expect(seeded!.max, 50);
    expect(seeded.beforeId, 'm-1');
    expect(seeded.before, 'm-1');

    final unseeded = MamQueryPlanner.older(
      isRoom: true,
      seeded: false,
      oldestMamId: 'r-1',
    );
    expect(unseeded, isNotNull);
    expect(unseeded!.max, 25);
    expect(unseeded.before, 'r-1');
    expect(unseeded.beforeId, isNull);
  });

  test('older returns null when no oldest anchor exists', () {
    expect(
      MamQueryPlanner.older(isRoom: false, seeded: true, oldestMamId: null),
      isNull,
    );
    expect(
      MamQueryPlanner.older(isRoom: true, seeded: false, oldestMamId: ''),
      isNull,
    );
  });

  test('catch-up plans switch between after and afterId by seeded mode', () {
    final seeded = MamQueryPlanner.catchUp(
      isRoom: false,
      seeded: true,
      latestMamId: 'm-99',
    );
    expect(seeded, isNotNull);
    expect(seeded!.max, 50);
    expect(seeded.afterId, 'm-99');
    expect(seeded.after, isNull);

    final unseeded = MamQueryPlanner.catchUp(
      isRoom: true,
      seeded: false,
      latestMamId: 'r-99',
    );
    expect(unseeded, isNotNull);
    expect(unseeded!.max, 50);
    expect(unseeded.after, 'r-99');
    expect(unseeded.afterId, isNull);
  });

  test('catch-up returns null when no latest anchor exists', () {
    expect(
      MamQueryPlanner.catchUp(isRoom: false, seeded: true, latestMamId: null),
      isNull,
    );
    expect(
      MamQueryPlanner.catchUp(isRoom: true, seeded: false, latestMamId: ''),
      isNull,
    );
  });
}
