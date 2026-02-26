import 'package:test/test.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/Negotiator.dart';
import 'package:xmpp_stone/src/features/SessionInitiationNegotiator.dart';

void main() {
  group('SessionInitiationNegotiator', () {
    test('skips optional session IQ and marks session ready', () async {
      final connection = Connection(
        XmppAccountSettings.fromJid('user@example.com', 'password'),
      );
      final negotiator = SessionInitiationNegotiator(connection);

      final sessionNonza = Nonza()
        ..name = 'session'
        ..addAttribute(
          XmppAttribute('xmlns', 'urn:ietf:params:xml:ns:xmpp-session'),
        );
      sessionNonza.addChild(XmppElement()..name = 'optional');

      final sentStanzas = <String>[];
      final sub = connection.outStanzasStream.listen((stanza) {
        sentStanzas.add(stanza.name ?? '');
      });

      negotiator.negotiate([sessionNonza]);

      await Future<void>.delayed(Duration.zero);

      await sub.cancel();

      expect(negotiator.state, NegotiatorState.DONE);
      expect(connection.state, XmppConnectionState.SessionInitialized);
      expect(sentStanzas, isEmpty);
    });
  });
}
