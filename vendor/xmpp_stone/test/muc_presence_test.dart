import 'package:test/test.dart';
import 'package:xmpp_stone/src/muc/MucManager.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/stanzas/PresenceStanza.dart';

/// Builds a join-error presence stanza as a server would send it when
/// rejecting a MUC join.
PresenceStanza _buildJoinErrorPresence({
  required String roomJid,
  required String errorCondition,
  String errorType = 'cancel',
}) {
  const xmppStanzasNs = 'urn:ietf:params:xml:ns:xmpp-stanzas';
  final presence = PresenceStanza.withType(PresenceType.ERROR);
  presence.fromJid = Jid.fromFullJid(roomJid);
  final error = XmppElement()..name = 'error';
  error.addAttribute(XmppAttribute('type', errorType));
  final condition = XmppElement()..name = errorCondition;
  condition.addAttribute(XmppAttribute('xmlns', xmppStanzasNs));
  error.addChild(condition);
  presence.addChild(error);
  return presence;
}

void main() {
  test('Muc presence exposes status codes', () async {
    final connection = Connection(XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222));
    final manager = MucManager.getInstance(connection);

    final presence = PresenceStanza();
    presence.fromJid = Jid.fromFullJid('room@example.com/nick');
    final x = XmppElement()..name = 'x';
    x.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#user'));
    final status201 = XmppElement()..name = 'status';
    status201.addAttribute(XmppAttribute('code', '201'));
    final status110 = XmppElement()..name = 'status';
    status110.addAttribute(XmppAttribute('code', '110'));
    x.addChild(status201);
    x.addChild(status110);
    presence.addChild(x);

    final nextUpdate = manager.roomPresenceStream.first;
    connection.fireNewStanzaEvent(presence);
    final update = await nextUpdate;
    expect(update.statusCodes.contains('201'), isTrue);
    expect(update.statusCodes.contains('110'), isTrue);
  });

  test('MUC join error with registration-required is emitted on roomJoinErrorStream', () async {
    final connection = Connection(
      XmppAccountSettings('test2', 'user2', 'example.com', 'pass', 5222),
    );
    final manager = MucManager.getInstance(connection);

    final presence = _buildJoinErrorPresence(
      roomJid: 'members-only@example.com',
      errorCondition: 'registration-required',
    );

    final nextError = manager.roomJoinErrorStream.first;
    connection.fireNewStanzaEvent(presence);
    final error = await nextError;

    expect(error.roomJid, equals('members-only@example.com'));
    expect(error.errorCondition, equals('registration-required'));
  });

  test('MUC join error with forbidden is emitted on roomJoinErrorStream', () async {
    final connection = Connection(
      XmppAccountSettings('test3', 'user3', 'example.com', 'pass', 5222),
    );
    final manager = MucManager.getInstance(connection);

    final presence = _buildJoinErrorPresence(
      roomJid: 'banned-room@example.com',
      errorCondition: 'forbidden',
      errorType: 'auth',
    );

    final nextError = manager.roomJoinErrorStream.first;
    connection.fireNewStanzaEvent(presence);
    final error = await nextError;

    expect(error.roomJid, equals('banned-room@example.com'));
    expect(error.errorCondition, equals('forbidden'));
  });

  test('MUC join error does NOT emit on roomPresenceStream', () async {
    final connection = Connection(
      XmppAccountSettings('test4', 'user4', 'example.com', 'pass', 5222),
    );
    final manager = MucManager.getInstance(connection);

    final presence = _buildJoinErrorPresence(
      roomJid: 'restricted@example.com',
      errorCondition: 'registration-required',
    );

    var presenceEventFired = false;
    final sub = manager.roomPresenceStream.listen((_) {
      presenceEventFired = true;
    });

    final nextError = manager.roomJoinErrorStream.first;
    connection.fireNewStanzaEvent(presence);
    await nextError;
    // Give the event loop a chance to fire a spurious presence event.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await sub.cancel();

    expect(presenceEventFired, isFalse);
  });

  test('Normal MUC presence (without error) still emits on roomPresenceStream', () async {
    final connection = Connection(
      XmppAccountSettings('test5', 'user5', 'example.com', 'pass', 5222),
    );
    final manager = MucManager.getInstance(connection);

    final presence = PresenceStanza();
    presence.fromJid = Jid.fromFullJid('open-room@example.com/alice');
    final x = XmppElement()..name = 'x';
    x.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#user'),
    );
    final status110 = XmppElement()..name = 'status';
    status110.addAttribute(XmppAttribute('code', '110'));
    x.addChild(status110);
    presence.addChild(x);

    final nextUpdate = manager.roomPresenceStream.first;
    connection.fireNewStanzaEvent(presence);
    final update = await nextUpdate;

    expect(update.roomJid, equals('open-room@example.com'));
    expect(update.nick, equals('alice'));
    expect(update.isSelf, isTrue);
  });
}
