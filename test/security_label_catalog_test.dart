import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spiffing/spiffing.dart' as spiffing;
import 'package:wimsy/xmpp/security_label_catalog.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

XmppElement _securityLabelElement({
  required String displayMarkingText,
  String? fgColor,
  String? bgColor,
  String? essBase64,
}) {
  final securityLabel = XmppElement()..name = 'securitylabel';
  securityLabel.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sec-label:0'));
  final displayMarking = XmppElement()..name = 'displaymarking';
  if (fgColor != null) {
    displayMarking.addAttribute(XmppAttribute('fgcolor', fgColor));
  }
  if (bgColor != null) {
    displayMarking.addAttribute(XmppAttribute('bgcolor', bgColor));
  }
  displayMarking.textValue = displayMarkingText;
  securityLabel.addChild(displayMarking);
  if (essBase64 != null) {
    final label = XmppElement()..name = 'label';
    final ess = XmppElement()..name = 'esssecuritylabel';
    ess.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sec-label:ess:0'));
    ess.textValue = essBase64;
    label.addChild(ess);
    securityLabel.addChild(label);
  }
  return securityLabel;
}

void main() {
  test('parseSecurityLabelCatalog extracts items with selector/default', () {
    final stanza = IqStanza('c1', IqStanzaType.RESULT);
    final catalog = XmppElement()..name = 'catalog';
    catalog.addAttribute(
      XmppAttribute('xmlns', securityLabelCatalogNamespace),
    );
    catalog.addAttribute(XmppAttribute('restrict', 'false'));

    final unclassified = XmppElement()..name = 'item';
    unclassified.addAttribute(XmppAttribute('selector', 'UNCLASSIFIED'));
    unclassified.addAttribute(XmppAttribute('default', 'true'));
    unclassified.addChild(
      _securityLabelElement(displayMarkingText: 'UNCLASSIFIED'),
    );
    catalog.addChild(unclassified);

    final secret = XmppElement()..name = 'item';
    secret.addAttribute(XmppAttribute('selector', 'SECRET'));
    secret.addChild(
      _securityLabelElement(
        displayMarkingText: 'SECRET',
        fgColor: 'white',
        bgColor: 'red',
      ),
    );
    catalog.addChild(secret);

    stanza.addChild(catalog);

    final entries = parseSecurityLabelCatalog(stanza);
    expect(entries, hasLength(2));

    expect(entries[0].selector, 'UNCLASSIFIED');
    expect(entries[0].isDefault, isTrue);
    expect(entries[0].info.text, 'UNCLASSIFIED');
    expect(entries[0].securityLabelElement.name, 'securitylabel');

    expect(entries[1].selector, 'SECRET');
    expect(entries[1].isDefault, isFalse);
    expect(entries[1].info.text, 'SECRET');
    expect(entries[1].info.fgColor, 'white');
    expect(entries[1].info.bgColor, 'red');
  });

  test(
    'parseSecurityLabelCatalog accepts items with neither selector nor default',
    () {
      final stanza = IqStanza('c2', IqStanzaType.RESULT);
      final catalog = XmppElement()..name = 'catalog';
      catalog.addAttribute(
        XmppAttribute('xmlns', securityLabelCatalogNamespace),
      );
      final item = XmppElement()..name = 'item';
      item.addChild(_securityLabelElement(displayMarkingText: 'PLAIN'));
      catalog.addChild(item);
      stanza.addChild(catalog);

      final entries = parseSecurityLabelCatalog(stanza);
      expect(entries, hasLength(1));
      expect(entries.single.selector, isNull);
      expect(entries.single.isDefault, isFalse);
      expect(entries.single.info.text, 'PLAIN');
    },
  );

  test(
    'parseSecurityLabelCatalog skips items missing a securitylabel child',
    () {
      final stanza = IqStanza('c3', IqStanzaType.RESULT);
      final catalog = XmppElement()..name = 'catalog';
      catalog.addAttribute(
        XmppAttribute('xmlns', securityLabelCatalogNamespace),
      );
      final badItem = XmppElement()..name = 'item';
      badItem.addAttribute(XmppAttribute('selector', 'BROKEN'));
      catalog.addChild(badItem);

      final goodItem = XmppElement()..name = 'item';
      goodItem.addAttribute(XmppAttribute('selector', 'OK'));
      goodItem.addChild(_securityLabelElement(displayMarkingText: 'OK'));
      catalog.addChild(goodItem);

      stanza.addChild(catalog);

      final entries = parseSecurityLabelCatalog(stanza);
      expect(entries, hasLength(1));
      expect(entries.single.selector, 'OK');
    },
  );

  test(
    'parseSecurityLabelCatalog skips an item whose securitylabel yields no '
    'usable display info (bad ESS payload, empty displaymarking)',
    () {
      final stanza = IqStanza('c4', IqStanzaType.RESULT);
      final catalog = XmppElement()..name = 'catalog';
      catalog.addAttribute(
        XmppAttribute('xmlns', securityLabelCatalogNamespace),
      );

      // No known policy to decode the ESS payload against, and an empty
      // <displaymarking/> to fall back to - this item must be dropped
      // rather than crashing the whole parse.
      final malformed = XmppElement()..name = 'item';
      malformed.addAttribute(XmppAttribute('selector', 'MALFORMED'));
      final securityLabel = XmppElement()..name = 'securitylabel';
      securityLabel.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:sec-label:0'),
      );
      securityLabel.addChild(XmppElement()..name = 'displaymarking');
      final label = XmppElement()..name = 'label';
      final ess = XmppElement()..name = 'esssecuritylabel';
      ess.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sec-label:ess:0'));
      ess.textValue = base64.encode(latin1.encode('not a real label'));
      label.addChild(ess);
      securityLabel.addChild(label);
      malformed.addChild(securityLabel);
      catalog.addChild(malformed);

      final good = XmppElement()..name = 'item';
      good.addAttribute(XmppAttribute('selector', 'GOOD'));
      good.addChild(_securityLabelElement(displayMarkingText: 'GOOD'));
      catalog.addChild(good);

      stanza.addChild(catalog);

      final entries = parseSecurityLabelCatalog(stanza);
      expect(entries, hasLength(1));
      expect(entries.single.selector, 'GOOD');
    },
  );

  test(
    'parseSecurityLabelCatalog parses the primary label against a known '
    'policy, preferring it over displaymarking',
    () {
      final site = spiffing.Site();
      final policy = site.load('''
<SPIF>
  <securityPolicyId name="TestPolicy" id="1.2.3.4.6"/>
  <securityClassifications>
    <securityClassification lacv="10" name="SECRET" hierarchy="10" color="red"/>
  </securityClassifications>
</SPIF>
''');
      final label = spiffing.Label.forClassification(policy, 10);
      final berBytes = label.write(spiffing.Format.ber);
      final base64Data = base64.encode(latin1.encode(berBytes));

      final stanza = IqStanza('c5', IqStanzaType.RESULT);
      final catalog = XmppElement()..name = 'catalog';
      catalog.addAttribute(
        XmppAttribute('xmlns', securityLabelCatalogNamespace),
      );
      final item = XmppElement()..name = 'item';
      item.addAttribute(XmppAttribute('selector', 'SECRET'));
      item.addChild(
        _securityLabelElement(
          displayMarkingText: 'SHOULD NOT BE USED',
          essBase64: base64Data,
        ),
      );
      catalog.addChild(item);
      stanza.addChild(catalog);

      final entries = parseSecurityLabelCatalog(stanza);
      expect(entries, hasLength(1));
      expect(entries.single.info.isFallback, isFalse);
      expect(entries.single.info.text, contains('SECRET'));
      expect(entries.single.info.fgColor, 'red');
    },
  );

  test('parseSecurityLabelCatalog returns empty for an error response', () {
    final stanza = IqStanza('c6', IqStanzaType.ERROR);
    expect(parseSecurityLabelCatalog(stanza), isEmpty);
  });

  test('parseSecurityLabelCatalog returns empty when no catalog present', () {
    final stanza = IqStanza('c7', IqStanzaType.RESULT);
    expect(parseSecurityLabelCatalog(stanza), isEmpty);
  });
}
