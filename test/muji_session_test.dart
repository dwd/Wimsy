import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/av/muji_session.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('MujiSessionState tracks participants by jid', () {
    final session = MujiSessionState();

    session.addParticipant(MujiParticipant(
      jid: Jid.fromFullJid('alice@example.com/resource'),
      nick: 'Alice',
    ));
    session.addParticipant(MujiParticipant(
      jid: Jid.fromFullJid('bob@example.com/resource'),
      nick: 'Bob',
    ));

    expect(session.participants, hasLength(2));

    session.removeParticipant(Jid.fromFullJid('alice@example.com/resource'));
    expect(session.participants, hasLength(1));
    expect(session.participants.first.nick, 'Bob');
  });

  test('MujiSessionState clear resets participants', () {
    final session = MujiSessionState();
    session.addParticipant(MujiParticipant(
      jid: Jid.fromFullJid('alice@example.com/resource'),
      nick: 'Alice',
    ));

    session.clear();

    expect(session.participants, isEmpty);
  });
}
