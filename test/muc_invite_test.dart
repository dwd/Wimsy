import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/muc_invite.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('parseMucDirectInvite extracts room and reason', () {
    final stanza = MessageStanza('m1', MessageStanzaType.NORMAL);
    final invite = XmppElement()..name = 'x';
    invite.addAttribute(XmppAttribute('xmlns', mucDirectInviteNamespace));
    invite.addAttribute(XmppAttribute('jid', 'room@example.com'));
    invite.addAttribute(XmppAttribute('reason', 'Join us'));
    invite.addAttribute(XmppAttribute('password', 'secret'));
    stanza.addChild(invite);

    final parsed = parseMucDirectInvite(stanza);
    expect(parsed, isNotNull);
    expect(parsed!.roomJid, 'room@example.com');
    expect(parsed.reason, 'Join us');
    expect(parsed.password, 'secret');
  });

  test('parseMucDirectInvite returns null when no invite', () {
    final stanza = MessageStanza('m2', MessageStanzaType.NORMAL);
    final parsed = parseMucDirectInvite(stanza);
    expect(parsed, isNull);
  });

  test('parseMucMediatedInvite extracts room and inviter', () {
    final stanza = MessageStanza('m3', MessageStanzaType.NORMAL);
    stanza.fromJid = Jid.fromFullJid('room@example.com');
    final x = XmppElement()..name = 'x';
    x.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#user'));
    final invite = XmppElement()..name = 'invite';
    invite.addAttribute(XmppAttribute('from', 'juliet@example.com'));
    final reason = XmppElement()..name = 'reason';
    reason.textValue = 'Join us';
    invite.addChild(reason);
    x.addChild(invite);
    stanza.addChild(x);

    final parsed = parseMucMediatedInvite(stanza);
    expect(parsed, isNotNull);
    expect(parsed!.roomJid, 'room@example.com');
    expect(parsed.inviterJid, 'juliet@example.com');
    expect(parsed.reason, 'Join us');
  });

}
