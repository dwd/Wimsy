import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/room_nickname.dart';

void main() {
  group('defaultRoomNickname', () {
    test('uses the trimmed profile name when one is set', () {
      expect(
        defaultRoomNickname(
          accountJid: 'alice@example.com',
          profileDisplayName: '  Alice Smith  ',
        ),
        'Alice Smith',
      );
    });

    test('uses the account localpart when the profile has no name', () {
      expect(
        defaultRoomNickname(accountJid: 'alice@example.com/resource'),
        'alice',
      );
      expect(
        defaultRoomNickname(
          accountJid: 'bob@example.com',
          profileDisplayName: '   ',
        ),
        'bob',
      );
    });
  });
}
