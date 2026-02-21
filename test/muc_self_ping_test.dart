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
}
