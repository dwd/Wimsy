import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

class TestConnection extends Connection {
  TestConnection(super.account);

  AbstractStanza? lastWrittenStanza;

  @override
  void writeStanza(AbstractStanza stanza) {
    lastWrittenStanza = stanza;
  }

  @override
  void writeNonza(Nonza nonza) {}

  @override
  void write(Object? message) {}
}

PresenceStanza _buildMucPresence({
  required String fromFullJid,
  required String nick,
  required bool unavailable,
  String? realJid,
  String? role,
  String? affiliation,
  String? statusText,
  PresenceShowElement? show,
}) {
  final stanza = unavailable
      ? PresenceStanza.withType(PresenceType.UNAVAILABLE)
      : PresenceStanza();
  stanza.fromJid = Jid.fromFullJid('$fromFullJid/$nick');
  final x = XmppElement()..name = 'x';
  x.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#user'));
  final item = XmppElement()..name = 'item';
  item.addAttribute(XmppAttribute('role', role ?? 'participant'));
  item.addAttribute(XmppAttribute('affiliation', affiliation ?? 'member'));
  if (realJid != null) {
    item.addAttribute(XmppAttribute('jid', realJid));
  }
  x.addChild(item);
  final mucStatusCode = XmppElement()..name = 'status';
  mucStatusCode.addAttribute(XmppAttribute('code', '110'));
  x.addChild(mucStatusCode);
  stanza.addChild(x);
  if (statusText != null) {
    // The free-text presence `<status/>` (no `code` attribute) is distinct
    // from the MUC numeric `<status code="..."/>` elements above.
    stanza.status = statusText;
  }
  if (show != null) {
    stanza.show = show;
  }
  return stanza;
}

void main() {
  test('MUC join builds presence stanza', () {
    final account = XmppAccountSettings(
      'test',
      'user',
      'example.com',
      'pass',
      5222,
    );
    final connection = TestConnection(account);
    final muc = connection.getMucModule();

    muc.joinRoom(Jid.fromFullJid('room@conference.example'), 'nick');

    final stanza = connection.lastWrittenStanza as PresenceStanza;
    expect(stanza.toJid?.fullJid, 'room@conference.example/nick');
    final x = stanza.getChild('x');
    expect(x?.getAttribute('xmlns')?.value, 'http://jabber.org/protocol/muc');
  });

  test('MUC groupchat message emits stream', () async {
    final account = XmppAccountSettings(
      'test',
      'user',
      'example.com',
      'pass',
      5222,
    );
    final connection = TestConnection(account);
    final muc = connection.getMucModule();

    final message = MessageStanza('m1', MessageStanzaType.GROUPCHAT);
    message.fromJid = Jid.fromFullJid('room@conference.example/alice');
    message.body = 'Hello room';

    final completer = Completer<MucMessage>();
    final sub = muc.roomMessageStream.listen((event) {
      completer.complete(event);
    });

    connection.fireNewStanzaEvent(message);

    final received = await completer.future.timeout(const Duration(seconds: 1));
    await sub.cancel();

    expect(received.roomJid, 'room@conference.example');
    expect(received.nick, 'alice');
    expect(received.body, 'Hello room');
  });

  test('MUC groupchat message exposes replace id', () async {
    final account = XmppAccountSettings(
      'test',
      'user',
      'example.com',
      'pass',
      5222,
    );
    final connection = TestConnection(account);
    final muc = connection.getMucModule();

    final message = MessageStanza('m2', MessageStanzaType.GROUPCHAT);
    message.fromJid = Jid.fromFullJid('room@conference.example/alice');
    message.body = 'Corrected';
    final replace = XmppElement()..name = 'replace';
    replace.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:message-correct:0'));
    replace.addAttribute(XmppAttribute('id', 'orig-1'));
    message.addChild(replace);

    final completer = Completer<MucMessage>();
    final sub = muc.roomMessageStream.listen((event) {
      completer.complete(event);
    });

    connection.fireNewStanzaEvent(message);

    final received = await completer.future.timeout(const Duration(seconds: 1));
    await sub.cancel();

    expect(received.replaceId, 'orig-1');
  });

  test('MUC presence emits occupant updates', () async {
    final account = XmppAccountSettings(
      'test',
      'user',
      'example.com',
      'pass',
      5222,
    );
    final connection = TestConnection(account);
    final muc = connection.getMucModule();

    final presence = _buildMucPresence(
      fromFullJid: 'room@conference.example',
      nick: 'me',
      unavailable: false,
      realJid: 'me@example.com/resource',
    );

    final completer = Completer<MucPresenceUpdate>();
    final sub = muc.roomPresenceStream.listen((event) {
      completer.complete(event);
    });

    connection.fireNewStanzaEvent(presence);

    final update = await completer.future.timeout(const Duration(seconds: 1));
    await sub.cancel();

    expect(update.roomJid, 'room@conference.example');
    expect(update.realJid, 'me@example.com/resource');
    expect(update.nick, 'me');
    expect(update.isSelf, true);
    expect(update.unavailable, false);
  });

  test(
    'MUC presence update captures role, affiliation, and status text',
    () async {
      final account = XmppAccountSettings(
        'test',
        'user',
        'example.com',
        'pass',
        5222,
      );
      final connection = TestConnection(account);
      final muc = connection.getMucModule();

      final presence = _buildMucPresence(
        fromFullJid: 'room@conference.example',
        nick: 'alice',
        unavailable: false,
        role: 'moderator',
        affiliation: 'owner',
        statusText: 'Away at lunch',
        show: PresenceShowElement.AWAY,
      );

      final completer = Completer<MucPresenceUpdate>();
      final sub = muc.roomPresenceStream.listen((event) {
        completer.complete(event);
      });

      connection.fireNewStanzaEvent(presence);

      final update = await completer.future.timeout(
        const Duration(seconds: 1),
      );
      await sub.cancel();

      expect(update.nick, 'alice');
      expect(update.role, 'moderator');
      expect(update.affiliation, 'owner');
      expect(update.status, 'Away at lunch');
      expect(update.show, PresenceShowElement.AWAY);
    },
  );

  test('MUC presence update defaults show to null when absent', () async {
    final account = XmppAccountSettings(
      'test',
      'user',
      'example.com',
      'pass',
      5222,
    );
    final connection = TestConnection(account);
    final muc = connection.getMucModule();

    final presence = _buildMucPresence(
      fromFullJid: 'room@conference.example',
      nick: 'bob',
      unavailable: false,
    );

    final completer = Completer<MucPresenceUpdate>();
    final sub = muc.roomPresenceStream.listen((event) {
      completer.complete(event);
    });

    connection.fireNewStanzaEvent(presence);

    final update = await completer.future.timeout(const Duration(seconds: 1));
    await sub.cancel();

    expect(update.nick, 'bob');
    expect(update.show, isNull);
  });
}
