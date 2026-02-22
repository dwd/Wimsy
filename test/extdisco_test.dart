import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/extdisco.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('parseExternalServices extracts TURN service', () {
    final services = XmppElement()..name = 'services';
    services.addAttribute(XmppAttribute('xmlns', extDiscoNamespace));
    final service = XmppElement()..name = 'service';
    service.addAttribute(XmppAttribute('type', 'turn'));
    service.addAttribute(XmppAttribute('host', 'turn.example.com'));
    service.addAttribute(XmppAttribute('port', '3478'));
    service.addAttribute(XmppAttribute('transport', 'udp'));
    service.addAttribute(XmppAttribute('username', 'user'));
    service.addAttribute(XmppAttribute('password', 'pass'));
    services.addChild(service);

    final parsed = parseExternalServices(services);

    expect(parsed, hasLength(1));
    expect(parsed.first.type, 'turn');
    expect(parsed.first.toUriString(), 'turn:turn.example.com:3478?transport=udp');
    expect(parsed.first.username, 'user');
  });
}
