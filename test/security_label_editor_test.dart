import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spiffing/spiffing.dart' as spiffing;
import 'package:wimsy/main.dart';
import 'package:wimsy/xmpp/security_label_policy.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

String _policyXml({
  required String id,
  required String name,
  required String classificationName,
  int lacv = 10,
}) {
  return '''
<SPIF xmlns="http://www.xmlspif.org/spif">
  <securityPolicyId id="$id" name="$name"/>
  <securityClassifications>
    <securityClassification lacv="$lacv" name="$classificationName" hierarchy="$lacv"/>
  </securityClassifications>
</SPIF>
''';
}

void main() {
  late spiffing.Spif spif1;
  late spiffing.Spif spif2;
  late SecurityLabelPolicyOption policyOption1;
  late SecurityLabelPolicyOption policyOption2;

  setUp(() {
    final site = spiffing.Site();
    spif1 = site.load(
      _policyXml(
        id: '1.2.826.0.1.6726289.0.0',
        name: 'Policy One',
        classificationName: 'CONFIDENTIAL',
        lacv: 1,
      ),
    );
    spif2 = site.load(
      _policyXml(
        id: '1.2.826.0.1.6726289.0.1',
        name: 'Policy Two',
        classificationName: 'SECRET',
        lacv: 2,
      ),
    );
    policyOption1 = SecurityLabelPolicyOption(
      ref: const SecurityLabelPolicyRef(
        id: '1.2.826.0.1.6726289.0.0',
        name: 'Policy One',
      ),
      spif: spif1,
    );
    policyOption2 = SecurityLabelPolicyOption(
      ref: const SecurityLabelPolicyRef(
        id: '1.2.826.0.1.6726289.0.1',
        name: 'Policy Two',
      ),
      spif: spif2,
    );
  });

  group('SecurityLabelPolicyOption', () {
    test('displayName prefers ref name, then spif name, then id', () {
      final opt1 = SecurityLabelPolicyOption(
        ref: const SecurityLabelPolicyRef(id: '1.2.3', name: 'Ref Name'),
        spif: spif1,
      );
      expect(opt1.displayName, 'Ref Name');

      final opt2 = SecurityLabelPolicyOption(
        ref: const SecurityLabelPolicyRef(id: '1.2.3', name: '  '),
        spif: spif1,
      );
      expect(opt2.displayName, 'Policy One');

      final emptySpifSite = spiffing.Site();
      final emptySpif = emptySpifSite.load(
        _policyXml(
          id: '1.2.3.4',
          name: '',
          classificationName: 'PUBLIC',
        ),
      );
      final opt3 = SecurityLabelPolicyOption(
        ref: const SecurityLabelPolicyRef(id: '1.2.3.4', name: ''),
        spif: emptySpif,
      );
      expect(opt3.displayName, '1.2.3.4');
    });
  });

  group('SecurityLabelEditorScreen', () {
    testWidgets(
      'does not show policy selector dropdown when only one policy is available',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SecurityLabelEditorScreen(policies: [policyOption1]),
          ),
        );

        expect(find.byKey(const Key('security-policy-selector')), findsNothing);
        expect(find.text('CONFIDENTIAL'), findsOneWidget);
      },
    );

    testWidgets(
      'shows policy selector dropdown when multiple policies are available',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SecurityLabelEditorScreen(
              policies: [policyOption1, policyOption2],
            ),
          ),
        );

        expect(find.byKey(const Key('security-policy-selector')), findsOneWidget);
        expect(find.text('Policy One'), findsWidgets);
        expect(find.text('CONFIDENTIAL'), findsOneWidget);
      },
    );

    testWidgets(
      'selecting a different policy switches the label editor and builds the chosen policy label on apply',
      (WidgetTester tester) async {
        XmppElement? appliedResult;

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    appliedResult = await Navigator.of(context).push<XmppElement>(
                      MaterialPageRoute(
                        builder: (_) => SecurityLabelEditorScreen(
                          policies: [policyOption1, policyOption2],
                        ),
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('security-policy-selector')), findsOneWidget);
        expect(find.text('CONFIDENTIAL'), findsOneWidget);

        // Tap the policy dropdown and select Policy Two
        await tester.tap(find.byKey(const Key('security-policy-selector')));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Policy Two').last);
        await tester.pumpAndSettle();

        // Label editor should now show Policy Two's classification
        expect(find.text('SECRET'), findsOneWidget);

        // Tap Apply
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();

        expect(appliedResult, isNotNull);
        expect(appliedResult!.name, 'securitylabel');
        final displayMarking = appliedResult!.children.firstWhere(
          (c) => c.name == 'displaymarking',
        );
        expect(displayMarking.textValue, 'Policy Two SECRET');
      },
    );

    testWidgets(
      'initialPolicyId selects the requested policy by default',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SecurityLabelEditorScreen(
              policies: [policyOption1, policyOption2],
              initialPolicyId: '1.2.826.0.1.6726289.0.1',
            ),
          ),
        );

        expect(find.text('SECRET'), findsOneWidget);
      },
    );
  });
}
