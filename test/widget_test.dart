// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wimsy/login_screen.dart';
import 'package:wimsy/main.dart';
import 'package:wimsy/storage/preferences_service.dart';
import 'package:wimsy/storage/storage_service.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.load();
    await tester.pumpWidget(WimsyApp(preferences: prefs));

    expect(find.byType(WimsyApp), findsOneWidget);
  });

  testWidgets('Login form builds without framework exceptions', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.load();

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          service: XmppService(),
          storage: StorageService(),
          preferences: prefs,
        ),
      ),
    );

    expect(find.text('Remember password on this device'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
