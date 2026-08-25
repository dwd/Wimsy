// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/login_screen.dart';
import 'package:wimsy/main.dart';
import 'package:wimsy/models/chat_message.dart';
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
    expect(find.byKey(const Key('connection-log-panel')), findsOneWidget);
    expect(
      find.text('Connection details will appear here after you tap Connect.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Message composer requests normal sentence text input', (
    WidgetTester tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageComposerTextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: false,
            enabled: true,
            onChanged: (_) {},
            onSubmitted: (_) {},
          ),
        ),
      ),
    );

    final composer = tester.widget<TextField>(
      find.byKey(const Key('message-composer-input')),
    );
    expect(composer.keyboardType, TextInputType.text);
    expect(composer.textCapitalization, TextCapitalization.sentences);
    expect(composer.autocorrect, isTrue);
    expect(composer.enableSuggestions, isTrue);
  });

  testWidgets('long pressing a message opens its complete action menu', (
    WidgetTester tester,
  ) async {
    var replied = false;
    late StateSetter rebuild;
    final message = ChatMessage(
      from: 'bob@example.com',
      to: 'alice@example.com',
      body: 'A message with actions',
      timestamp: DateTime.utc(2026),
      outgoing: false,
      messageId: 'long-press-menu-test',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: MessageBubble(
                message: message,
                senderName: 'Bob',
                timestamp: '12:00',
                avatarBytes: null,
                replySenderName: null,
                replyBody: null,
                onReplyTargetTap: null,
                inviteRoomJid: null,
                inviteRoomName: null,
                inviteAvatarBytes: null,
                inviteReason: null,
                onJoinInvite: null,
                selfReactionSenderId: 'alice@example.com',
                recentReactionOptions: const ['👍'],
                onReact: (_) {},
                onEdit: null,
                onReply: () => replied = true,
                onAcceptFile: null,
                onDeclineFile: null,
                onFallbackUpload: null,
              ),
            );
          },
        ),
      ),
    );

    await tester.longPress(find.text('A message with actions'));
    await tester.pumpAndSettle();

    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Add reaction'), findsOneWidget);
    expect(find.text('View XML'), findsOneWidget);

    rebuild(() {});
    await tester.pump();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(replied, isTrue);

    await tester.longPress(find.text('A message with actions'));
    await tester.pumpAndSettle();
    rebuild(() {});
    await tester.pump();
    await tester.tap(find.text('Add reaction'));
    await tester.pumpAndSettle();
    expect(find.text('👍'), findsOneWidget);
  });

  testWidgets('Login screen displays and clears live connection logs', (
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

    Log.i('LoginTest', 'Negotiating secure connection');
    await tester.pump();

    expect(
      find.textContaining('Negotiating secure connection'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Clear'));
    await tester.tap(find.text('Clear'));
    await tester.pump();

    expect(find.textContaining('Negotiating secure connection'), findsNothing);
  });

  testWidgets('Manual connection offers each native transport protocol', (
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

    await tester.tap(find.text('Manual connection'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manual-transport-selector')), findsOneWidget);

    await tester.tap(find.byKey(const Key('manual-transport-selector')));
    await tester.pumpAndSettle();
    expect(find.text('StartTLS'), findsWidgets);
    expect(find.text('Direct TLS'), findsOneWidget);
    expect(find.text('QUIC'), findsOneWidget);
  });
}
