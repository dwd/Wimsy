import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wimsy/keepalive_settings_screen.dart';
import 'package:wimsy/storage/preferences_service.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

void main() {
  Future<PreferencesService> loadPrefs() async {
    SharedPreferences.setMockInitialValues({});
    return PreferencesService.load();
  }

  final saveButtonFinder = find.byKey(const ValueKey('saveAndApplyButton'));
  final pingFieldFinder = find.byKey(
    const ValueKey('durationField_Ping interval (foreground)'),
  );

  // The screen's body is a single vertical `ListView`, but each
  // `_DurationField` contains a single-line `TextField`, and every
  // `TextField` builds its own internal (horizontal) `Scrollable` for text
  // scrolling. That means `find.byType(Scrollable)` - the default used by
  // `scrollUntilVisible` - matches many widgets on this screen, not just the
  // list's own `Scrollable`, which makes it throw a "too many elements"
  // error. Disambiguate by only matching the vertical `Scrollable`, i.e. the
  // one backing the outer `ListView`.
  final verticalScrollableFinder = find.byWidgetPredicate(
    (widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down,
  );

  testWidgets(
    'Save & apply is disabled until a duration field is edited, then enabled',
    (WidgetTester tester) async {
      final prefs = await loadPrefs();
      final service = XmppService();

      await tester.pumpWidget(
        MaterialApp(
          home: KeepaliveSettingsScreen(service: service, preferences: prefs),
        ),
      );

      // Initially unchanged, so the button must be disabled.
      await tester.scrollUntilVisible(
        saveButtonFinder,
        200,
        scrollable: verticalScrollableFinder,
      );
      var saveButton = tester.widget<FilledButton>(saveButtonFinder);
      expect(saveButton.onPressed, isNull);

      // Editing the foreground ping interval field (without submitting, i.e.
      // without pressing an on-screen keyboard "done"/enter key) must be
      // enough to mark the form dirty and enable the button. This is the
      // regression check: previously only `onSubmitted` updated the state,
      // so on numeric keyboards without a submit key the button never
      // became enabled.
      await tester.scrollUntilVisible(
        pingFieldFinder,
        -200,
        scrollable: verticalScrollableFinder,
      );
      await tester.enterText(pingFieldFinder, '10');
      await tester.pump();

      await tester.scrollUntilVisible(
        saveButtonFinder,
        200,
        scrollable: verticalScrollableFinder,
      );
      saveButton = tester.widget<FilledButton>(saveButtonFinder);
      expect(saveButton.onPressed, isNotNull);
    },
  );

  testWidgets(
    'Save & apply persists the edited foreground ping interval',
    (WidgetTester tester) async {
      final prefs = await loadPrefs();
      final service = XmppService();

      await tester.pumpWidget(
        MaterialApp(
          home: KeepaliveSettingsScreen(service: service, preferences: prefs),
        ),
      );

      await tester.scrollUntilVisible(
        pingFieldFinder,
        200,
        scrollable: verticalScrollableFinder,
      );
      await tester.enterText(pingFieldFinder, '10');
      await tester.pump();

      await tester.scrollUntilVisible(
        saveButtonFinder,
        200,
        scrollable: verticalScrollableFinder,
      );
      await tester.tap(saveButtonFinder);
      await tester.pumpAndSettle();

      expect(
        prefs.keepaliveTuning.pingIntervalForeground,
        const Duration(seconds: 10),
      );
      expect(
        service.keepaliveTuning.pingIntervalForeground,
        const Duration(seconds: 10),
      );

      // After saving, the button must become disabled again.
      final saveButton = tester.widget<FilledButton>(saveButtonFinder);
      expect(saveButton.onPressed, isNull);
    },
  );

  testWidgets('Reset to defaults marks the form dirty', (
    WidgetTester tester,
  ) async {
    final prefs = await loadPrefs();
    final service = XmppService();

    await tester.pumpWidget(
      MaterialApp(
        home: KeepaliveSettingsScreen(service: service, preferences: prefs),
      ),
    );

    await tester.tap(find.byTooltip('Reset to defaults'));
    await tester.pump();

    await tester.scrollUntilVisible(
      saveButtonFinder,
      200,
      scrollable: verticalScrollableFinder,
    );
    final saveButton = tester.widget<FilledButton>(saveButtonFinder);
    expect(saveButton.onPressed, isNotNull);
  });
}
