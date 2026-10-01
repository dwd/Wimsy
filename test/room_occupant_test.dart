import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/models/room_occupant.dart';

void main() {
  group('roomOccupantAffiliationRank', () {
    test('ranks owner above admin, member, others, and outcast', () {
      expect(roomOccupantAffiliationRank('owner'), lessThan(
          roomOccupantAffiliationRank('admin')));
      expect(roomOccupantAffiliationRank('admin'), lessThan(
          roomOccupantAffiliationRank('member')));
      expect(roomOccupantAffiliationRank('member'), lessThan(
          roomOccupantAffiliationRank(null)));
      expect(roomOccupantAffiliationRank(null), lessThan(
          roomOccupantAffiliationRank('outcast')));
    });

    test('treats unknown and absent affiliations the same as "none"', () {
      expect(
        roomOccupantAffiliationRank('none'),
        roomOccupantAffiliationRank(null),
      );
      expect(
        roomOccupantAffiliationRank('something-unexpected'),
        roomOccupantAffiliationRank(null),
      );
    });
  });

  group('RoomOccupant.copyWith', () {
    test('overrides only the specified fields', () {
      final occupant = RoomOccupant(
        nick: 'alice',
        role: 'participant',
        affiliation: 'member',
        realJid: 'alice@example.com',
        status: 'Away',
        occupantId: 'occ-1',
        show: PresenceShowElement.AWAY,
      );

      final updated = occupant.copyWith(role: 'moderator', status: 'Back');

      expect(updated.nick, 'alice');
      expect(updated.role, 'moderator');
      expect(updated.affiliation, 'member');
      expect(updated.realJid, 'alice@example.com');
      expect(updated.status, 'Back');
      expect(updated.occupantId, 'occ-1');
      expect(updated.show, PresenceShowElement.AWAY);
    });

    test('clearRealJid and clearStatus null out those fields', () {
      final occupant = RoomOccupant(
        nick: 'bob',
        realJid: 'bob@example.com',
        status: 'Busy',
      );

      final updated = occupant.copyWith(
        clearRealJid: true,
        clearStatus: true,
      );

      expect(updated.realJid, isNull);
      expect(updated.status, isNull);
      expect(updated.nick, 'bob');
    });

    test('show defaults to null and clearShow nulls it out', () {
      final occupant = RoomOccupant(nick: 'carol');
      expect(occupant.show, isNull);

      final withShow = occupant.copyWith(show: PresenceShowElement.DND);
      expect(withShow.show, PresenceShowElement.DND);

      final cleared = withShow.copyWith(clearShow: true);
      expect(cleared.show, isNull);
    });
  });
}
