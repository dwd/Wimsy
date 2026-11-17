import 'package:cupertino_ui/cupertino_ui.dart';
// Used only to type `_LegacySimpleMaterialLocalizationsDelegate` below
// against the legacy `MaterialLocalizations` type that the legacy `RawChip`
// (inside `flutter_spiffing`'s `ChoiceChip`) actually looks up -
// `package:material_ui` defines its own, distinct `MaterialLocalizations`
// class, which would not satisfy that lookup.
// ignore: deprecated_member_use
import 'package:flutter/material.dart' as legacy;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_spiffing/flutter_spiffing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spiffing/spiffing.dart' as spiffing;
import 'package:wimsy/main.dart';
import 'package:wimsy/widgets/legacy_material_bridge.dart';
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

class _SimpleMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const _SimpleMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      DefaultMaterialLocalizations.load(locale);

  @override
  bool shouldReload(_SimpleMaterialLocalizationsDelegate old) => false;
}

class _SimpleCupertinoLocalizationsDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const _SimpleCupertinoLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CupertinoLocalizations> load(Locale locale) =>
      DefaultCupertinoLocalizations.load(locale);

  @override
  bool shouldReload(_SimpleCupertinoLocalizationsDelegate old) => false;
}

// Legacy-typed counterpart of `_SimpleMaterialLocalizationsDelegate` above:
// `package:material_ui` defines its own, distinct `MaterialLocalizations`
// class, so this is needed wherever a legacy widget (e.g. `RawChip` inside
// `flutter_spiffing`'s `ChoiceChip`, reached via [LegacyMaterialBridge])
// looks up the legacy type instead.
class _LegacySimpleMaterialLocalizationsDelegate
    extends LocalizationsDelegate<legacy.MaterialLocalizations> {
  const _LegacySimpleMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<legacy.MaterialLocalizations> load(Locale locale) =>
      legacy.DefaultMaterialLocalizations.load(locale);

  @override
  bool shouldReload(_LegacySimpleMaterialLocalizationsDelegate old) => false;
}


class _SimpleWidgetsLocalizationsDelegate
    extends LocalizationsDelegate<WidgetsLocalizations> {
  const _SimpleWidgetsLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<WidgetsLocalizations> load(Locale locale) =>
      DefaultWidgetsLocalizations.load(locale);

  @override
  bool shouldReload(_SimpleWidgetsLocalizationsDelegate old) => false;
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
            builder: (context, child) => LegacyMaterialBridge(child: child!),
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
            builder: (context, child) => LegacyMaterialBridge(child: child!),
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
            builder: (context, child) => LegacyMaterialBridge(child: child!),
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
            builder: (context, child) => LegacyMaterialBridge(child: child!),
            home: SecurityLabelEditorScreen(
              policies: [policyOption1, policyOption2],
              initialPolicyId: '1.2.826.0.1.6726289.0.1',
            ),
          ),
        );

        expect(find.text('SECRET'), findsOneWidget);
      },
    );

    testWidgets(
      'populates langTag from locale on LabelEditor',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => LegacyMaterialBridge(child: child!),
            localizationsDelegates: const [
              _SimpleMaterialLocalizationsDelegate(),
              _SimpleCupertinoLocalizationsDelegate(),
              _SimpleWidgetsLocalizationsDelegate(),
            ],
            supportedLocales: const [Locale('fr', 'FR'), Locale('en', 'US')],
            locale: const Locale('fr', 'FR'),
            home: SecurityLabelEditorScreen(policies: [policyOption1]),
          ),
        );

        final editor = tester.widget<LabelEditor>(find.byType(LabelEditor));
        expect(editor.langTag, 'fr-FR');
      },
    );

    testWidgets(
      'populates simple language code as langTag on LabelEditor',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => LegacyMaterialBridge(child: child!),
            localizationsDelegates: const [
              _SimpleMaterialLocalizationsDelegate(),
              _SimpleCupertinoLocalizationsDelegate(),
              _SimpleWidgetsLocalizationsDelegate(),
            ],
            supportedLocales: const [Locale('de'), Locale('en', 'US')],
            locale: const Locale('de'),
            home: SecurityLabelEditorScreen(policies: [policyOption1]),
          ),
        );

        final editor = tester.widget<LabelEditor>(find.byType(LabelEditor));
        expect(editor.langTag, 'de');
      },
    );

    testWidgets(
      'falls back to "en" when Localizations widget is not present',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Localizations(
              locale: const Locale('und'),
              delegates: const [
                _SimpleMaterialLocalizationsDelegate(),
                _LegacySimpleMaterialLocalizationsDelegate(),
                _SimpleWidgetsLocalizationsDelegate(),
              ],
              child: MediaQuery(
                data: const MediaQueryData(),
                child: LegacyMaterialBridge(
                  delegates: const [],
                  child: SecurityLabelEditorScreen(policies: [policyOption1]),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final editor = tester.widget<LabelEditor>(find.byType(LabelEditor));
        expect(editor.langTag, 'en');
      },
    );

    testWidgets(
      'falls back to "en" when ambient locale is "und"',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Localizations(
              locale: const Locale('und'),
              delegates: const [
                _SimpleMaterialLocalizationsDelegate(),
                _LegacySimpleMaterialLocalizationsDelegate(),
                _SimpleWidgetsLocalizationsDelegate(),
              ],
              child: MediaQuery(
                data: const MediaQueryData(),
                child: LegacyMaterialBridge(
                  delegates: const [],
                  child: SecurityLabelEditorScreen(policies: [policyOption1]),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final editor = tester.widget<LabelEditor>(find.byType(LabelEditor));
        expect(editor.langTag, 'en');
      },
    );
  });
}
