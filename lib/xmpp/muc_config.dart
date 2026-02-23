import 'package:xmpp_stone/xmpp_stone.dart';

const String _mucOwnerNamespace = 'http://jabber.org/protocol/muc#owner';
const String _dataFormNamespace = 'jabber:x:data';

IqStanza buildMucDefaultConfigIq(String roomJid) {
  final id = AbstractStanza.getRandomId();
  final iq = IqStanza(id, IqStanzaType.SET);
  iq.toJid = Jid.fromFullJid(roomJid);

  final query = XmppElement()..name = 'query';
  query.addAttribute(XmppAttribute('xmlns', _mucOwnerNamespace));

  final form = XmppElement()..name = 'x';
  form.addAttribute(XmppAttribute('xmlns', _dataFormNamespace));
  form.addAttribute(XmppAttribute('type', 'submit'));

  query.addChild(form);
  iq.addChild(query);
  return iq;
}
