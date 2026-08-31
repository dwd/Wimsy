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
import 'package:wimsy/login_link.dart';
import 'package:wimsy/main.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/models/room_entry.dart';
import 'package:wimsy/notifications/notification_service.dart';
import 'package:wimsy/storage/preferences_service.dart';
import 'package:wimsy/storage/storage_service.dart';
import 'package:wimsy/xmpp/jid_discovery.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

class _SuggestionXmppService extends XmppService {
  _SuggestionXmppService({this.unknownFallback = false});

  final bool unknownFallback;
  bool? lastExcludeRosterContacts;
  int suggestionCalls = 0;
  int discoveryCalls = 0;

  @override
  String? get currentUserBareJid => 'me@example.com';

  @override
  Future<List<JidSuggestion>> suggestLocalJids(
    String input, {
    Duration timeout = const Duration(seconds: 5),
    bool excludeRosterContacts = false,
  }) async {
    suggestionCalls++;
    lastExcludeRosterContacts = excludeRosterContacts;
    if (unknownFallback) {
      return const [
        JidSuggestion(
          jid: 'ali@example.com',
          kind: DiscoveredJidKind.person,
          isUnverified: true,
        ),
      ];
    }
    return const [
      JidSuggestion(
        jid: 'alice@example.com',
        kind: DiscoveredJidKind.person,
        name: 'Alice Example',
      ),
    ];
  }

  @override
  Future<JidDiscoveryResult> discoverJidKind(
    String jid, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    discoveryCalls++;
    return const JidDiscoveryResult(kind: DiscoveredJidKind.unknown);
  }
}

class _ConnectingXmppService extends XmppService {
  bool _connecting = true;
  bool disconnectCalled = false;

  @override
  bool get isConnecting => _connecting;

  @override
  Future<void> disconnect() async {
    disconnectCalled = true;
    _connecting = false;
    notifyListeners();
  }
}

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

  testWidgets('New Chat uses a full-screen dialog on compact displays', (
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
    expect(find.text('New Chat'), findsOneWidget);
    final dialogSize = tester.getSize(
      find.byKey(const Key('add-by-jid-fullscreen-dialog')),
    );
    expect(dialogSize, const Size(360, 640));
    expect(tester.takeException(), isNull);
  });

  testWidgets('New Chat uses a full-screen dialog on landscape phones', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(home: addByJidDialogForTesting(XmppService())),
    );

    expect(
      find.byKey(const Key('add-by-jid-fullscreen-dialog')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const Key('add-by-jid-fullscreen-dialog'))),
      const Size(915, 412),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('room invitation offers person search suggestions', (
    WidgetTester tester,
  ) async {
    final service = _SuggestionXmppService();
    await tester.pumpWidget(
      MaterialApp(home: roomInviteDialogForTesting(service)),
    );

    await tester.enterText(find.byType(TextField).first, 'ali');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('Alice Example'), findsOneWidget);
    expect(find.text('alice@example.com'), findsOneWidget);
    expect(service.lastExcludeRosterContacts, isFalse);
  });

  testWidgets('New Chat explicitly excludes roster contacts', (
    WidgetTester tester,
  ) async {
    final service = _SuggestionXmppService();
    await tester.pumpWidget(
      MaterialApp(home: addByJidDialogForTesting(service)),
    );

    await tester.enterText(find.byType(TextField).first, 'ali');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(service.lastExcludeRosterContacts, isTrue);
  });

  testWidgets('full addresses are probed without running a search', (
    WidgetTester tester,
  ) async {
    final service = _SuggestionXmppService();
    await tester.pumpWidget(
      MaterialApp(home: addByJidDialogForTesting(service)),
    );

    await tester.enterText(find.byType(TextField).first, 'alice@example.com');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();

    expect(service.suggestionCalls, 0);
    expect(service.discoveryCalls, 1);
  });

  testWidgets('Inviter probes full addresses without running a search', (
    WidgetTester tester,
  ) async {
    final service = _SuggestionXmppService();
    await tester.pumpWidget(
      MaterialApp(home: roomInviteDialogForTesting(service)),
    );

    await tester.enterText(find.byType(TextField).first, 'alice@example.com');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(service.suggestionCalls, 0);
    expect(service.discoveryCalls, 1);
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
  });

  testWidgets('unknown fallback suggestions use a question-mark icon', (
    WidgetTester tester,
  ) async {
    final service = _SuggestionXmppService(unknownFallback: true);
    await tester.pumpWidget(
      MaterialApp(home: addByJidDialogForTesting(service)),
    );

    await tester.enterText(find.byType(TextField).first, 'ali');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('ali@example.com'), findsOneWidget);
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
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

  testWidgets('landscape phone keeps the compact room chat layout', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.load();
    final room = RoomEntry(
      roomJid: 'lounge@conference.example.com',
      nick: 'tester',
      subject: 'A useful room subject',
      joined: true,
    );
    final service = XmppService()
      ..seedConnectedRoomForTesting(
        room,
        name: 'The Lounge',
        quicRtt: const [35, 42],
        quicLoss: const [0, 2],
        quicSent: const [50, 50],
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
    service.seedConnectedRoomForTesting(
      room,
      name: 'The Lounge',
      quicRtt: const [35, 42],
      quicLoss: const [0, 2],
      quicSent: const [50, 50],
    );
    await tester.pump();

    expect(find.byKey(const Key('chat-header-details-button')), findsOneWidget);
    expect(find.byTooltip('Invite to room'), findsOneWidget);
    expect(find.byTooltip('Leave room'), findsOneWidget);
    expect(find.text('Leave'), findsNothing);
    expect(find.byTooltip('Send file'), findsOneWidget);
    expect(find.byTooltip('Send photo'), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
    expect(find.textContaining('Signed in as'), findsNothing);
    expect(find.byTooltip('Set presence'), findsOneWidget);
    expect(find.byTooltip('RTT: 42ms'), findsOneWidget);
    expect(find.byTooltip('Loss over 2 seconds: 2%'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    final regularEditableState = tester.state<EditableTextState>(
      find.byType(EditableText),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const Key('landscape-fullscreen-composer')),
      findsOneWidget,
    );
    expect(find.text('The Lounge'), findsNothing);
    expect(find.byTooltip('Set presence'), findsNothing);
    expect(find.byTooltip('Send file'), findsOneWidget);
    expect(find.byTooltip('Send photo'), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.state<EditableTextState>(find.byType(EditableText)),
      same(regularEditableState),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
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

  testWidgets('Login link prefills account fields', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.load();
    final loginLink = ValueNotifier<LoginLinkValues?>(
      const LoginLinkValues(
        jid: 'tester@example.org',
        password: 'test-password',
        displayName: 'Test Person',
      ),
    );
    addTearDown(loginLink.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          service: XmppService(),
          storage: StorageService(),
          preferences: prefs,
          loginLink: loginLink,
        ),
      ),
    );
    await tester.pump();

    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'JID'))
          .controller
          ?.text,
      'tester@example.org',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Password'))
          .controller
          ?.text,
      'test-password',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Display name'))
          .controller
          ?.text,
      'Test Person',
    );
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

  testWidgets('unconfirmed outgoing message shows a pending clock', (
    WidgetTester tester,
  ) async {
    final message = ChatMessage(
      from: 'alice@example.com',
      to: 'bob@example.com',
      body: 'Still sending',
      timestamp: DateTime.utc(2026),
      outgoing: true,
      messageId: 'pending-message-test',
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
            inviteRoomJid: null,
            inviteRoomName: null,
            inviteAvatarBytes: null,
            inviteReason: null,
            onJoinInvite: null,
            selfReactionSenderId: 'alice@example.com',
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

    expect(find.byKey(const Key('pending-message-clock')), findsOneWidget);
    expect(find.bySemanticsLabel('Message sending'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('confirmed outgoing message replaces the pending clock', (
    WidgetTester tester,
  ) async {
    final message = ChatMessage(
      from: 'alice@example.com',
      to: 'bob@example.com',
      body: 'Sent',
      timestamp: DateTime.utc(2026),
      outgoing: true,
      messageId: 'acked-message-test',
      acked: true,
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
            inviteRoomJid: null,
            inviteRoomName: null,
            inviteAvatarBytes: null,
            inviteReason: null,
            onJoinInvite: null,
            selfReactionSenderId: 'alice@example.com',
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

    expect(find.byKey(const Key('pending-message-clock')), findsNothing);
    expect(find.byIcon(Icons.done), findsOneWidget);
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

  testWidgets('message menu can add a known room occupant to contacts', (
    WidgetTester tester,
  ) async {
    var added = false;
    final message = ChatMessage(
      from: 'Bob',
      to: 'room@conference.example.com',
      body: 'Hello from a room',
      timestamp: DateTime.utc(2026),
      outgoing: false,
      messageId: 'room-roster-menu-test',
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
            onAddToRoster: () => added = true,
            selfReactionSenderId: 'Alice',
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

    await tester.longPress(find.text('Hello from a room'));
    await tester.pumpAndSettle();
    expect(find.text('Add to contacts'), findsOneWidget);

    await tester.tap(find.text('Add to contacts'));
    expect(added, isTrue);
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

  testWidgets('Stop button cancels connecting and re-enables inputs', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.load();
    final service = _ConnectingXmppService();

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: service,
          builder: (context, _) => LoginScreen(
            service: service,
            storage: StorageService(),
            preferences: prefs,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('stop-connecting-button')), findsOneWidget);
    expect(
      tester.widget<TextField>(find.widgetWithText(TextField, 'JID')).enabled,
      isFalse,
    );

    await tester.ensureVisible(find.byKey(const Key('stop-connecting-button')));
    await tester.tap(find.byKey(const Key('stop-connecting-button')));
    await tester.pump();

    expect(service.disconnectCalled, isTrue);
    expect(find.byKey(const Key('stop-connecting-button')), findsNothing);
    expect(
      tester.widget<TextField>(find.widgetWithText(TextField, 'JID')).enabled,
      isTrue,
    );
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

    await tester.ensureVisible(
      find.byKey(const Key('manual-transport-selector')),
    );
    await tester.tap(find.byKey(const Key('manual-transport-selector')));
    await tester.pumpAndSettle();
    expect(find.text('StartTLS'), findsWidgets);
    expect(find.text('Direct TLS'), findsOneWidget);
    expect(find.text('QUIC'), findsOneWidget);
  });
}
