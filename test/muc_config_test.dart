import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/muc_config.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('Default MUC config IQ uses owner query and submit form', () {
    final iq = buildMucDefaultConfigIq('room@example.com');

    expect(iq.type, IqStanzaType.SET);
    expect(iq.toJid?.fullJid, 'room@example.com');

    final query = iq.getChild('query');
    expect(query?.getAttribute('xmlns')?.value, 'http://jabber.org/protocol/muc#owner');

    final form = query?.getChild('x');
    expect(form?.getAttribute('xmlns')?.value, 'jabber:x:data');
    expect(form?.getAttribute('type')?.value, 'submit');
  });
}
