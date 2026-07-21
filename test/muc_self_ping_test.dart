import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/muc_self_ping.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('buildMucSelfPing builds IQ ping to room nick', () {
    final stanza = buildMucSelfPing(
      id: 'ping1',
      fullJid: 'room@example.com/nick',
    );

    expect(stanza, isA<IqStanza>());
    expect(stanza.type, IqStanzaType.GET);
    expect(stanza.toJid?.fullJid, 'room@example.com/nick');
    final ping = stanza.getChild('ping');
    expect(ping, isNotNull);
    expect(ping!.getAttribute('xmlns')?.value, 'urn:xmpp:ping');
  });

  test('mucSelfPingOutcomeFromResponse handles result', () {
    final stanza = IqStanza('id1', IqStanzaType.RESULT);
    expect(mucSelfPingOutcomeFromResponse(stanza), MucSelfPingOutcome.joined);
  });

  test('mucSelfPingOutcomeFromResponse handles not-acceptable error', () {
    final stanza = IqStanza('id2', IqStanzaType.ERROR);
    final error = XmppElement()..name = 'error';
    final condition = XmppElement()..name = 'not-acceptable';
    condition.addAttribute(
      XmppAttribute('xmlns', 'urn:ietf:params:xml:ns:xmpp-stanzas'),
    );
    error.addChild(condition);
    stanza.addChild(error);
    expect(mucSelfPingOutcomeFromResponse(stanza), MucSelfPingOutcome.notJoined);
  });

  // Openfire returns not-acceptable with type="modify" (rather than type="cancel"
  // as Prosody does). The error type attribute is not used in outcome detection —
  // only the condition element name matters — so this should still map to notJoined.
  test('mucSelfPingOutcomeFromResponse handles not-acceptable with type=modify (Openfire style)', () {
    final stanza = IqStanza('id-openfire', IqStanzaType.ERROR);
    final error = XmppElement()..name = 'error';
    error.addAttribute(XmppAttribute('type', 'modify'));
    final condition = XmppElement()..name = 'not-acceptable';
    condition.addAttribute(
      XmppAttribute('xmlns', 'urn:ietf:params:xml:ns:xmpp-stanzas'),
    );
    error.addChild(condition);
    stanza.addChild(error);
    expect(mucSelfPingOutcomeFromResponse(stanza), MucSelfPingOutcome.notJoined);
  });

  test('mucSelfPingOutcomeFromResponse treats item-not-found as joined', () {
    final stanza = IqStanza('id3', IqStanzaType.ERROR);
    final error = XmppElement()..name = 'error';
    final condition = XmppElement()..name = 'item-not-found';
    condition.addAttribute(
      XmppAttribute('xmlns', 'urn:ietf:params:xml:ns:xmpp-stanzas'),
    );
    error.addChild(condition);
    stanza.addChild(error);
    expect(mucSelfPingOutcomeFromResponse(stanza), MucSelfPingOutcome.joined);
  });
}
