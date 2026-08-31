import 'package:test/test.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/Negotiator.dart';
import 'package:xmpp_stone/src/features/servicediscovery/Feature.dart';
import 'package:xmpp_stone/src/features/servicediscovery/MAMNegotiator.dart';

void main() {
  test('MAM capability query does not block connection setup indefinitely',
      () async {
    final connection = Connection(
      XmppAccountSettings.fromJid('user@example.com', 'password'),
    );
    final negotiator = MAMNegotiator(
      connection,
      responseTimeout: const Duration(milliseconds: 20),
    );
    final mamFeature = Feature()
      ..addAttribute(XmppAttribute('var', 'urn:xmpp:mam:2'));

    negotiator.negotiate(<Nonza>[mamFeature]);

    expect(negotiator.state, NegotiatorState.NEGOTIATING);

    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(negotiator.state, NegotiatorState.DONE);
  });
}
