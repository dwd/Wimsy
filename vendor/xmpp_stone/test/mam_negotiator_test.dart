import 'package:test/test.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/Negotiator.dart';
import 'package:xmpp_stone/src/features/servicediscovery/Feature.dart';
import 'package:xmpp_stone/src/features/servicediscovery/MAMNegotiator.dart';

void main() {
  test('derives mandatory MAM capabilities without sending a form query',
      () async {
    final connection = Connection(
      XmppAccountSettings.fromJid('user@example.com', 'password'),
    );
    final negotiator = MAMNegotiator(connection);
    final mamFeature = Feature()
      ..addAttribute(XmppAttribute('var', 'urn:xmpp:mam:2'));

    final sentStanzas = <String>[];
    final subscription = connection.outStanzasStream.listen(
      (stanza) => sentStanzas.add(stanza.buildXmlString()),
    );

    negotiator.negotiate(<Nonza>[mamFeature]);
    expect(negotiator.state, NegotiatorState.NEGOTIATING);
    expect(negotiator.enabled, isTrue);
    expect(negotiator.isQueryByDateSupported, isTrue);
    expect(negotiator.isQueryByJidSupported, isTrue);
    expect(negotiator.isQueryByIdSupported, isFalse);

    await Future<void>.delayed(Duration.zero);
    expect(negotiator.state, NegotiatorState.DONE);
    expect(sentStanzas, isEmpty);
    await subscription.cancel();
  });

  test('derives extended ID filtering support from disco', () async {
    final connection = Connection(
      XmppAccountSettings.fromJid('user@example.com', 'password'),
    );
    final negotiator = MAMNegotiator(connection);
    final extendedFeature = Feature()
      ..addAttribute(XmppAttribute('var', 'urn:xmpp:mam:2#extended'));

    negotiator.negotiate(<Nonza>[extendedFeature]);

    expect(negotiator.enabled, isTrue);
    expect(negotiator.isQueryByIdSupported, isTrue);
  });
}
