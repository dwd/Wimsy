// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/login_screen.dart';
import 'package:wimsy/main.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/models/room_entry.dart';
import 'package:wimsy/notifications/notification_service.dart';
import 'package:wimsy/storage/preferences_service.dart';
import 'package:wimsy/storage/storage_service.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

void main() {
  test('window title includes the active bare JID', () {
    expect(windowTitleFor(null), 'Wimsy');
    expect(windowTitleFor(''), 'Wimsy');
    expect(
      windowTitleFor('dave.cridland@example.com'),
      'Wimsy - dave.cridland@example.com',
    );
  });

  testWidgets('App launches smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.load();
    await tester.pumpWidget(WimsyApp(preferences: prefs));

    expect(find.byType(WimsyApp), findsOneWidget);
  });

  testWidgets('PIN setup scrolls on a small portrait display', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.load();
    await tester.pumpWidget(MaterialApp(home: pinSetupScreenForTesting(prefs)));
    await tester.pump();

    expect(find.text('Set a PIN'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Set a PIN'),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -200),
    );
    await tester.pump();
    expect(find.text('Continue without PIN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Add by JID uses a full-screen dialog on compact displays', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => addByJidDialogForTesting(XmppService()),
            ),
            child: const Text('Open dialog'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('add-by-jid-fullscreen-dialog')),
      findsOneWidget,
    );
    final dialogSize = tester.getSize(
      find.byKey(const Key('add-by-jid-fullscreen-dialog')),
    );
    expect(dialogSize, const Size(360, 640));
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait room chat folds details and keeps composer actions', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.load();
    final service = XmppService()
      ..seedConnectedRoomForTesting(
        RoomEntry(
          roomJid: 'lounge@conference.example.com',
          nick: 'tester',
          subject: 'A useful room subject',
          joined: true,
          occupantCount: 12,
        ),
        name: 'The Lounge',
      );

    await tester.pumpWidget(
      MaterialApp(
        home: WimsyHome(
          service: service,
          storage: StorageService(),
          notifications: NotificationService(),
          preferences: prefs,
        ),
      ),
    );
    await tester.pump();
    // WimsyHome seeds its initially empty storage asynchronously; restore the
    // in-memory room fixture after that first frame completes.
    service.seedConnectedRoomForTesting(
      RoomEntry(
        roomJid: 'lounge@conference.example.com',
        nick: 'tester',
        subject: 'A useful room subject',
        joined: true,
        occupantCount: 12,
      ),
      name: 'The Lounge',
    );
    await tester.pump();

    expect(find.text('The Lounge'), findsOneWidget);
    expect(
      find.text('A useful room subject', findRichText: true),
      findsNothing,
    );
    expect(find.byTooltip('Invite to room'), findsOneWidget);
    expect(find.byTooltip('Leave room'), findsOneWidget);
    expect(find.text('Leave'), findsNothing);
    expect(find.byTooltip('Send file'), findsOneWidget);
    expect(find.byTooltip('Send photo'), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-header-details-button')));
    await tester.pump();
    expect(find.text('lounge@conference.example.com'), findsOneWidget);
    expect(
      find.text('A useful room subject', findRichText: true),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
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

  testWidgets('long-press menu waits for the recognizing touch to end', (
    WidgetTester tester,
  ) async {
    final message = ChatMessage(
      from: 'bob@example.com',
      to: 'alice@example.com',
      body: 'Hold this message',
      timestamp: DateTime.utc(2026),
      outgoing: false,
      messageId: 'held-menu-test',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
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
            recentReactionOptions: const [],
            onReact: (_) {},
            onEdit: null,
            onReply: () {},
            onAcceptFile: null,
            onDeclineFile: null,
            onFallbackUpload: null,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Hold this message')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(find.text('Reply'), findsNothing);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
  });

  testWidgets('bodyless room invitation renders its card and join action', (
    WidgetTester tester,
  ) async {
    var joined = false;
    final message = ChatMessage(
      from: 'juliet@example.com',
      to: 'romeo@example.com',
      body: '',
      timestamp: DateTime.utc(2026),
      outgoing: false,
      messageId: 'invite-card-test',
      inviteRoomJid: 'room@example.com',
      inviteReason: 'Join the discussion',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            senderName: 'Juliet',
            timestamp: '12:00',
            avatarBytes: null,
            replySenderName: null,
            replyBody: null,
            onReplyTargetTap: null,
            inviteRoomJid: 'room@example.com',
            inviteRoomName: 'Discussion room',
            inviteAvatarBytes: null,
            inviteReason: 'Join the discussion',
            onJoinInvite: () => joined = true,
            selfReactionSenderId: 'romeo@example.com',
            recentReactionOptions: const [],
            onReact: null,
            onEdit: null,
            onReply: null,
            onAcceptFile: null,
            onDeclineFile: null,
            onFallbackUpload: null,
          ),
        ),
      ),
    );

    expect(find.text('Discussion room'), findsOneWidget);
    expect(find.text('Join the discussion'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget);

    await tester.tap(find.text('Join'));
    expect(joined, isTrue);
  });

  testWidgets('sent room invitation renders a non-interactive card', (
    WidgetTester tester,
  ) async {
    final message = ChatMessage(
      from: 'romeo@example.com',
      to: 'juliet@example.com',
      body: '',
      timestamp: DateTime.utc(2026),
      outgoing: true,
      messageId: 'sent-invite-card-test',
      inviteRoomJid: 'room@example.com',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            senderName: 'You',
            timestamp: '12:00',
            avatarBytes: null,
            replySenderName: null,
            replyBody: null,
            onReplyTargetTap: null,
            inviteRoomJid: 'room@example.com',
            inviteRoomName: 'Discussion room',
            inviteAvatarBytes: null,
            inviteReason: null,
            onJoinInvite: null,
            selfReactionSenderId: 'romeo@example.com',
            recentReactionOptions: const [],
            onReact: null,
            onEdit: null,
            onReply: null,
            onAcceptFile: null,
            onDeclineFile: null,
            onFallbackUpload: null,
          ),
        ),
      ),
    );

    expect(find.text('Discussion room'), findsOneWidget);
    expect(find.text('room@example.com'), findsOneWidget);
    expect(find.text('Join'), findsNothing);
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
