import 'package:xmpp_stone/xmpp_stone.dart';

enum MucSelfPingOutcome {
  joined,
  notJoined,
  inconclusive,
}

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

MucSelfPingOutcome mucSelfPingOutcomeFromResponse(IqStanza stanza) {
  if (stanza.type == IqStanzaType.RESULT) {
    return MucSelfPingOutcome.joined;
  }
  if (stanza.type != IqStanzaType.ERROR) {
    return MucSelfPingOutcome.inconclusive;
  }
  final condition = _errorCondition(stanza);
  switch (condition) {
    case 'not-acceptable':
      return MucSelfPingOutcome.notJoined;
    case 'service-unavailable':
    case 'feature-not-implemented':
    case 'item-not-found':
      return MucSelfPingOutcome.joined;
    case 'remote-server-not-found':
    case 'remote-server-timeout':
      return MucSelfPingOutcome.inconclusive;
    default:
      return MucSelfPingOutcome.notJoined;
  }
}

String _errorCondition(IqStanza stanza) {
  final error = stanza.getChild('error');
  if (error == null) {
    return '';
  }
  for (final child in error.children) {
    if (child.getAttribute('xmlns')?.value ==
        'urn:ietf:params:xml:ns:xmpp-stanzas') {
      return child.name ?? '';
    }
  }
  return '';
}
