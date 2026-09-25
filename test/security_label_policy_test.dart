import 'package:flutter_test/flutter_test.dart';
import 'package:spiffing/spiffing.dart' as spiffing;
import 'package:wimsy/xmpp/security_label_policy.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('parseSecurityLabelPolicyList extracts every item in order', () {
    final stanza = IqStanza('p1', IqStanzaType.RESULT);
    final policy = XmppElement()..name = 'policy';
    policy.addAttribute(
      XmppAttribute('xmlns', securityLabelPolicyNamespace),
    );
    final food = XmppElement()..name = 'item';
    food.addAttribute(XmppAttribute('id', '1.2.826.0.1.6726289.0.0'));
    food.addAttribute(XmppAttribute('name', 'Food'));
    policy.addChild(food);
    final drink = XmppElement()..name = 'item';
    drink.addAttribute(XmppAttribute('id', '1.2.826.0.1.6726289.0.1'));
    drink.addAttribute(XmppAttribute('name', 'Drink'));
    policy.addChild(drink);
    stanza.addChild(policy);

    final refs = parseSecurityLabelPolicyList(stanza);
    expect(refs, hasLength(2));
    expect(refs[0].id, '1.2.826.0.1.6726289.0.0');
    expect(refs[0].name, 'Food');
    expect(refs[1].id, '1.2.826.0.1.6726289.0.1');
    expect(refs[1].name, 'Drink');
  });

  test('parseSecurityLabelPolicyList skips items with no id', () {
    final stanza = IqStanza('p2', IqStanzaType.RESULT);
    final policy = XmppElement()..name = 'policy';
    policy.addAttribute(
      XmppAttribute('xmlns', securityLabelPolicyNamespace),
    );
    final noId = XmppElement()..name = 'item';
    noId.addAttribute(XmppAttribute('name', 'NoId'));
    policy.addChild(noId);
    stanza.addChild(policy);

    expect(parseSecurityLabelPolicyList(stanza), isEmpty);
  });

  test('parseSecurityLabelPolicyList returns empty for an error response', () {
    final stanza = IqStanza('p3', IqStanzaType.ERROR);
    expect(parseSecurityLabelPolicyList(stanza), isEmpty);
  });

  test(
    'parseSecurityLabelPolicyDocument extracts the raw SPIF document',
    () {
      final stanza = IqStanza('p4', IqStanzaType.RESULT);
      final policy = XmppElement()..name = 'policy';
      policy.addAttribute(
        XmppAttribute('xmlns', securityLabelPolicyNamespace),
      );
      policy.addAttribute(XmppAttribute('id', '1.2.826.0.1.6726289.0.0'));
      policy.addAttribute(XmppAttribute('name', 'Food'));
      final spif = XmppElement()..name = 'SPIF';
      final policyId = XmppElement()..name = 'securityPolicyId';
      policyId.addAttribute(XmppAttribute('name', 'Food'));
      policyId.addAttribute(XmppAttribute('id', '1.2.826.0.1.6726289.0.0'));
      spif.addChild(policyId);
      policy.addChild(spif);
      stanza.addChild(policy);

      final xml = parseSecurityLabelPolicyDocument(stanza);
      expect(xml, isNotNull);
      expect(xml, contains('<SPIF'));
      expect(xml, contains('securityPolicyId'));
    },
  );

  test(
    'parseSecurityLabelPolicyDocument returns null when no SPIF is present',
    () {
      final stanza = IqStanza('p5', IqStanzaType.RESULT);
      final policy = XmppElement()..name = 'policy';
      policy.addAttribute(
        XmppAttribute('xmlns', securityLabelPolicyNamespace),
      );
      stanza.addChild(policy);

      expect(parseSecurityLabelPolicyDocument(stanza), isNull);
    },
  );

  test(
    'parseSecurityLabelPolicyDocument returns null for an error response',
    () {
      final stanza = IqStanza('p6', IqStanzaType.ERROR);
      expect(parseSecurityLabelPolicyDocument(stanza), isNull);
    },
  );

  test(
    'a fetched SPIF document can actually be registered and used by spiffing',
    () {
      // Builds the same policy IQ shape a real server (the Spiffing Openfire
      // plugin's PolicyIqHandler) returns for a specific-policy request, and
      // verifies the extracted document round-trips through spiffing's own
      // parser into a usable Spif - end-to-end proof that what we extract
      // is exactly the raw SPIF text `Spif.fromXml` expects.
      final stanza = IqStanza('p7', IqStanzaType.RESULT);
      final policy = XmppElement()..name = 'policy';
      policy.addAttribute(
        XmppAttribute('xmlns', securityLabelPolicyNamespace),
      );
      policy.addAttribute(XmppAttribute('id', '1.2.3.4.5'));
      policy.addAttribute(XmppAttribute('name', 'TestPolicy'));
      final spif = XmppElement()..name = 'SPIF';
      final policyId = XmppElement()..name = 'securityPolicyId';
      policyId.addAttribute(XmppAttribute('name', 'TestPolicy'));
      policyId.addAttribute(XmppAttribute('id', '1.2.3.4.5'));
      spif.addChild(policyId);
      final classifications = XmppElement()..name = 'securityClassifications';
      final classification = XmppElement()..name = 'securityClassification';
      classification.addAttribute(XmppAttribute('lacv', '10'));
      classification.addAttribute(XmppAttribute('name', 'SECRET'));
      classification.addAttribute(XmppAttribute('hierarchy', '10'));
      classification.addAttribute(XmppAttribute('color', 'red'));
      classifications.addChild(classification);
      spif.addChild(classifications);
      policy.addChild(spif);
      stanza.addChild(policy);

      final xml = parseSecurityLabelPolicyDocument(stanza);
      expect(xml, isNotNull);

      final site = spiffing.Site();
      final parsedPolicy = site.load(xml!);
      expect(parsedPolicy.policyId, '1.2.3.4.5');
      final label = spiffing.Label.forClassification(parsedPolicy, 10);
      expect(label.classification.name, 'SECRET');
    },
  );
}
