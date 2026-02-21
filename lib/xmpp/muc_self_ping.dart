import 'package:xmpp_stone/xmpp_stone.dart';

IqStanza buildMucSelfPing({
  required String id,
  required String fullJid,
}) {
  final stanza = IqStanza(id, IqStanzaType.GET);
  stanza.toJid = Jid.fromFullJid(fullJid);
  final ping = XmppElement()..name = 'ping';
  ping.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:ping'));
  stanza.addChild(ping);
  return stanza;
}
