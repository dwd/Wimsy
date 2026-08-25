import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:xmpp_stone/xmpp_stone.dart';
import 'package:url_launcher/url_launcher.dart';

import 'av/call_session.dart';
import 'keepalive_settings_screen.dart';
import 'login_screen.dart';
import 'models/chat_message.dart';
import 'models/contact_entry.dart';
import 'models/muc_notify_settings.dart';
import 'models/room_entry.dart';
import 'notifications/notification_service.dart';
import 'storage/preferences_service.dart';
import 'storage/storage_service.dart';
import 'xmpp/jid_discovery.dart';
import 'xmpp/vcard_utils.dart';
import 'xmpp/xmpp_service.dart';
import 'background/foreground_task_handler.dart';
import 'utils/graph_statistics.dart';
import 'utils/xep0392_color.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

const List<String> _defaultReactionOptions = [
  '👍',
  '❤️',
  '😂',
  '😮',
  '😢',
  '👎',
];

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(WimsyForegroundTaskHandler());
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  assert(() {
    Log.logLevel = LogLevel.VERBOSE;
    Log.logXmpp = true;
    return true;
  }());
  final prefs = await PreferencesService.load();
  await _startApp(sentryEnabled: prefs.sentryOptIn, preferences: prefs);
}

const bool _isFlutterTest = bool.fromEnvironment('FLUTTER_TEST');

Future<void> _startApp({
  required bool sentryEnabled,
  required PreferencesService preferences,
}) async {
  if (sentryEnabled) {
    await SentryFlutter.init(
      (options) {
        options.dsn =
            'https://7d58998fe2d0e488aa5f11020778c9f6@sentry.cridland.io/8';
        options.tracesSampleRate = 1.0;
      },
      appRunner: () {
        Connection.errorReporter = (error, stackTrace) {
          Sentry.captureException(error, stackTrace: stackTrace);
        };
        runApp(SentryWidget(child: WimsyApp(preferences: preferences)));
      },
    );
    return;
  }
  Connection.errorReporter = null;
  runApp(WimsyApp(preferences: preferences));
}

Future<void> _enableSentryAndRestart() async {
  if (Sentry.isEnabled) {
    return;
  }
  final prefs = await PreferencesService.load();
  await _startApp(sentryEnabled: true, preferences: prefs);
}

Future<void> _restartWithoutSentry() async {
  if (!Sentry.isEnabled) {
    return;
  }
  final prefs = await PreferencesService.load();
  await _startApp(sentryEnabled: false, preferences: prefs);
}

class WimsyApp extends StatefulWidget {
  const WimsyApp({super.key, required this.preferences});

  final PreferencesService preferences;

  @override
  State<WimsyApp> createState() => _WimsyAppState();
}

class _WimsyAppState extends State<WimsyApp> with WidgetsBindingObserver {
  final XmppService _service = XmppService();
  final StorageService _storage = StorageService();
  final NotificationService _notifications = NotificationService();
  final Connectivity _connectivity = Connectivity();
  PreferencesService get _preferences => widget.preferences;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _appIsForeground = true;
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!_isFlutterTest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notifications.initialize(onEvent: _handleNotificationEvent);
      });
      _service.setIncomingMessageHandler(_handleIncomingMessage);
      _service.setIncomingRoomMessageHandler(_handleIncomingRoomMessage);
      _service.setIncomingCallHandler(_handleIncomingCallSession);
      _service.setCallSessionEndedHandler(_handleCallSessionEnded);
      if (!kIsWeb && Platform.isAndroid) {
        _startAndroidForegroundService();
      }
      // Subscribe to connectivity changes on all non-web IO platforms so that
      // iOS (Wi-Fi ↔ cellular) also triggers QUIC migration / reconnect.
      if (!kIsWeb) {
        _connectivitySubscription = _connectivity.onConnectivityChanged.listen((
          results,
        ) {
          final online = results.any(
            (result) => result != ConnectivityResult.none,
          );
          _service.handleConnectivityChange(online);
        });
      }
    }
    _initFuture = _storage.initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    _service.setIncomingMessageHandler(null);
    _service.setIncomingRoomMessageHandler(null);
    _service.setIncomingCallHandler(null);
    _service.setCallSessionEndedHandler(null);
    _service.dispose();
    _storage.lock();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsForeground = state == AppLifecycleState.resumed;
    if (!kIsWeb && Platform.isAndroid) {
      _service.setBackgroundMode(state != AppLifecycleState.resumed);
    }
  }

  void _handleIncomingMessage(String bareJid, ChatMessage message) {
    final shouldNotify = _shouldNotifyFor(bareJid);
    debugPrint(
      'NewMsg[DM] _handleIncomingMessage: chat=$bareJid '
      'messageId=${message.messageId} timestamp=${message.timestamp} '
      'appIsForeground=$_appIsForeground '
      'activeChat=${_service.activeChatBareJid} '
      'shouldNotify=$shouldNotify',
    );
    if (!shouldNotify) {
      debugPrint(
        'NewMsg[DM] _handleIncomingMessage: suppressed by _shouldNotifyFor '
        'chat=$bareJid',
      );
      return;
    }
    final unseen = _service.isMessageUnseen(bareJid, message);
    if (!unseen) {
      debugPrint(
        'NewMsg[DM] _handleIncomingMessage: suppressed by isMessageUnseen '
        'chat=$bareJid messageId=${message.messageId}',
      );
      return;
    }
    debugPrint(
      'NewMsg[DM] _handleIncomingMessage: showing notification for '
      'chat=$bareJid messageId=${message.messageId}',
    );
    final title = _service.displayNameFor(bareJid);
    _notifications.showMessage(
      id: bareJid.hashCode.abs() % (1 << 31),
      title: title,
      body: message.body,
      chatJid: bareJid,
      tag: bareJid,
    );
  }

  void _handleIncomingRoomMessage(String roomJid, ChatMessage message) {
    final shouldNotify = _shouldNotifyFor(roomJid);
    debugPrint(
      'NewMsg[MUC] _handleIncomingRoomMessage: chat=$roomJid '
      'messageId=${message.messageId} timestamp=${message.timestamp} '
      'appIsForeground=$_appIsForeground '
      'activeChat=${_service.activeChatBareJid} '
      'shouldNotify=$shouldNotify',
    );
    if (!shouldNotify) {
      debugPrint(
        'NewMsg[MUC] _handleIncomingRoomMessage: suppressed by _shouldNotifyFor '
        'chat=$roomJid',
      );
      return;
    }
    final shouldNotifyForContent = _service.shouldNotifyForRoomContent(
      roomJid,
      message,
    );
    if (!shouldNotifyForContent) {
      debugPrint(
        'NewMsg[MUC] _handleIncomingRoomMessage: suppressed by '
        'shouldNotifyForRoomContent (mode/mention/after-own settings) '
        'chat=$roomJid',
      );
      return;
    }
    final unseen = _service.isMessageUnseen(roomJid, message);
    if (!unseen) {
      debugPrint(
        'NewMsg[MUC] _handleIncomingRoomMessage: suppressed by isMessageUnseen '
        'chat=$roomJid messageId=${message.messageId}',
      );
      return;
    }
    debugPrint(
      'NewMsg[MUC] _handleIncomingRoomMessage: showing notification for '
      'chat=$roomJid messageId=${message.messageId}',
    );
    final title = '$roomJid • ${message.from}';
    _notifications.showMessage(
      id: roomJid.hashCode.abs() % (1 << 31),
      title: title,
      body: message.body,
      chatJid: roomJid,
      tag: roomJid,
    );
  }

  void _handleIncomingCallSession(CallSession session) {
    if (kIsWeb || !Platform.isAndroid) {
      return;
    }
    if (session.direction != CallDirection.incoming ||
        session.state != CallState.ringing) {
      return;
    }
    unawaited(
      _notifications.showIncomingCall(
        sid: session.sid,
        peerJid: session.peerBareJid,
        video: session.video,
      ),
    );
  }

  void _handleCallSessionEnded(CallSession session) {
    if (kIsWeb || !Platform.isAndroid) {
      return;
    }
    unawaited(_notifications.cancelIncomingCall(session.sid));
  }

  void _handleNotificationEvent(NotificationEvent event) {
    final payload = event.payload;
    if (payload == null || payload.isEmpty) {
      return;
    }
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      data = decoded;
    } catch (_) {
      return;
    }
    final type = data['type']?.toString() ?? '';
    final chatJid = data['chatJid']?.toString() ?? '';
    final sid = data['sid']?.toString() ?? '';
    final actionId = event.actionId ?? '';

    if (type == 'call') {
      if (actionId == 'call_decline') {
        unawaited(_service.declineCallBySid(sid));
        unawaited(_notifications.cancelIncomingCall(sid));
        return;
      }
      if (actionId == 'call_answer') {
        unawaited(_service.acceptCallBySid(sid));
        unawaited(_notifications.cancelIncomingCall(sid));
      }
    }
    if (chatJid.isNotEmpty) {
      _service.selectChat(chatJid);
      unawaited(_notifications.cancelMessagesForTag(chatJid));
    }
  }

  bool _shouldNotifyFor(String bareJid) {
    if (kIsWeb) {
      return false;
    }
    if (!_appIsForeground) {
      return true;
    }
    final activeChat = _service.activeChatBareJid;
    if (activeChat == null) {
      return true;
    }
    return activeChat != bareJid;
  }

  Future<void> _startAndroidForegroundService() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'wimsy_service',
        channelName: 'Wimsy Background Service',
        channelDescription: 'Keeps Wimsy connected in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(300000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    final running = await FlutterForegroundTask.isRunningService;
    if (!running) {
      await FlutterForegroundTask.startService(
        notificationTitle: 'Wimsy is running',
        notificationText: 'Keeping your XMPP session connected.',
        callback: startCallback,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = const ColorScheme(
      brightness: Brightness.light,
      primary: Color(0xFF1F6F8B),
      onPrimary: Color(0xFFFDFCF8),
      secondary: Color(0xFFEE6C4D),
      onSecondary: Color(0xFFFDFCF8),
      surface: Color(0xFFF1EADF),
      onSurface: Color(0xFF1B1A17),
      error: Color(0xFFB00020),
      onError: Color(0xFFFDFCF8),
    );

    return WithForegroundTask(
      child: Listener(
        onPointerDown: (_) => _service.noteUserActivity(),
        onPointerSignal: (_) => _service.noteUserActivity(),
        child: MaterialApp(
          title: 'Wimsy',
          theme: ThemeData(
            colorScheme: colorScheme,
            useMaterial3: true,
            scaffoldBackgroundColor: colorScheme.surface,
            fontFamily: 'Droid Sans',
            fontFamilyFallback: const ['Roboto', 'Arial', 'sans-serif'],
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: const Color(0xFFFDFBF6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colorScheme.outline),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colorScheme.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
          home: FutureBuilder<void>(
            future: _initFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const _SplashScreen();
              }
              return _Gatekeeper(
                service: _service,
                storage: _storage,
                notifications: _notifications,
                preferences: _preferences,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Gatekeeper extends StatefulWidget {
  const _Gatekeeper({
    required this.service,
    required this.storage,
    required this.notifications,
    required this.preferences,
  });

  final XmppService service;
  final StorageService storage;
  final NotificationService notifications;
  final PreferencesService preferences;

  @override
  State<_Gatekeeper> createState() => _GatekeeperState();
}

class _GatekeeperState extends State<_Gatekeeper> {
  bool _checkingPin = true;
  bool _hasPin = false;
  bool _pinIgnored = false;

  @override
  void initState() {
    super.initState();
    _loadPinState();
  }

  Future<void> _loadPinState() async {
    final hasPin = await widget.storage.hasPin();
    var pinIgnored = false;
    if (hasPin) {
      pinIgnored = widget.preferences.pinIgnored;
      if (pinIgnored) {
        try {
          await widget.storage.unlock('0000');
        } catch (_) {
          pinIgnored = false;
          await widget.preferences.setPinIgnored(false);
        }
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _hasPin = hasPin;
      _pinIgnored = pinIgnored;
      _checkingPin = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingPin) {
      return const _SplashScreen();
    }
    if (!_hasPin) {
      return _PinSetupScreen(
        preferences: widget.preferences,
        onPinSet: (pin, {required ignored}) async {
          await widget.storage.setupPin(pin);
          await widget.preferences.setPinIgnored(ignored);
          if (!mounted) {
            return;
          }
          setState(() {
            _hasPin = true;
            _pinIgnored = ignored;
          });
        },
      );
    }
    if (!widget.storage.isUnlocked) {
      return _PinUnlockScreen(
        pinIgnored: _pinIgnored,
        preferences: widget.preferences,
        onUnlocked: (pin) async {
          await widget.storage.unlock(pin);
          if (!mounted) {
            return;
          }
          setState(() {});
        },
      );
    }
    return WimsyHome(
      service: widget.service,
      storage: widget.storage,
      notifications: widget.notifications,
      preferences: widget.preferences,
    );
  }
}

class WimsyHome extends StatefulWidget {
  const WimsyHome({
    super.key,
    required this.service,
    required this.storage,
    required this.notifications,
    required this.preferences,
  });

  final XmppService service;
  final StorageService storage;
  final NotificationService notifications;
  final PreferencesService preferences;

  @override
  State<WimsyHome> createState() => _WimsyHomeState();
}

class _WimsyHomeState extends State<WimsyHome> {
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  final ScrollController _messageScrollController = ScrollController();
  final Map<String, DateTime> _lastReadAtByChat = {};
  // Busy chats can have tens of thousands of cached messages. Rendering and
  // re-indexing all of them on every rebuild made opening such a chat
  // visibly slow (the window stayed blank while it caught up). Instead we
  // only keep a bounded "window" of the most recent messages on screen and
  // grow it from the already-loaded local cache as the user scrolls up,
  // falling back to a network fetch only once the local cache is exhausted.
  static const int _initialMessageWindowSize = 60;
  static const int _messageWindowIncrement = 60;
  final Map<String, int> _messageWindowByChat = {};
  bool _clearingCache = false;
  Timer? _typingDebounce;
  Timer? _idleTimer;
  ChatState? _lastSentChatState;
  String? _lastFocusedChat;
  int _lastMessageCount = 0;
  final Map<String, bool> _roomSubjectExpanded = {};
  bool _wasAtBottom = true;
  bool _showScrollToBottomButton = false;
  String? _editingMessageId;
  String? _editingChatBareJid;
  bool _editingIsRoom = false;
  String? _replyingChatBareJid;
  bool _replyingIsRoom = false;
  ChatMessage? _replyingToMessage;
  final Map<String, GlobalKey> _messageKeysByChatAndId = {};
  final Map<String, int> _messageIndexByChatAndId = {};
  String? _activeChatForKeyHandler;
  bool _activeChatIsBookmark = false;
  bool _activeChatRoomJoined = false;

  @override
  void initState() {
    super.initState();
    _messageScrollController.addListener(_handleScrollPosition);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    widget.service.attachStorage(widget.storage);
    widget.service.setRosterPersistor(
      (roster) => widget.storage.storeRoster(roster),
    );
    widget.service.setBookmarkPersistor(
      (bookmarks) => widget.storage.storeBookmarks(bookmarks),
    );
    widget.service.setMessagePersistor(
      (bareJid, messages) =>
          widget.storage.storeMessagesForJid(bareJid, messages),
    );
    widget.service.setRoomMessagePersistor(
      (roomJid, messages) =>
          widget.storage.storeRoomMessagesForJid(roomJid, messages),
    );
    _seedRoster();
    _seedBookmarks();
    _seedMessages();
    _seedRoomMessages();
    _loadMediaPreferences();
    widget.service.applyKeepaliveTuning(widget.preferences.keepaliveTuning);
  }

  Future<void> _seedRoster() async {
    final roster = widget.storage.loadRoster();
    widget.service.seedRoster(roster);
  }

  /// The number of most-recent messages to keep rendered for [bareJid].
  /// Grows in [_messageWindowIncrement] steps as the user scrolls toward
  /// the top of a chat with more cached history than is currently shown.
  int _messageWindowFor(String bareJid) {
    return _messageWindowByChat[bareJid] ?? _initialMessageWindowSize;
  }

  /// Reveals another page of already-cached messages for [bareJid] without
  /// hitting the network, preserving the user's scroll position so the
  /// message they were looking at doesn't jump around as older messages
  /// are inserted above it.
  void _growMessageWindow(String bareJid) {
    final hasClients = _messageScrollController.hasClients;
    final previousPixels = hasClients
        ? _messageScrollController.position.pixels
        : null;
    final previousExtent = hasClients
        ? _messageScrollController.position.maxScrollExtent
        : null;
    setState(() {
      _messageWindowByChat[bareJid] =
          _messageWindowFor(bareJid) + _messageWindowIncrement;
    });
    if (previousPixels == null || previousExtent == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_messageScrollController.hasClients) {
        return;
      }
      final newExtent = _messageScrollController.position.maxScrollExtent;
      _messageScrollController.jumpTo(
        scrollOffsetAfterPrepend(
          previousPixels: previousPixels,
          previousMaxScrollExtent: previousExtent,
          newMaxScrollExtent: newExtent,
        ),
      );
    });
  }

  Future<void> _seedMessages() async {
    final messages = widget.storage.loadMessages();
    widget.service.seedMessages(messages);
  }

  Future<void> _seedRoomMessages() async {
    final messages = widget.storage.loadRoomMessages();
    widget.service.seedRoomMessages(messages);
  }

  Future<void> _seedBookmarks() async {
    final bookmarks = widget.storage.loadBookmarks();
    widget.service.seedBookmarks(bookmarks);
  }

  Future<void> _loadMediaPreferences() async {
    final audioInput = widget.preferences.audioInputId;
    final videoInput = widget.preferences.videoInputId;
    if (audioInput != null && audioInput.isNotEmpty) {
      widget.service.selectAudioInput(audioInput);
    }
    if (videoInput != null && videoInput.isNotEmpty) {
      widget.service.selectVideoInput(videoInput);
    }
  }

  @override
  void dispose() {
    _typingDebounce?.cancel();
    _idleTimer?.cancel();
    _messageScrollController.removeListener(_handleScrollPosition);
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _messageFocusNode.dispose();
    _messageScrollController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return false;
    }
    if (event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return false;
    }
    if (!_messageFocusNode.hasFocus) {
      return false;
    }
    final activeChat = _activeChatForKeyHandler;
    if (activeChat == null) {
      return false;
    }
    if (_activeChatIsBookmark && !_activeChatRoomJoined) {
      return false;
    }
    if (_messageController.text.trim().isNotEmpty) {
      return false;
    }
    if (_editingMessageId != null && _editingChatBareJid == activeChat) {
      return false;
    }
    _editLastOutgoingMessage(activeChat, _activeChatIsBookmark);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final service = widget.service;
        if (!service.isConnected) {
          return LoginScreen(
            service: service,
            storage: widget.storage,
            preferences: widget.preferences,
          );
        }
        return _buildClient(context, service);
      },
    );
  }

  Widget _buildClient(BuildContext context, XmppService service) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 900;
        final activeChat = service.activeChatBareJid;
        _noteActiveChatRead(service, activeChat);

        return Scaffold(
          appBar: AppBar(
            title: Text('Signed in as ${service.currentUserBareJid ?? ''}'),
            actions: [
              if (service.quicRttHistory.isNotEmpty) ...[
                _QuicStatsGraph(
                  label: 'RTT',
                  data: service.quicRttHistory,
                  color: Colors.blue,
                  unit: 'ms',
                ),
                const SizedBox(width: 8),
                _QuicStatsGraph(
                  label: 'Loss',
                  data: service.quicLossHistory,
                  color: Colors.red,
                  unit: '',
                  showAverage: true,
                ),
                const SizedBox(width: 16),
              ],
              _PresenceMenu(
                service: service,
                preferences: widget.preferences,
                onClearCacheExit: _clearingCache
                    ? null
                    : _confirmClearCacheAndExit,
                onExit: _handleExit,
              ),
              const SizedBox(width: 12),
            ],
          ),
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFDFBF7), Color(0xFFE8F1F2)],
              ),
            ),
            child: isWide
                ? Row(
                    children: [
                      SizedBox(
                        width: 320,
                        child: _buildRosterPane(context, service, isWide: true),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: _buildChatPane(
                          context,
                          service,
                          activeChat,
                          showBack: false,
                        ),
                      ),
                    ],
                  )
                : activeChat == null
                ? _buildRosterPane(context, service, isWide: false)
                : _buildChatPane(context, service, activeChat, showBack: true),
          ),
        );
      },
    );
  }

  Widget _buildRosterPane(
    BuildContext context,
    XmppService service, {
    required bool isWide,
  }) {
    final theme = Theme.of(context);
    final contacts = service.contacts;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Chats', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _showAddByJidDialog,
                    icon: const Icon(Icons.person_search),
                    label: const Text('Add by JID'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: contacts.isEmpty
                  ? Center(
                      child: Text(
                        'No contacts yet. Add one above.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: contacts.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final contact = contacts[index];
                        final jid = contact.jid;
                        final isBookmark = contact.isBookmark;
                        final isServerNotFound = service.isServerNotFound(jid);
                        final latest = isBookmark
                            ? service.roomMessagesFor(jid).lastOrNull
                            : service.messagesFor(jid).lastOrNull;
                        final presence = service.presenceFor(jid);
                        final statusText = presence?.status?.trim();
                        final effectiveStatusText =
                            statusText != null &&
                                statusText.toLowerCase() == 'unavailable'
                            ? null
                            : statusText;
                        final show =
                            (statusText != null &&
                                statusText.toLowerCase() == 'unavailable')
                            ? null
                            : (presence?.showElement ??
                                  (presence != null
                                      ? PresenceShowElement.CHAT
                                      : null));
                        final dotColor = _presenceDotColor(theme, show);
                        final avatarBytes = service.avatarBytesFor(jid);
                        final messages = isBookmark
                            ? service.roomMessagesFor(jid)
                            : service.messagesFor(jid);
                        final displayedAt = service.displayedAtFor(jid);
                        final localReadAt = _lastReadAtByChat[jid];
                        final activeChat = service.activeChatBareJid;
                        final isActiveChat = activeChat == jid;
                        final lastReadAt = displayedAt == null
                            ? localReadAt
                            : (localReadAt == null ||
                                      displayedAt.isAfter(localReadAt)
                                  ? displayedAt
                                  : localReadAt);
                        var unreadCount = 0;
                        if (!isActiveChat &&
                            service.isMamCatchUpCompleteFor(jid)) {
                          for (final message in messages) {
                            if (!message.outgoing && !message.readByMe) {
                              // Fall back to timestamp comparison for messages
                              // loaded before readByMe was introduced.
                              if (lastReadAt != null &&
                                  !message.timestamp.isAfter(lastReadAt)) {
                                continue;
                              }
                              unreadCount += 1;
                            }
                          }
                        }
                        final isUnread = unreadCount > 0;
                        final roomJoinError = isBookmark
                            ? service.roomFor(jid)?.joinError == true
                            : false;
                        final roomJoinErrorCondition = isBookmark
                            ? service.roomFor(jid)?.joinErrorCondition
                            : null;
                        final bookmarkStatusText = roomJoinError
                            ? _mucJoinErrorLabel(roomJoinErrorCondition)
                            : (contact.bookmarkAutoJoin
                                  ? 'Auto-join room'
                                  : 'Room bookmark');
                        return InkWell(
                          onTap: () => service.selectChat(jid),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: roomJoinError
                                    ? theme.colorScheme.error.withValues(
                                        alpha: 0.5,
                                      )
                                    : (isBookmark
                                          ? theme.colorScheme.primary
                                                .withValues(alpha: 0.35)
                                          : theme.colorScheme.outlineVariant),
                              ),
                            ),
                            child: Opacity(
                              opacity: isServerNotFound ? 0.5 : 1.0,
                              child: Row(
                                children: [
                                  Stack(
                                    children: [
                                      _AvatarPlaceholder(
                                        label: contact.displayName,
                                        bytes: avatarBytes,
                                      ),
                                      if (isBookmark)
                                        Positioned(
                                          right: 0,
                                          bottom: 0,
                                          child: Container(
                                            padding: const EdgeInsets.all(2),
                                            decoration: BoxDecoration(
                                              color: theme.colorScheme.surface,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color:
                                                    theme.colorScheme.primary,
                                                width: 1.2,
                                              ),
                                            ),
                                            child: Icon(
                                              Icons.meeting_room,
                                              size: 12,
                                              color: theme.colorScheme.primary,
                                            ),
                                          ),
                                        )
                                      else
                                        Positioned(
                                          right: 0,
                                          bottom: 0,
                                          child: Container(
                                            width: 12,
                                            height: 12,
                                            decoration: BoxDecoration(
                                              color: dotColor,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color:
                                                    theme.colorScheme.surface,
                                                width: 2,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                contact.displayName,
                                                style: theme
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      fontWeight: isUnread
                                                          ? FontWeight.w600
                                                          : null,
                                                    ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (isBookmark) ...[
                                              const SizedBox(width: 6),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: theme
                                                      .colorScheme
                                                      .primary
                                                      .withValues(alpha: 0.1),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: Text(
                                                  'ROOM',
                                                  style: theme
                                                      .textTheme
                                                      .labelSmall
                                                      ?.copyWith(
                                                        color: theme
                                                            .colorScheme
                                                            .primary,
                                                        letterSpacing: 0.6,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          isBookmark
                                              ? bookmarkStatusText
                                              : ((effectiveStatusText
                                                            ?.isNotEmpty ==
                                                        true)
                                                    ? effectiveStatusText!
                                                    : service.presenceLabelFor(
                                                        jid,
                                                      )),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: roomJoinError
                                                    ? theme.colorScheme.error
                                                    : theme
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                              ),
                                        ),
                                        if (latest != null) ...[
                                          const SizedBox(height: 2),
                                          Builder(
                                            builder: (context) {
                                              final previewText = isBookmark
                                                  ? '${_roomPreviewSenderLabel(latest)}: ${_messagePreviewText(service, latest)}'
                                                  : _messagePreviewText(
                                                      service,
                                                      latest,
                                                    );
                                              final isOutgoingPreview =
                                                  latest.outgoing;
                                              final isUnreadIncomingPreview =
                                                  !latest.outgoing &&
                                                  unreadCount > 0;
                                              return Text(
                                                previewText,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      color: theme
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                      fontStyle:
                                                          isOutgoingPreview
                                                          ? FontStyle.italic
                                                          : null,
                                                      fontWeight:
                                                          isUnreadIncomingPreview
                                                          ? FontWeight.w700
                                                          : null,
                                                    ),
                                              );
                                            },
                                          ),
                                        ],
                                        if (!isBookmark &&
                                            contact.groups.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            contact.groups
                                                .map(
                                                  (group) => '#${group.trim()}',
                                                )
                                                .join(' '),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color:
                                                      theme.colorScheme.primary,
                                                  letterSpacing: 0.2,
                                                ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (unreadCount > 0)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.primary,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        unreadCount > 99
                                            ? '99+'
                                            : unreadCount.toString(),
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color:
                                                  theme.colorScheme.onPrimary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                  if (unreadCount > 0) const SizedBox(width: 8),
                                  _ContactActionsMenu(
                                    isBookmark: isBookmark,
                                    isBlocked: service.isBlocked(jid),
                                    onEditContact: () =>
                                        _showContactDialog(contact: contact),
                                    onRemoveContact: () =>
                                        _confirmRemoveContact(contact),
                                    onBlockContact: () =>
                                        _blockContact(contact),
                                    onUnblockContact: () =>
                                        _unblockContact(contact),
                                    onEditBookmark: () =>
                                        _showBookmarkDialog(contact),
                                    onRemoveBookmark: () =>
                                        _confirmRemoveBookmark(contact),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (!isWide && service.errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                service.errorMessage!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChatPane(
    BuildContext context,
    XmppService service,
    String? activeChat, {
    required bool showBack,
  }) {
    final theme = Theme.of(context);
    final isBookmark = activeChat != null && service.isBookmark(activeChat);
    final isNewlyOpenedChat =
        activeChat != null && activeChat != _lastFocusedChat;
    if (isNewlyOpenedChat) {
      // Start each newly opened chat with just the initial screenful or
      // two, rather than carrying over a window grown from a previous
      // visit or previous chat.
      _messageWindowByChat[activeChat] = _initialMessageWindowSize;
    }
    final allMessages = activeChat == null
        ? const <ChatMessage>[]
        : isBookmark
        ? service.roomMessagesFor(activeChat)
        : service.messagesFor(activeChat);
    // Only render/index the most recent "window" of messages: for a busy
    // chat with a huge cached history, building and indexing every single
    // message on each rebuild is what made opening the chat feel slow.
    // Older messages are revealed on demand as the user scrolls up (see
    // `_growMessageWindow`).
    final messages = activeChat == null
        ? allMessages
        : messageWindow(allMessages, _messageWindowFor(activeChat));
    final messageById = _indexMessagesById(messages);
    _indexMessagePositions(activeChat, messages);
    final roomEntry = activeChat == null ? null : service.roomFor(activeChat);
    _activeChatForKeyHandler = activeChat;
    _activeChatIsBookmark = isBookmark;
    _activeChatRoomJoined = roomEntry?.joined ?? false;
    _handleAutoScroll(allMessages.length);
    if (activeChat != null) {
      _markChatRead(activeChat, allMessages);
    }
    if (activeChat == null) {
      _lastFocusedChat = null;
      _lastMessageCount = 0;
      if (_editingChatBareJid != null) {
        _cancelEditing();
      }
      if (_replyingChatBareJid != null) {
        _cancelReply();
      }
    } else if (isNewlyOpenedChat) {
      _lastFocusedChat = activeChat;
      _lastMessageCount = allMessages.length;
      if (_editingChatBareJid != null && _editingChatBareJid != activeChat) {
        _cancelEditing();
      }
      if (_replyingChatBareJid != null && _replyingChatBareJid != activeChat) {
        _cancelReply();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          // Only focus the message input on non-mobile platforms: popping
          // up the on-screen keyboard automatically on phones/tablets when
          // a chat is opened (e.g. from a notification tap) is unwanted.
          final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
          if (!isBookmark && !isMobile) {
            _messageFocusNode.requestFocus();
          }
          // Always jump straight to the latest message when a chat is
          // opened (e.g. by tapping it in the list or tapping a
          // notification), rather than scrolling to the first unread one.
          _scrollToBottom();
        }
      });
    }

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                if (showBack)
                  IconButton(
                    onPressed: () => service.selectChat(null),
                    icon: const Icon(Icons.arrow_back),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        activeChat ?? 'Select a chat',
                        style: theme.textTheme.titleLarge,
                      ),
                      Text(
                        activeChat == null
                            ? 'Secure connection active'
                            : isBookmark
                            ? _roomSubtitle(roomEntry)
                            : service.chatStateLabelFor(activeChat).isNotEmpty
                            ? service.chatStateLabelFor(activeChat)
                            : 'Secure connection active',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (activeChat != null && isBookmark)
                        _buildRoomSubjectHeader(
                          roomEntry: roomEntry,
                          roomJid: activeChat,
                          theme: theme,
                        ),
                    ],
                  ),
                ),
                if (isBookmark && (roomEntry?.joined ?? false))
                  IconButton(
                    onPressed: () => _showInviteDialog(activeChat),
                    icon: const Icon(Icons.person_add),
                    tooltip: 'Invite to room',
                  ),
                if (activeChat != null && !isBookmark) ...[
                  Builder(
                    builder: (context) {
                      final presence = service.presenceFor(activeChat);
                      final isOnline =
                          presence != null &&
                          (presence.status?.toLowerCase() != 'unavailable');
                      final supportsJingle = service.contactSupportsJingle(
                        activeChat,
                      );
                      final callLikelyAvailable = isOnline && supportsJingle;
                      final callEnabled =
                          service.callSessionFor(activeChat) == null;
                      final callIconColor = callEnabled && !callLikelyAvailable
                          ? Theme.of(context).disabledColor
                          : null;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: callEnabled
                                ? () => _startCall(activeChat, video: false)
                                : null,
                            icon: Icon(Icons.call, color: callIconColor),
                            tooltip: 'Start voice call',
                          ),
                          IconButton(
                            onPressed: callEnabled
                                ? () => _startCall(activeChat, video: true)
                                : null,
                            icon: Icon(Icons.videocam, color: callIconColor),
                            tooltip: 'Start video call',
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
          if (activeChat != null && !isBookmark)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildCallBanner(service, activeChat),
            ),
          if (activeChat != null &&
              isBookmark &&
              service.mujiSessionFor(activeChat) != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildMujiStatusBar(service, activeChat),
            ),
          if (activeChat != null &&
              isBookmark &&
              service.mujiSessionFor(activeChat) != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildMujiParticipantBar(service, activeChat),
            ),
          const Divider(height: 1),
          Expanded(
            child: activeChat == null
                ? Center(
                    child: Text(
                      'Pick a contact to start messaging.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _messageScrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final message = messages[index];
                          final messageKey = _keyForMessage(
                            activeChat,
                            message,
                          );
                          final senderName = isBookmark
                              ? (message.outgoing ? 'You' : message.from)
                              : message.outgoing
                              ? 'You'
                              : service.displayNameFor(message.from);
                          final replyTarget = _resolveReplyTarget(
                            message: message,
                            messageById: messageById,
                          );
                          final replySenderName = replyTarget == null
                              ? null
                              : (isBookmark
                                    ? (replyTarget.outgoing
                                          ? 'you'
                                          : replyTarget.from)
                                    : (replyTarget.outgoing
                                          ? 'you'
                                          : service.displayNameFor(
                                              replyTarget.from,
                                            )));
                          final replyBody = replyTarget?.body;
                          final timestamp = _formatTimestamp(message.timestamp);
                          final occupantAvatarJid = isBookmark
                              ? roomOccupantAvatarJid(
                                  roomJid: activeChat,
                                  nick: message.from,
                                  outgoing: message.outgoing,
                                )
                              : null;
                          final avatarBytes = isBookmark
                              ? (occupantAvatarJid == null
                                    ? null
                                    : service.avatarBytesFor(occupantAvatarJid))
                              : service.avatarBytesFor(message.from);
                          final inviteRoomJid = message.inviteRoomJid;
                          final inviteRoomName =
                              inviteRoomJid == null || inviteRoomJid.isEmpty
                              ? null
                              : service.displayNameFor(inviteRoomJid);
                          final inviteAvatarBytes =
                              inviteRoomJid == null || inviteRoomJid.isEmpty
                              ? null
                              : service.avatarBytesFor(inviteRoomJid);
                          final joinRoom =
                              (inviteRoomJid != null &&
                                  inviteRoomJid.isNotEmpty &&
                                  !message.outgoing)
                              ? () => service.joinRoom(
                                  inviteRoomJid,
                                  password: message.invitePassword,
                                )
                              : null;
                          return MessageBubble(
                            key: messageKey,
                            message: message,
                            senderName: senderName,
                            timestamp: timestamp,
                            avatarBytes: avatarBytes,
                            replySenderName: replySenderName,
                            replyBody: replyBody,
                            onReplyTargetTap: (message.replyToId ?? '').isEmpty
                                ? null
                                : () => _scrollToMessageById(
                                    activeChat,
                                    message.replyToId!,
                                  ),
                            inviteRoomJid: inviteRoomJid,
                            inviteRoomName: inviteRoomName,
                            inviteAvatarBytes: inviteAvatarBytes,
                            inviteReason: message.inviteReason,
                            onJoinInvite: joinRoom,
                            selfReactionSenderId: service.reactionSenderForChat(
                              activeChat,
                              isRoom: isBookmark,
                            ),
                            recentReactionOptions: service.recentReactionEmojis,
                            onReact: (emoji) {
                              service.sendReaction(
                                bareJid: activeChat,
                                message: message,
                                emoji: emoji,
                                isRoom: isBookmark,
                              );
                            },
                            onEdit:
                                (message.outgoing &&
                                    (message.messageId ?? '').isNotEmpty)
                                ? () => _startEditingMessage(
                                    activeChat: activeChat,
                                    message: message,
                                    isRoom: isBookmark,
                                  )
                                : null,
                            onReply:
                                ((message.stanzaId ?? message.messageId) ?? '')
                                    .isNotEmpty
                                ? () => _startReplyingToMessage(
                                    activeChat: activeChat,
                                    message: message,
                                    isRoom: isBookmark,
                                  )
                                : null,
                            onAcceptFile:
                                (!isBookmark &&
                                    !message.outgoing &&
                                    (message.fileTransferId ?? '').isNotEmpty &&
                                    message.fileState == 'offered')
                                ? () => _promptAcceptFileTransfer(
                                    activeChat,
                                    message,
                                  )
                                : null,
                            onDeclineFile:
                                (!isBookmark &&
                                    !message.outgoing &&
                                    (message.fileTransferId ?? '').isNotEmpty &&
                                    message.fileState == 'offered')
                                ? () => _declineFileTransfer(message)
                                : null,
                            onFallbackUpload:
                                (!isBookmark &&
                                    message.outgoing &&
                                    (message.fileTransferId ?? '').isNotEmpty &&
                                    (message.fileState == 'failed' ||
                                        message.fileState == 'declined'))
                                ? () => _fallbackFileTransfer(message)
                                : null,
                          );
                        },
                      ),
                      if (_showScrollToBottomButton)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: FloatingActionButton.small(
                            heroTag: 'scrollToBottomFab',
                            tooltip: 'Scroll to latest message',
                            onPressed: _scrollToBottom,
                            child: const Icon(Icons.arrow_downward),
                          ),
                        ),
                    ],
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (activeChat != null &&
                    service.chatStateLabelFor(activeChat).isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      service.chatStateLabelFor(activeChat),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
                if (isBookmark) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            (roomEntry?.joined ?? false)
                                ? 'Joined room'
                                : 'Not joined',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (!(roomEntry?.joined ?? false))
                          TextButton(
                            onPressed: () => service.joinRoom(activeChat),
                            child: const Text('Join'),
                          )
                        else
                          TextButton(
                            onPressed: () => service.leaveRoom(activeChat),
                            child: const Text('Leave'),
                          ),
                      ],
                    ),
                  ),
                ],
                if (activeChat != null &&
                    _editingMessageId != null &&
                    _editingChatBareJid == activeChat) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Editing message',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _cancelEditing,
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ),
                ],
                if (activeChat != null &&
                    _replyingToMessage != null &&
                    _replyingChatBareJid == activeChat) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Replying: ${_replyPreviewLabel(_replyingToMessage!)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: _cancelReply,
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    // On narrow screens (e.g. phones or split panes), the
                    // attachment and camera actions are combined into a
                    // single menu button so the message field stays as
                    // wide as possible.
                    final isCompact = constraints.maxWidth < 420;
                    final canSend =
                        activeChat != null &&
                        (!isBookmark || (roomEntry?.joined ?? false));
                    return Row(
                      // Align the action buttons to the bottom so that as
                      // the message field grows taller (wrapping longer
                      // messages), the buttons stay anchored near the
                      // text baseline instead of floating in the middle.
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: MessageComposerTextField(
                            controller: _messageController,
                            focusNode: _messageFocusNode,
                            autofocus: canSend,
                            enabled: canSend,
                            // Allow the field to grow (up to a limit) and
                            // wrap the text instead of scrolling
                            // horizontally, so a long message stays fully
                            // visible while composing it.
                            onChanged: (value) {
                              if (activeChat == null || isBookmark) {
                                return;
                              }
                              _handleTypingState(service, activeChat, value);
                            },
                            onSubmitted: (_) => _sendMessage(activeChat),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (isCompact)
                          PopupMenuButton<_ComposerAttachmentAction>(
                            enabled: canSend,
                            icon: const Icon(Icons.attach_file),
                            tooltip: 'Attach',
                            onSelected: (action) {
                              switch (action) {
                                case _ComposerAttachmentAction.file:
                                  _sendAttachment(
                                    activeChat,
                                    isBookmark: isBookmark,
                                    roomEntry: roomEntry,
                                  );
                                  break;
                                case _ComposerAttachmentAction.photo:
                                  _sendPhotoMessage(
                                    activeChat,
                                    isBookmark: isBookmark,
                                    roomEntry: roomEntry,
                                  );
                                  break;
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: _ComposerAttachmentAction.file,
                                child: ListTile(
                                  leading: Icon(Icons.attach_file),
                                  title: Text('Send file'),
                                ),
                              ),
                              PopupMenuItem(
                                value: _ComposerAttachmentAction.photo,
                                child: ListTile(
                                  leading: Icon(Icons.photo_camera),
                                  title: Text('Send photo'),
                                ),
                              ),
                            ],
                          )
                        else ...[
                          IconButton(
                            onPressed: canSend
                                ? () => _sendAttachment(
                                    activeChat,
                                    isBookmark: isBookmark,
                                    roomEntry: roomEntry,
                                  )
                                : null,
                            icon: const Icon(Icons.attach_file),
                            tooltip: 'Send file',
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            onPressed: canSend
                                ? () => _sendPhotoMessage(
                                    activeChat,
                                    isBookmark: isBookmark,
                                    roomEntry: roomEntry,
                                  )
                                : null,
                            icon: const Icon(Icons.photo_camera),
                            tooltip: 'Send photo',
                          ),
                        ],
                        const SizedBox(width: 4),
                        IconButton(
                          onPressed: canSend
                              ? () => _sendMessage(activeChat)
                              : null,
                          icon: const Icon(Icons.send),
                          tooltip: 'Send',
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _sendMessage(String? activeChat) {
    if (activeChat == null) {
      return;
    }
    final text = _messageController.text;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final isBookmark = widget.service.isBookmark(activeChat);
    final editingId = _editingMessageId;
    final editingChat = _editingChatBareJid;
    final editingIsRoom = _editingIsRoom;
    final replyingMessage = _replyingToMessage;
    final replyingChat = _replyingChatBareJid;
    final replyingIsRoom = _replyingIsRoom;
    _messageController.clear();
    if (editingId != null && editingChat == activeChat) {
      _cancelEditing();
      if (editingIsRoom) {
        widget.service.editRoomMessage(
          roomJid: activeChat,
          replaceId: editingId,
          text: trimmed,
        );
      } else {
        widget.service.editMessage(
          toBareJid: activeChat,
          replaceId: editingId,
          text: trimmed,
        );
        _setChatState(activeChat, ChatState.ACTIVE);
      }
    } else if (isBookmark) {
      final replyRef =
          (replyingMessage != null &&
              replyingChat == activeChat &&
              replyingIsRoom == isBookmark)
          ? widget.service.buildReplyReference(
              chatJid: activeChat,
              message: replyingMessage,
              isRoom: true,
            )
          : null;
      widget.service.sendRoomMessage(activeChat, trimmed, reply: replyRef);
    } else {
      final replyRef =
          (replyingMessage != null &&
              replyingChat == activeChat &&
              replyingIsRoom == isBookmark)
          ? widget.service.buildReplyReference(
              chatJid: activeChat,
              message: replyingMessage,
              isRoom: false,
            )
          : null;
      widget.service.sendMessage(
        toBareJid: activeChat,
        text: trimmed,
        reply: replyRef,
      );
      _setChatState(activeChat, ChatState.ACTIVE);
    }
    if (replyingChat == activeChat) {
      _cancelReply();
    }
    if (_messageFocusNode.canRequestFocus) {
      _messageFocusNode.requestFocus();
    }
  }

  Future<void> _sendPhotoMessage(
    String? activeChat, {
    required bool isBookmark,
    RoomEntry? roomEntry,
  }) async {
    if (activeChat == null) {
      return;
    }
    if (isBookmark && !(roomEntry?.joined ?? false)) {
      return;
    }
    final isDesktop =
        !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);
    final supportsPickerCamera =
        !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final useWebRtcCamera = kIsWeb || isDesktop;
    final supportsCamera = useWebRtcCamera || supportsPickerCamera;
    if (!supportsCamera) {
      _showSnack('Camera not available.');
      return;
    }
    final selection = await _capturePhotoForMessage(
      useWebRtcCamera: useWebRtcCamera,
      supportsPickerCamera: supportsPickerCamera,
    );
    if (!mounted || selection == null) {
      return;
    }
    final confirmed = await _confirmUsePhoto(selection.bytes);
    if (!mounted || !confirmed) {
      return;
    }
    final caption = _messageController.text.trim();
    _messageController.clear();
    final error = isBookmark
        ? await widget.service.sendRoomPhotoMessage(
            roomJid: activeChat,
            bytes: selection.bytes,
            fileName: selection.fileName,
            contentType: selection.mimeType,
            body: caption.isEmpty ? null : caption,
          )
        : await widget.service.sendPhotoMessage(
            toBareJid: activeChat,
            bytes: selection.bytes,
            fileName: selection.fileName,
            contentType: selection.mimeType,
            body: caption.isEmpty ? null : caption,
          );
    if (!mounted) {
      return;
    }
    if (error != null) {
      _showSnack(error);
    } else if (!isBookmark) {
      _setChatState(activeChat, ChatState.ACTIVE);
    }
    if (_messageFocusNode.canRequestFocus) {
      _messageFocusNode.requestFocus();
    }
  }

  Future<_PhotoSelection?> _capturePhotoForMessage({
    required bool useWebRtcCamera,
    required bool supportsPickerCamera,
  }) async {
    try {
      if (useWebRtcCamera) {
        final bytes = await _capturePhotoViaWebRtc(context);
        if (!mounted || bytes == null || bytes.isEmpty) {
          return null;
        }
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        return _PhotoSelection(
          bytes: bytes,
          fileName: 'photo-$timestamp.png',
          mimeType: 'image/png',
        );
      }
      if (!supportsPickerCamera) {
        return null;
      }
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.camera);
      if (picked == null) {
        return null;
      }
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) {
        return null;
      }
      final fileName = picked.name.isNotEmpty ? picked.name : 'photo.jpg';
      return _PhotoSelection(
        bytes: bytes,
        fileName: fileName,
        mimeType:
            _guessImageMimeType(picked.path) ?? _guessImageMimeType(fileName),
      );
    } catch (_) {
      if (mounted) {
        _showSnack('Camera not available.');
      }
      return null;
    }
  }

  Future<bool> _confirmUsePhoto(Uint8List bytes) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Use this photo?'),
          content: SizedBox(
            width: 360,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Use photo'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _startCall(String bareJid, {required bool video}) async {
    final result = await widget.service.startCall(
      bareJid: bareJid,
      video: video,
    );
    if (!mounted || result == null) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
  }

  Future<void> _acceptCall(CallSession session) async {
    await widget.service.acceptCall(session);
    await widget.notifications.cancelIncomingCall(session.sid);
  }

  Future<void> _declineCall(CallSession session) async {
    await widget.service.declineCall(session);
    await widget.notifications.cancelIncomingCall(session.sid);
  }

  Future<void> _endCall(CallSession session) async {
    await widget.service.endCall(session);
    await widget.notifications.cancelIncomingCall(session.sid);
  }

  Future<void> _showAudioOutputPicker() async {
    final outputs = await widget.service.listAudioOutputs();
    if (!mounted) {
      return;
    }
    if (outputs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No audio outputs available.')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Audio output')),
              for (final output in outputs)
                ListTile(
                  title: Text(
                    output.label.isEmpty ? output.deviceId : output.label,
                  ),
                  onTap: () {
                    widget.service.selectAudioOutput(output.deviceId);
                    Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAudioInputPicker() async {
    final inputs = await widget.service.listAudioInputs();
    if (!mounted) {
      return;
    }
    if (inputs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No audio inputs available.')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Select microphone')),
              for (var i = 0; i < inputs.length; i++)
                ListTile(
                  title: Text(_deviceLabel(inputs[i], i, 'Microphone')),
                  subtitle:
                      inputs[i].deviceId == widget.service.preferredAudioInputId
                      ? const Text('Selected')
                      : null,
                  onTap: () async {
                    widget.service.selectAudioInput(inputs[i].deviceId);
                    await widget.preferences.setAudioInputId(
                      inputs[i].deviceId,
                    );
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showVideoInputPicker() async {
    final inputs = await widget.service.listVideoInputs();
    if (!mounted) {
      return;
    }
    if (inputs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No cameras available.')));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Select camera')),
              for (var i = 0; i < inputs.length; i++)
                ListTile(
                  title: Text(_deviceLabel(inputs[i], i, 'Camera')),
                  subtitle:
                      inputs[i].deviceId == widget.service.preferredVideoInputId
                      ? const Text('Selected')
                      : null,
                  onTap: () async {
                    widget.service.selectVideoInput(inputs[i].deviceId);
                    await widget.preferences.setVideoInputId(
                      inputs[i].deviceId,
                    );
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  String _deviceLabel(
    MediaDeviceInfo device,
    int index,
    String fallbackPrefix,
  ) {
    final label = device.label.trim();
    if (label.isNotEmpty) {
      return label;
    }
    return '$fallbackPrefix ${index + 1}';
  }

  void _cancelEditing() {
    if (!mounted) {
      return;
    }
    setState(() {
      _editingMessageId = null;
      _editingChatBareJid = null;
      _editingIsRoom = false;
    });
  }

  void _cancelReply() {
    if (!mounted) {
      return;
    }
    setState(() {
      _replyingChatBareJid = null;
      _replyingIsRoom = false;
      _replyingToMessage = null;
    });
  }

  void _startReplyingToMessage({
    required String activeChat,
    required ChatMessage message,
    required bool isRoom,
  }) {
    setState(() {
      _replyingChatBareJid = activeChat;
      _replyingIsRoom = isRoom;
      _replyingToMessage = message;
    });
    if (_messageFocusNode.canRequestFocus) {
      _messageFocusNode.requestFocus();
    }
  }

  String _replyPreviewLabel(ChatMessage message) {
    final compact = message.body.trim().replaceAll('\n', ' ');
    if (compact.isEmpty) {
      return '(empty message)';
    }
    const maxChars = 100;
    if (compact.runes.length <= maxChars) {
      return compact;
    }
    return '${String.fromCharCodes(compact.runes.take(maxChars))}…';
  }

  GlobalKey? _keyForMessage(String? activeChat, ChatMessage message) {
    if (activeChat == null) {
      return null;
    }
    final ids = _messageIds(message);
    if (ids.isEmpty) {
      return null;
    }
    GlobalKey? existing;
    for (final id in ids) {
      final candidate = _messageKeysByChatAndId['$activeChat|$id'];
      if (candidate != null) {
        existing = candidate;
        break;
      }
    }
    final key = existing ?? GlobalKey();
    for (final id in ids) {
      _messageKeysByChatAndId['$activeChat|$id'] = key;
    }
    return key;
  }

  Set<String> _messageIds(ChatMessage message) {
    final ids = <String>{};
    final messageId = message.messageId;
    final stanzaId = message.stanzaId;
    final mamId = message.mamId;
    if (messageId != null && messageId.isNotEmpty) {
      ids.add(messageId);
    }
    if (stanzaId != null && stanzaId.isNotEmpty) {
      ids.add(stanzaId);
    }
    if (mamId != null && mamId.isNotEmpty) {
      ids.add(mamId);
    }
    return ids;
  }

  Map<String, ChatMessage> _indexMessagesById(List<ChatMessage> messages) {
    final map = <String, ChatMessage>{};
    for (final message in messages) {
      for (final id in _messageIds(message)) {
        map[id] = message;
      }
    }
    return map;
  }

  void _indexMessagePositions(String? activeChat, List<ChatMessage> messages) {
    if (activeChat == null) {
      return;
    }
    for (var i = 0; i < messages.length; i += 1) {
      for (final id in _messageIds(messages[i])) {
        _messageIndexByChatAndId['$activeChat|$id'] = i;
      }
    }
  }

  ChatMessage? _resolveReplyTarget({
    required ChatMessage message,
    required Map<String, ChatMessage> messageById,
  }) {
    final replyToId = message.replyToId;
    if (replyToId == null || replyToId.isEmpty) {
      return null;
    }
    return messageById[replyToId];
  }

  Future<void> _scrollToMessageById(String? activeChat, String targetId) async {
    if (activeChat == null || targetId.isEmpty) {
      return;
    }
    final mapKey = '$activeChat|$targetId';
    final immediateContext = _messageKeysByChatAndId[mapKey]?.currentContext;
    if (immediateContext != null) {
      await Scrollable.ensureVisible(
        immediateContext,
        alignment: 0.15,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    {
      final index = _messageIndexByChatAndId[mapKey];
      if (index == null || !_messageScrollController.hasClients) {
        return;
      }
      final targetOffset = index * 84.0;
      final clamped = targetOffset.clamp(
        0.0,
        _messageScrollController.position.maxScrollExtent,
      );
      await _messageScrollController.animateTo(
        clamped,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
      if (!mounted) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      if (!mounted) {
        return;
      }
    }
  }

  void _startEditingMessage({
    required String activeChat,
    required ChatMessage message,
    required bool isRoom,
  }) {
    final messageId = message.messageId;
    if (messageId == null || messageId.isEmpty) {
      return;
    }
    final body = message.body;
    setState(() {
      _editingMessageId = messageId;
      _editingChatBareJid = activeChat;
      _editingIsRoom = isRoom;
    });
    _messageController.value = TextEditingValue(
      text: body,
      selection: TextSelection.collapsed(offset: body.length),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (_messageController.text != body) {
        _messageController.value = TextEditingValue(
          text: body,
          selection: TextSelection.collapsed(offset: body.length),
        );
      }
    });
    if (_messageFocusNode.canRequestFocus) {
      _messageFocusNode.requestFocus();
    }
  }

  void _editLastOutgoingMessage(String activeChat, bool isRoom) {
    final messages = isRoom
        ? widget.service.roomMessagesFor(activeChat)
        : widget.service.messagesFor(activeChat);
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (!message.outgoing) {
        continue;
      }
      if (message.body.trim().isEmpty) {
        continue;
      }
      _startEditingMessage(
        activeChat: activeChat,
        message: message,
        isRoom: isRoom,
      );
      break;
    }
  }

  Widget _buildCallBanner(XmppService service, String bareJid) {
    final session = service.callSessionFor(bareJid);
    if (session == null) {
      return const SizedBox.shrink();
    }
    if (session.state != CallState.ringing &&
        session.state != CallState.active) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final isIncoming = session.direction == CallDirection.incoming;
    final isActive = session.state == CallState.active;
    final typeLabel = session.video ? 'video' : 'voice';
    final title = isActive
        ? 'In $typeLabel call'
        : isIncoming
        ? 'Incoming $typeLabel call'
        : 'Calling...';
    final localStream = service.callLocalStreamFor(bareJid);
    final remoteStream = service.callRemoteStreamFor(bareJid);
    final localSpeaking = service.isCallLocalSpeaking(bareJid);
    final remoteSpeaking = service.isCallRemoteSpeaking(bareJid);
    return Card(
      color: theme.colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  session.video ? Icons.videocam : Icons.call,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: theme.textTheme.bodyMedium)),
                if (!isActive && isIncoming) ...[
                  TextButton(
                    onPressed: () => _declineCall(session),
                    child: const Text('Decline'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _acceptCall(session),
                    child: const Text('Accept'),
                  ),
                ] else
                  FilledButton(
                    onPressed: () => _endCall(session),
                    child: const Text('Hang up'),
                  ),
              ],
            ),
            if (session.video) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 180,
                child: Row(
                  children: [
                    Expanded(
                      child: _SpeakingFrame(
                        active: remoteSpeaking,
                        color: theme.colorScheme.primary,
                        child: _CallVideoView(
                          stream: remoteStream ?? localStream,
                          mirrored: false,
                          placeholder: 'Remote video',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SpeakingFrame(
                        active: localSpeaking,
                        color: theme.colorScheme.tertiary,
                        child: _CallVideoView(
                          stream: localStream,
                          mirrored: true,
                          placeholder: 'Local preview',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (isActive) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  _SpeakingPill(
                    label: 'You',
                    active: localSpeaking,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  _SpeakingPill(
                    label: 'Them',
                    active: remoteSpeaking,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: () => service.toggleCallMute(bareJid),
                    icon: Icon(
                      service.isCallMuted(bareJid) ? Icons.mic_off : Icons.mic,
                    ),
                    tooltip: service.isCallMuted(bareJid) ? 'Unmute' : 'Mute',
                  ),
                  IconButton(
                    onPressed: _showAudioInputPicker,
                    icon: const Icon(Icons.settings_voice),
                    tooltip: 'Select microphone',
                  ),
                  IconButton(
                    onPressed: () => service.toggleSpeakerphone(),
                    icon: Icon(
                      service.isSpeakerphoneOn
                          ? Icons.volume_up
                          : Icons.volume_down,
                    ),
                    tooltip: service.isSpeakerphoneOn
                        ? 'Speaker on'
                        : 'Speaker off',
                  ),
                  IconButton(
                    onPressed: _showAudioOutputPicker,
                    icon: const Icon(Icons.headphones),
                    tooltip: 'Select audio output',
                  ),
                  if (session.video)
                    IconButton(
                      onPressed: () => service.toggleCallVideo(bareJid),
                      icon: Icon(
                        service.isCallVideoEnabled(bareJid)
                            ? Icons.videocam
                            : Icons.videocam_off,
                      ),
                      tooltip: service.isCallVideoEnabled(bareJid)
                          ? 'Disable camera'
                          : 'Enable camera',
                    ),
                  if (session.video)
                    IconButton(
                      onPressed: _showVideoInputPicker,
                      icon: const Icon(Icons.switch_camera),
                      tooltip: 'Select camera',
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRoomSubjectHeader({
    required RoomEntry? roomEntry,
    required String roomJid,
    required ThemeData theme,
  }) {
    final subject = roomEntry?.subject?.trim() ?? '';
    if (subject.isEmpty) {
      return const SizedBox.shrink();
    }
    final expanded = _roomSubjectExpanded[roomJid] ?? false;
    final baseStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final linkStyle = baseStyle?.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Subject',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () {
                  setState(() {
                    _roomSubjectExpanded[roomJid] = !expanded;
                  });
                },
                child: Text(expanded ? 'Collapse' : 'Expand'),
              ),
            ],
          ),
          RichText(
            text: TextSpan(
              style: baseStyle,
              children: _linkifyText(subject, baseStyle, linkStyle),
            ),
            maxLines: expanded ? null : 2,
            overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  List<TextSpan> _linkifyText(
    String input,
    TextStyle? baseStyle,
    TextStyle? linkStyle,
  ) {
    final regex = RegExp(
      r'((https?:\/\/)|(www\.))[^\s<]+',
      caseSensitive: false,
    );
    final matches = regex.allMatches(input).toList();
    if (matches.isEmpty) {
      return [TextSpan(text: input, style: baseStyle)];
    }

    final spans = <TextSpan>[];
    var lastIndex = 0;
    for (final match in matches) {
      if (match.start > lastIndex) {
        spans.add(
          TextSpan(
            text: input.substring(lastIndex, match.start),
            style: baseStyle,
          ),
        );
      }
      final raw = input.substring(match.start, match.end);
      final normalized = _normalizeUrl(raw);
      spans.add(
        TextSpan(
          text: raw,
          style: linkStyle ?? baseStyle,
          recognizer: TapGestureRecognizer()
            ..onTap = () async {
              final uri = Uri.tryParse(normalized);
              if (uri == null) {
                return;
              }
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
        ),
      );
      lastIndex = match.end;
    }
    if (lastIndex < input.length) {
      spans.add(TextSpan(text: input.substring(lastIndex), style: baseStyle));
    }
    return spans;
  }

  String _normalizeUrl(String raw) {
    final stripped = _stripTrailingPunctuation(raw);
    final lower = stripped.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return stripped;
    }
    return 'https://$stripped';
  }

  String _stripTrailingPunctuation(String input) {
    var result = input;
    while (result.isNotEmpty &&
        RegExp(r'[\\).,!?;:\\]]').hasMatch(result[result.length - 1])) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  Widget _buildMujiParticipantBar(XmppService service, String roomJid) {
    final session = service.mujiSessionFor(roomJid);
    if (session == null) {
      return const SizedBox.shrink();
    }
    final participants = session.participants;
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Participants (${participants.length})',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            if (participants.isEmpty)
              Text(
                'Waiting for participants…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: participants
                    .map((participant) {
                      final icon = participant.muted
                          ? Icons.mic_off
                          : Icons.mic;
                      final speakerIcon = participant.speaking
                          ? Icons.volume_up
                          : Icons.volume_off;
                      return Chip(
                        avatar: Icon(
                          icon,
                          size: 16,
                          color: participant.muted
                              ? theme.colorScheme.error
                              : theme.colorScheme.primary,
                        ),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(participant.nick),
                            const SizedBox(width: 4),
                            Icon(
                              speakerIcon,
                              size: 16,
                              color: participant.speaking
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      );
                    })
                    .toList(growable: false),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMujiStatusBar(XmppService service, String roomJid) {
    final session = service.mujiSessionFor(roomJid);
    if (session == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.groups, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Muji call active', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text(
                    'Other participants can join from the room.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => service.leaveMujiRoom(roomJid),
              child: const Text('Leave'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendAttachment(
    String? activeChat, {
    required bool isBookmark,
    RoomEntry? roomEntry,
  }) async {
    if (activeChat == null) {
      return;
    }
    if (isBookmark && !(roomEntry?.joined ?? false)) {
      return;
    }
    final selection = await FilePicker.pickFiles(withData: true);
    if (selection == null || selection.files.isEmpty) {
      return;
    }
    final file = selection.files.first;
    final bytes = await _readPickedFileBytes(file);
    if (bytes == null || bytes.isEmpty) {
      _showSnack('Unable to read file.');
      return;
    }
    final contentType = _guessContentType(file.name);
    final error = isBookmark
        ? await widget.service.sendRoomFile(
            roomJid: activeChat,
            bytes: bytes,
            fileName: file.name,
            contentType: contentType,
          )
        : await widget.service.sendFile(
            toBareJid: activeChat,
            bytes: bytes,
            fileName: file.name,
            contentType: contentType,
          );
    if (!mounted) {
      return;
    }
    if (error != null) {
      _showSnack(error);
    }
  }

  Future<void> _promptAcceptFileTransfer(
    String activeChat,
    ChatMessage message,
  ) async {
    final transferId = message.fileTransferId;
    if (transferId == null || transferId.isEmpty) {
      return;
    }
    final suggested = message.fileName?.isNotEmpty == true
        ? message.fileName!
        : 'file';
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save file',
      fileName: suggested,
    );
    if (path == null || path.isEmpty) {
      await _declineFileTransfer(message);
      return;
    }
    await widget.service.acceptFileTransfer(
      transferId: transferId,
      savePath: path,
    );
  }

  Future<void> _declineFileTransfer(ChatMessage message) async {
    final transferId = message.fileTransferId;
    if (transferId == null || transferId.isEmpty) {
      return;
    }
    await widget.service.declineFileTransfer(transferId: transferId);
  }

  Future<void> _fallbackFileTransfer(ChatMessage message) async {
    final transferId = message.fileTransferId;
    if (transferId == null || transferId.isEmpty) {
      return;
    }
    final error = await widget.service.fallbackFileTransferToHttpUpload(
      transferId: transferId,
    );
    if (!mounted) {
      return;
    }
    if (error != null) {
      _showSnack(error);
    }
  }

  String? _guessContentType(String fileName) {
    final parts = fileName.toLowerCase().split('.');
    if (parts.length < 2) {
      return null;
    }
    final ext = parts.last;
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'pdf':
        return 'application/pdf';
      default:
        return null;
    }
  }

  List<String> _parseGroups(String input) {
    final normalized = input.replaceAll('#', ' ');
    final parts = normalized.split(RegExp(r'[,\s]+'));
    final groups = <String>[];
    for (final part in parts) {
      final value = part.trim();
      if (value.isNotEmpty) {
        groups.add(value);
      }
    }
    return groups;
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showInviteDialog(String? roomJid) async {
    if (roomJid == null || roomJid.trim().isEmpty) {
      return;
    }
    final jidController = TextEditingController();
    final reasonController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Invite to room'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: jidController,
                  decoration: const InputDecoration(
                    labelText: 'Invitee JID',
                    hintText: 'user@example.com',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: reasonController,
                  decoration: const InputDecoration(
                    labelText: 'Reason (optional)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Send invite'),
            ),
          ],
        );
      },
    );
    if (result != true || !mounted) {
      return;
    }
    final invitee = jidController.text.trim();
    if (invitee.isEmpty) {
      _showSnack('Invitee JID required.');
      return;
    }
    final error = await widget.service.inviteToRoom(
      roomJid: roomJid,
      inviteeJid: invitee,
      reason: reasonController.text,
    );
    if (!mounted) {
      return;
    }
    if (error != null) {
      _showSnack(error);
    }
  }

  Future<void> _showContactDialog({ContactEntry? contact}) async {
    final isEdit = contact != null;
    final jidController = TextEditingController(text: contact?.jid ?? '');
    final nameController = TextEditingController(text: contact?.name ?? '');
    final groupsController = TextEditingController(
      text: contact?.groups.join(' ') ?? '',
    );
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(isEdit ? 'Edit contact' : 'Add contact'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: jidController,
                  readOnly: isEdit,
                  decoration: const InputDecoration(
                    labelText: 'JID',
                    hintText: 'user@example.com',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Display name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: groupsController,
                  decoration: const InputDecoration(
                    labelText: 'Groups (comma or #tags)',
                  ),
                ),
                if (contact != null) ...[
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Presence: ${widget.service.presenceLabelFor(contact.jid)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Subscription: ${contact.subscriptionType ?? 'none'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final ok = await widget.service
                                .requestPresenceSubscription(contact.jid);
                            if (!ok) {
                              _showSnack('Failed to request presence.');
                            } else {
                              _showSnack('Presence subscription requested.');
                            }
                          },
                          child: const Text('Subscribe'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final ok = await widget.service
                                .preauthorizePresenceSubscription(contact.jid);
                            if (!ok) {
                              _showSnack('Failed to preauthorize.');
                            } else {
                              _showSnack('Preauthorized contact.');
                            }
                          },
                          child: const Text('Preauthorize'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (result != true) {
      return;
    }
    final jid = jidController.text.trim();
    if (jid.isEmpty) {
      _showSnack('Enter a JID to save.');
      return;
    }
    final name = nameController.text.trim();
    final groups = _parseGroups(groupsController.text);
    final ok = await widget.service.upsertRosterContact(
      jid,
      name: name.isNotEmpty ? name : null,
      groups: groups,
    );
    if (!ok) {
      _showSnack('Failed to save contact.');
      return;
    }
    if (!isEdit) {
      await _promptPresenceSubscriptionActions(jid);
    }
  }

  Future<void> _showAddByJidDialog() async {
    final result = await showDialog<_AddByJidResult>(
      context: context,
      builder: (context) => _AddByJidDialog(service: widget.service),
    );
    if (result == null) {
      return;
    }
    if (result.isRoom) {
      widget.service.joinRoom(
        result.jid,
        nick: result.nick,
        password: result.password,
      );
      if (result.saveBookmark) {
        final bookmark = ContactEntry(
          jid: result.jid,
          name: result.roomName,
          groups: const [],
          isBookmark: true,
          bookmarkNick: result.nick,
          bookmarkPassword: result.password,
          bookmarkAutoJoin: result.autoJoin,
        );
        final ok = await widget.service.upsertBookmark(bookmark);
        if (!ok) {
          _showSnack('Failed to save bookmark.');
        }
      }
      return;
    }
    final ok = await widget.service.upsertRosterContact(result.jid);
    if (!ok) {
      _showSnack('Failed to save contact.');
      return;
    }
    await _promptPresenceSubscriptionActions(result.jid);
  }

  Future<void> _promptPresenceSubscriptionActions(String jid) async {
    if (!mounted) {
      return;
    }
    final selection = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Presence Subscription'),
          content: const Text(
            'Do you want to request and/or preauthorize presence subscription for this contact?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop('skip'),
              child: const Text('Skip'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('subscribe'),
              child: const Text('Subscribe'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('preauthorize'),
              child: const Text('Preauthorize'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop('both'),
              child: const Text('Both'),
            ),
          ],
        );
      },
    );
    if (!mounted || selection == null || selection == 'skip') {
      return;
    }
    if (selection == 'subscribe' || selection == 'both') {
      final ok = await widget.service.requestPresenceSubscription(jid);
      if (!ok) {
        _showSnack('Failed to request presence.');
      } else {
        _showSnack('Presence subscription requested.');
      }
    }
    if (selection == 'preauthorize' || selection == 'both') {
      final ok = await widget.service.preauthorizePresenceSubscription(jid);
      if (!ok) {
        _showSnack('Failed to preauthorize.');
      } else {
        _showSnack('Preauthorized contact.');
      }
    }
  }

  Future<void> _showBookmarkDialog(ContactEntry bookmark) async {
    final jidController = TextEditingController(text: bookmark.jid);
    final nameController = TextEditingController(text: bookmark.name ?? '');
    final nickController = TextEditingController(
      text: bookmark.bookmarkNick ?? '',
    );
    final passwordController = TextEditingController(
      text: bookmark.bookmarkPassword ?? '',
    );
    var autoJoin = bookmark.bookmarkAutoJoin;
    var notifyMode = bookmark.effectiveMucNotifySettings.mode;
    var afterOwnChoice = _afterOwnChoiceFor(
      bookmark.effectiveMucNotifySettings,
    );
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Edit bookmark'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: jidController,
                      readOnly: true,
                      decoration: const InputDecoration(labelText: 'Room JID'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Room name'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nickController,
                      decoration: const InputDecoration(labelText: 'Nickname'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: passwordController,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      value: autoJoin,
                      onChanged: (value) => setState(() => autoJoin = value),
                      title: const Text('Auto-join'),
                    ),
                    const Divider(height: 24),
                    DropdownButtonFormField<MucNotifyMode>(
                      initialValue: notifyMode,
                      decoration: const InputDecoration(
                        labelText: 'Notify me about',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: MucNotifyMode.all,
                          child: Text('All messages'),
                        ),
                        DropdownMenuItem(
                          value: MucNotifyMode.mentions,
                          child: Text('Only mentions of my nickname'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => notifyMode = value);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<_AfterOwnMessageChoice>(
                      initialValue: afterOwnChoice,
                      decoration: const InputDecoration(
                        labelText: 'After I send a message',
                      ),
                      items: _AfterOwnMessageChoice.values
                          .map(
                            (choice) => DropdownMenuItem(
                              value: choice,
                              child: Text(choice.label),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => afterOwnChoice = value);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    if (result != true) {
      return;
    }
    final updated = ContactEntry(
      jid: bookmark.jid,
      name: nameController.text.trim().isNotEmpty
          ? nameController.text.trim()
          : null,
      groups: const [],
      isBookmark: true,
      bookmarkNick: nickController.text.trim().isNotEmpty
          ? nickController.text.trim()
          : null,
      bookmarkPassword: passwordController.text.trim().isNotEmpty
          ? passwordController.text.trim()
          : null,
      bookmarkAutoJoin: autoJoin,
      mucNotifySettings: MucNotifySettings(
        mode: notifyMode,
        afterOwnMessagePeriod: afterOwnChoice.period,
        alwaysAfterOwnMessage: afterOwnChoice.always,
      ),
    );
    final ok = await widget.service.upsertBookmark(updated);
    if (!ok) {
      _showSnack('Failed to save bookmark.');
    }
  }

  _AfterOwnMessageChoice _afterOwnChoiceFor(MucNotifySettings settings) {
    if (settings.alwaysAfterOwnMessage) {
      return _AfterOwnMessageChoice.alwaysNotify;
    }
    final period = settings.afterOwnMessagePeriod;
    if (period == null) {
      return _AfterOwnMessageChoice.off;
    }
    return _AfterOwnMessageChoice.values.firstWhere(
      (choice) => choice.period == period,
      orElse: () => _AfterOwnMessageChoice.off,
    );
  }

  Future<void> _confirmRemoveContact(ContactEntry contact) async {
    final shouldRemove = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Remove contact?'),
          content: Text('Remove ${contact.displayName} from your roster?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
    if (shouldRemove != true) {
      return;
    }
    final ok = await widget.service.removeRosterContact(contact.jid);
    if (!ok) {
      _showSnack('Failed to remove contact.');
    }
  }

  Future<void> _confirmRemoveBookmark(ContactEntry bookmark) async {
    final shouldRemove = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Remove bookmark?'),
          content: Text('Remove ${bookmark.displayName} from bookmarks?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
    if (shouldRemove != true) {
      return;
    }
    final ok = await widget.service.removeBookmark(bookmark.jid);
    if (!ok) {
      _showSnack('Failed to remove bookmark.');
    }
  }

  Future<void> _blockContact(ContactEntry contact) async {
    final ok = await widget.service.blockContact(contact.jid);
    if (!ok) {
      _showSnack('Blocking not supported by your server.');
    }
  }

  Future<void> _unblockContact(ContactEntry contact) async {
    final ok = await widget.service.unblockContact(contact.jid);
    if (!ok) {
      _showSnack('Unblocking not supported by your server.');
    }
  }

  void _handleTypingState(
    XmppService service,
    String activeChat,
    String value,
  ) {
    _typingDebounce?.cancel();
    _idleTimer?.cancel();

    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      _setChatState(activeChat, ChatState.PAUSED);
    } else {
      _typingDebounce = Timer(const Duration(milliseconds: 350), () {
        _setChatState(activeChat, ChatState.COMPOSING);
      });
    }

    _idleTimer = Timer(const Duration(seconds: 5), () {
      if (_messageController.text.trim().isEmpty) {
        _setChatState(activeChat, ChatState.INACTIVE);
      }
    });
  }

  void _markChatRead(String bareJid, List<ChatMessage> messages) {
    if (messages.isEmpty) {
      return;
    }
    _lastReadAtByChat[bareJid] = messages.last.timestamp;
    // Mark all loaded messages as read by the local user so the per-message
    // readByMe flag is persisted and survives reconnects.
    widget.service.markMessagesRead(bareJid);
    unawaited(widget.notifications.cancelMessagesForTag(bareJid));
  }

  void _noteActiveChatRead(XmppService service, String? activeChat) {
    if (activeChat == null) {
      return;
    }
    final isBookmark = service.isBookmark(activeChat);
    if (isBookmark && (service.roomFor(activeChat)?.joined ?? false) == false) {
      return;
    }
    final messages = isBookmark
        ? service.roomMessagesFor(activeChat)
        : service.messagesFor(activeChat);
    _markChatRead(activeChat, messages);
  }

  Future<void> _confirmClearCacheAndExit() async {
    final cleared = await _confirmClearCache();
    if (mounted && cleared) {
      _handleExit();
    }
  }

  void _handleExit() {
    widget.service.disconnect();
    if (kIsWeb) {
      return;
    }
    if (Platform.isAndroid) {
      FlutterForegroundTask.stopService();
      SystemNavigator.pop();
    } else {
      exit(0);
    }
  }

  void _setChatState(String bareJid, ChatState state) {
    if (_lastSentChatState == state) {
      return;
    }
    _lastSentChatState = state;
    widget.service.setMyChatState(bareJid, state);
  }

  void _handleAutoScroll(int messageCount) {
    if (messageCount == _lastMessageCount) {
      return;
    }
    _lastMessageCount = messageCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (!_messageScrollController.hasClients) {
        return;
      }
      if (_wasAtBottom) {
        _scrollToBottom();
      }
    });
  }

  void _handleScrollPosition() {
    if (!_messageScrollController.hasClients) {
      _wasAtBottom = true;
      _updateScrollToBottomButton(false);
      return;
    }
    final position = _messageScrollController.position;
    _wasAtBottom = position.pixels >= (position.maxScrollExtent - 48);
    _updateScrollToBottomButton(
      shouldShowScrollToBottomButton(
        pixels: position.pixels,
        maxScrollExtent: position.maxScrollExtent,
      ),
    );
    if (position.pixels <= 24) {
      final activeChat = widget.service.activeChatBareJid;
      if (activeChat != null) {
        final isRoom = widget.service.isBookmark(activeChat);
        final cachedCount = isRoom
            ? widget.service.roomMessagesFor(activeChat).length
            : widget.service.messagesFor(activeChat).length;
        if (cachedCount > _messageWindowFor(activeChat)) {
          // More history is already sitting in the local cache: reveal it
          // immediately rather than waiting on a round-trip to the server.
          _growMessageWindow(activeChat);
        } else {
          widget.service.requestOlderMessages(activeChat);
        }
      }
    }
  }

  void _updateScrollToBottomButton(bool visible) {
    if (_showScrollToBottomButton == visible) {
      return;
    }
    setState(() {
      _showScrollToBottomButton = visible;
    });
  }

  void _scrollToBottom() {
    if (!_messageScrollController.hasClients) {
      return;
    }
    _messageScrollController
        .animateTo(
          _messageScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        )
        .then((_) => _settleScrollToBottom());
  }

  /// After the scroll animation completes, the message list's content
  /// height may have changed slightly (e.g. an image or avatar finishing
  /// layout, or a new message arriving mid-animation), leaving the view
  /// short of the true bottom because [maxScrollExtent] was captured before
  /// the animation started. Jump straight to the up-to-date
  /// [maxScrollExtent] so the view always lands exactly at the latest
  /// message.
  void _settleScrollToBottom() {
    if (!mounted || !_messageScrollController.hasClients) {
      return;
    }
    final position = _messageScrollController.position;
    if (position.pixels < position.maxScrollExtent) {
      _messageScrollController.jumpTo(position.maxScrollExtent);
    }
  }

  Future<bool> _confirmClearCache() async {
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Clear cached data?'),
          content: const Text(
            'This removes cached roster and messages from this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Clear'),
            ),
          ],
        );
      },
    );
    if (shouldClear != true) {
      return false;
    }
    setState(() => _clearingCache = true);
    await widget.storage.clearRoster();
    await widget.storage.clearBookmarks();
    await widget.storage.storeMessagesForJid('', const []);
    await widget.storage.clearAvatars();
    await widget.storage.clearVcardAvatars();
    widget.service.clearCache();
    if (mounted) {
      setState(() => _clearingCache = false);
    }
    return true;
  }
}

/// Decides whether the floating "scroll to latest message" button should be
/// visible for the message list, given the current scroll [pixels] offset
/// and the list's [maxScrollExtent].
///
/// The button is only shown once the user has scrolled a meaningful
/// distance away from the bottom, so it doesn't flicker in and out for tiny
/// scroll adjustments near the latest message.
bool shouldShowScrollToBottomButton({
  required double pixels,
  required double maxScrollExtent,
}) {
  return maxScrollExtent - pixels > 200;
}

/// Returns the slice of [messages] that should actually be rendered: the
/// most recent [windowSize] messages, or all of them if there are fewer
/// than [windowSize] to begin with.
///
/// Busy chats/groupchats can have a local cache of many thousands of
/// messages. Rendering (and re-indexing, for reply lookups and jump-to-id)
/// every single one on every rebuild is what made opening such a chat feel
/// slow, with the window staying blank for a while before finally showing
/// up scrolled to the bottom. Keeping only a bounded window in view fixes
/// that; older messages are paged in on demand as the user scrolls up.
List<ChatMessage> messageWindow(List<ChatMessage> messages, int windowSize) {
  if (windowSize <= 0 || messages.isEmpty) {
    return messages;
  }
  if (messages.length <= windowSize) {
    return messages;
  }
  return messages.sublist(messages.length - windowSize);
}

/// Computes the scroll offset that keeps the same content on screen after
/// older messages have been prepended to the message list.
///
/// Prepending items above the current viewport pushes everything else
/// down by the amount of newly-added content; without compensating for
/// that, the user's view would visibly jump. This returns the new
/// [previousPixels] offset shifted by however much the scrollable content
/// grew (`newMaxScrollExtent - previousMaxScrollExtent`), so the message
/// the user was looking at stays in the same place.
double scrollOffsetAfterPrepend({
  required double previousPixels,
  required double previousMaxScrollExtent,
  required double newMaxScrollExtent,
}) {
  final delta = newMaxScrollExtent - previousMaxScrollExtent;
  if (delta <= 0) {
    return previousPixels;
  }
  return previousPixels + delta;
}

/// Returns a human-readable label for a MUC join error to show in the
/// contact list. [errorCondition] is the XMPP error condition element name
/// (e.g. "registration-required", "forbidden").
String _mucJoinErrorLabel(String? errorCondition) {
  switch (errorCondition) {
    case 'registration-required':
      return 'Join failed: members only';
    case 'forbidden':
      return 'Join failed: banned';
    case 'not-allowed':
      return 'Join failed: not allowed';
    case 'conflict':
      return 'Join failed: nickname conflict';
    case 'service-unavailable':
      return 'Join failed: room full';
    case 'not-authorized':
    case 'password-required':
      return 'Join failed: password required';
    default:
      return 'Join failed';
  }
}

String _messagePreviewText(XmppService service, ChatMessage message) {
  final inviteRoomJid = message.inviteRoomJid;
  if (inviteRoomJid != null && inviteRoomJid.isNotEmpty) {
    final roomName = service.displayNameFor(inviteRoomJid);
    return 'Invitation to $roomName';
  }
  final transferId = message.fileTransferId;
  if (transferId != null && transferId.isNotEmpty) {
    final name = message.fileName?.trim();
    return name == null || name.isEmpty ? 'File transfer' : 'File: $name';
  }
  final body = message.body.trim();
  if (body.isNotEmpty) {
    return body;
  }
  final oob = message.oobUrl?.trim() ?? '';
  if (oob.isEmpty) {
    return 'Message';
  }
  final uri = Uri.tryParse(oob);
  final name = uri == null || uri.pathSegments.isEmpty
      ? ''
      : uri.pathSegments.last.trim();
  return name.isEmpty ? oob : 'File: ${Uri.decodeComponent(name)}';
}

String _roomPreviewSenderLabel(ChatMessage message) {
  if (message.outgoing) {
    return 'you';
  }
  final sender = message.from.trim();
  return sender.isEmpty ? 'unknown' : sender;
}

/// Preset choices for the "notify me for a while after I post" MUC
/// notification option, shown in the bookmark editor.
enum _AfterOwnMessageChoice {
  off('Off', null, false),
  fiveMinutes('For 5 minutes', Duration(minutes: 5), false),
  fifteenMinutes('For 15 minutes', Duration(minutes: 15), false),
  oneHour('For 1 hour', Duration(hours: 1), false),
  alwaysNotify('Always', null, true);

  const _AfterOwnMessageChoice(this.label, this.period, this.always);

  final String label;
  final Duration? period;
  final bool always;
}

/// Actions available in the combined attachment menu shown on narrow
/// screens, where the file and photo actions are merged into one button.
enum _ComposerAttachmentAction { file, photo }

class _PhotoSelection {
  const _PhotoSelection({
    required this.bytes,
    required this.fileName,
    this.mimeType,
  });

  final Uint8List bytes;
  final String fileName;
  final String? mimeType;
}

List<String> _reactionPickerOptions(List<String> recent) {
  final ordered = <String>[];
  for (final emoji in [...recent, ..._defaultReactionOptions]) {
    if (emoji.trim().isEmpty || ordered.contains(emoji)) {
      continue;
    }
    ordered.add(emoji);
  }
  return ordered;
}

Future<String?> _promptForCustomReaction(BuildContext context) async {
  final controller = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Add reaction'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Emoji',
            hintText: 'Paste or type an emoji',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Add'),
          ),
        ],
      );
    },
  );
  final normalized = value?.trim() ?? '';
  if (normalized.isEmpty) {
    return null;
  }
  final chars = normalized.characters;
  return chars.isEmpty ? null : chars.first;
}

void _showReactionPickerSheet({
  required BuildContext context,
  required void Function(String emoji) onReact,
  required List<String> recentReactionOptions,
  required Set<String> ownReactions,
}) {
  final options = _reactionPickerOptions(recentReactionOptions);
  showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final emoji in options)
                    FilterChip(
                      selected: ownReactions.contains(emoji),
                      label: Text(emoji, style: const TextStyle(fontSize: 20)),
                      side: BorderSide(
                        color: ownReactions.contains(emoji)
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                      ),
                      onSelected: (_) {
                        Navigator.of(sheetContext).pop();
                        onReact(emoji);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () async {
                  Navigator.of(sheetContext).pop();
                  final custom = await _promptForCustomReaction(context);
                  if (custom == null || custom.isEmpty) {
                    return;
                  }
                  onReact(custom);
                },
                icon: const Icon(Icons.add_reaction_outlined),
                label: const Text('Use custom emoji'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// The text entry field used by the chat composer.
///
/// Its text input hints intentionally describe ordinary prose so mobile
/// keyboards enable sentence capitalization, autocorrection, and suggestions.
class MessageComposerTextField extends StatelessWidget {
  const MessageComposerTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.autofocus,
    required this.enabled,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool autofocus;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const Key('message-composer-input'),
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      enabled: enabled,
      keyboardType: TextInputType.text,
      textCapitalization: TextCapitalization.sentences,
      autocorrect: true,
      enableSuggestions: true,
      minLines: 1,
      maxLines: 6,
      textInputAction: TextInputAction.send,
      decoration: const InputDecoration(labelText: 'Message'),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.senderName,
    required this.timestamp,
    required this.avatarBytes,
    required this.replySenderName,
    required this.replyBody,
    required this.onReplyTargetTap,
    required this.inviteRoomJid,
    required this.inviteRoomName,
    required this.inviteAvatarBytes,
    required this.inviteReason,
    required this.onJoinInvite,
    required this.selfReactionSenderId,
    required this.recentReactionOptions,
    required this.onReact,
    required this.onEdit,
    required this.onReply,
    required this.onAcceptFile,
    required this.onDeclineFile,
    required this.onFallbackUpload,
  });

  final ChatMessage message;
  final String senderName;
  final String timestamp;
  final Uint8List? avatarBytes;
  final String? replySenderName;
  final String? replyBody;
  final VoidCallback? onReplyTargetTap;
  final String? inviteRoomJid;
  final String? inviteRoomName;
  final Uint8List? inviteAvatarBytes;
  final String? inviteReason;
  final VoidCallback? onJoinInvite;
  final String selfReactionSenderId;
  final List<String> recentReactionOptions;
  final void Function(String emoji)? onReact;
  final VoidCallback? onEdit;
  final VoidCallback? onReply;
  final VoidCallback? onAcceptFile;
  final VoidCallback? onDeclineFile;
  final VoidCallback? onFallbackUpload;

  @override
  Widget build(BuildContext context) {
    final menuKey = GlobalKey<_MessageMenuButtonState>();
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    final linkColor = theme.colorScheme.primary;
    final tickIcon = _tickIcon(theme);
    final nameColor = message.outgoing
        ? textColor.withValues(alpha: 0.85)
        : xep0392ColorForLabel(senderName);
    final oobImage = _buildOobImage(context);
    final oobFileCard = _buildOobFileCard(context);
    final fileTransferCard = _buildFileTransferCard(context);
    final inviteCard = _buildInviteCard(context);
    final reactions = message.reactions ?? const {};
    final ownReactions = _ownReactions(reactions);

    return _TouchLongPressRegion(
      key: Key('message-bubble-${message.messageId}'),
      onLongPress: (position) => menuKey.currentState?.showAt(position),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MessageMenuButton(
              key: menuKey,
              message: message,
              recentReactionOptions: recentReactionOptions,
              ownReactions: ownReactions,
              onReact: onReact,
              onEdit: onEdit,
              onReply: onReply,
              child: _AvatarPlaceholder(label: senderName, bytes: avatarBytes),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          senderName,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: nameColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            timestamp,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: textColor.withValues(alpha: 0.7),
                            ),
                          ),
                          if (message.edited) ...[
                            const SizedBox(width: 6),
                            Text(
                              'edited',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: textColor.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                          if (tickIcon != null) ...[
                            const SizedBox(width: 6),
                            tickIcon,
                          ],
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if ((message.replyToId ?? '').isNotEmpty) ...[
                    _buildReplyCard(context),
                    const SizedBox(height: 8),
                  ],
                  if (fileTransferCard != null) ...[
                    fileTransferCard,
                    const SizedBox(height: 8),
                  ],
                  if (inviteCard != null) ...[
                    inviteCard,
                    const SizedBox(height: 8),
                  ],
                  if (oobImage != null) ...[
                    oobImage,
                    const SizedBox(height: 8),
                  ],
                  if (oobFileCard != null) ...[
                    oobFileCard,
                    const SizedBox(height: 8),
                  ],
                  if (_meCommandAction(message.body) != null)
                    SelectableText(
                      _formatMeCommand(
                        senderName,
                        _meCommandAction(message.body)!,
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: textColor,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else if (_shouldShowBody(message.body, message.oobUrl))
                    SelectableText.rich(
                      TextSpan(
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textColor,
                        ),
                        children: _linkifyText(
                          message.body,
                          theme.textTheme.bodyMedium?.copyWith(
                            color: textColor,
                          ),
                          theme.textTheme.bodyMedium?.copyWith(
                            color: linkColor,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                  if (reactions.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _buildReactionRow(context, reactions, ownReactions),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReplyCard(BuildContext context) {
    final theme = Theme.of(context);
    final cardBody = (replyBody ?? message.replyFallback ?? '').trim();
    final text = cardBody.isEmpty ? '(original message unavailable)' : cardBody;
    return InkWell(
      onTap: onReplyTargetTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              replySenderName ?? 'original message',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget? _tickIcon(ThemeData theme) {
    if (!message.outgoing) {
      return null;
    }
    if (message.displayed) {
      return Icon(Icons.done_all, size: 14, color: theme.colorScheme.primary);
    }
    if (message.receiptReceived) {
      return Icon(
        Icons.done_all,
        size: 14,
        color: theme.colorScheme.onSurfaceVariant,
      );
    }
    if (message.acked) {
      return Icon(
        Icons.done,
        size: 14,
        color: theme.colorScheme.onSurfaceVariant,
      );
    }
    return null;
  }

  List<TextSpan> _linkifyText(
    String input,
    TextStyle? baseStyle,
    TextStyle? linkStyle,
  ) {
    final regex = RegExp(
      r'((https?:\/\/)|(www\.))[^\s<]+',
      caseSensitive: false,
    );
    final matches = regex.allMatches(input).toList();
    if (matches.isEmpty) {
      return [TextSpan(text: input, style: baseStyle)];
    }

    final spans = <TextSpan>[];
    var lastIndex = 0;
    for (final match in matches) {
      if (match.start > lastIndex) {
        spans.add(
          TextSpan(
            text: input.substring(lastIndex, match.start),
            style: baseStyle,
          ),
        );
      }
      final raw = input.substring(match.start, match.end);
      final normalized = _normalizeUrl(raw);
      spans.add(
        TextSpan(
          text: raw,
          style: linkStyle ?? baseStyle,
          recognizer: TapGestureRecognizer()
            ..onTap = () async {
              final uri = Uri.tryParse(normalized);
              if (uri == null) {
                return;
              }
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
        ),
      );
      lastIndex = match.end;
    }
    if (lastIndex < input.length) {
      spans.add(TextSpan(text: input.substring(lastIndex), style: baseStyle));
    }
    return spans;
  }

  String _normalizeUrl(String raw) {
    final stripped = _stripTrailingPunctuation(raw);
    final lower = stripped.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return stripped;
    }
    return 'https://$stripped';
  }

  String _stripTrailingPunctuation(String input) {
    var result = input;
    while (result.isNotEmpty &&
        RegExp(r'[\\).,!?;:\\]]').hasMatch(result[result.length - 1])) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  String? _meCommandAction(String body) {
    if (!body.startsWith('/me ')) {
      return null;
    }
    final action = body.substring(4).trim();
    return action.isEmpty ? null : action;
  }

  String _formatMeCommand(String senderName, String action) {
    return '* $senderName $action';
  }

  bool _shouldShowBody(String body, String? oobUrl) {
    if (_isNonImageOob(oobUrl)) {
      return false;
    }
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final rawOob = oobUrl?.trim();
    if (rawOob == null || rawOob.isEmpty) {
      return true;
    }
    if (trimmed.contains(RegExp(r'\s'))) {
      return true;
    }
    return _normalizeUrl(trimmed) != _normalizeUrl(rawOob);
  }

  Widget? _buildInviteCard(BuildContext context) {
    final roomJid = inviteRoomJid;
    if (roomJid == null || roomJid.isEmpty) {
      return null;
    }
    final theme = Theme.of(context);
    final title = inviteRoomName?.isNotEmpty == true
        ? inviteRoomName!
        : roomJid;
    final subtitle = inviteReason?.isNotEmpty == true ? inviteReason! : roomJid;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AvatarPlaceholder(label: title, bytes: inviteAvatarBytes),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (onJoinInvite != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      onPressed: onJoinInvite,
                      child: const Text('Join'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildFileTransferCard(BuildContext context) {
    final transferId = message.fileTransferId;
    if (transferId == null || transferId.isEmpty) {
      return null;
    }
    final theme = Theme.of(context);
    final name = message.fileName?.isNotEmpty == true
        ? message.fileName!
        : 'File';
    final size = message.fileSize;
    final bytes = message.fileBytes ?? 0;
    final state = message.fileState ?? '';
    final status = _fileTransferStatusLabel(state, message.outgoing);
    final showActions =
        !message.outgoing &&
        state == 'offered' &&
        (onAcceptFile != null || onDeclineFile != null);
    final showFallback =
        message.outgoing &&
        (state == 'failed' || state == 'declined') &&
        onFallbackUpload != null;
    final hasProgress = size != null && size > 0 && state == 'in_progress';
    final progressValue = hasProgress ? (bytes / size).clamp(0.0, 1.0) : null;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            size == null ? 'Size unknown' : _formatFileSize(size),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            status,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (hasProgress) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progressValue),
          ],
          if (showActions) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: onAcceptFile,
                  child: const Text('Receive'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onDeclineFile,
                  child: const Text('Decline'),
                ),
              ],
            ),
          ],
          if (showFallback) ...[
            const SizedBox(height: 8),
            FilledButton(
              onPressed: onFallbackUpload,
              child: const Text('Send via HTTP'),
            ),
          ],
        ],
      ),
    );
  }

  String _fileTransferStatusLabel(String state, bool outgoing) {
    switch (state) {
      case 'accepted':
        return 'Accepted';
      case 'in_progress':
        return outgoing ? 'Sending...' : 'Receiving...';
      case 'completed':
        return 'Completed';
      case 'failed':
        return 'Failed';
      case 'declined':
        return 'Declined';
      case 'offered':
      default:
        return outgoing ? 'Waiting for acceptance' : 'Waiting to accept';
    }
  }

  String _formatFileSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex += 1;
    }
    final value = size >= 10
        ? size.roundToDouble()
        : double.parse(size.toStringAsFixed(1));
    final text = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$text ${units[unitIndex]}';
  }

  Widget? _buildOobImage(BuildContext context) {
    final url = _imageUrlForMessage(message.oobUrl);
    if (url == null) {
      return null;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 260.0;
        final cap = math.min(maxWidth, 280.0);
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: cap, maxHeight: cap),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _showExpandedImage(context, url),
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Shows a fullscreen overlay displaying [url] so the user can view the
  /// image at full size. Tapping the background or the close button dismisses
  /// the overlay.
  void _showExpandedImage(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog.fullscreen(
          backgroundColor: Colors.black87,
          child: Stack(
            children: [
              // Tapping outside the image also dismisses the dialog.
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(color: Colors.transparent),
              ),
              Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 8.0,
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: SafeArea(
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget? _buildOobFileCard(BuildContext context) {
    final url = message.oobUrl?.trim() ?? '';
    if (url.isEmpty || _isImageUrl(url)) {
      return null;
    }
    final theme = Theme.of(context);
    final description = _oobDescriptionText(url);
    final name = _oobFileName(url);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: theme.textTheme.titleSmall),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: () async {
                final uri = Uri.tryParse(url);
                if (uri == null) {
                  return;
                }
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              child: const Text('Download'),
            ),
          ),
        ],
      ),
    );
  }

  bool _isNonImageOob(String? oobUrl) {
    final raw = oobUrl?.trim();
    if (raw == null || raw.isEmpty) {
      return false;
    }
    return !_isImageUrl(raw);
  }

  String _oobDescriptionText(String url) {
    final description = message.oobDescription?.trim();
    if (description != null && description.isNotEmpty) {
      return description;
    }
    final body = message.body.trim();
    if (body.isNotEmpty && _normalizeUrl(body) != _normalizeUrl(url)) {
      return body;
    }
    return url;
  }

  String _oobFileName(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return 'File';
    }
    final segments = uri.pathSegments;
    if (segments.isEmpty) {
      return 'File';
    }
    final last = segments.last.trim();
    if (last.isEmpty) {
      return 'File';
    }
    return Uri.decodeComponent(last);
  }

  String? _imageUrlForMessage(String? oobUrl) {
    final raw = oobUrl?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    if (!_isImageUrl(raw)) {
      return null;
    }
    return raw;
  }

  bool _isImageUrl(String url) {
    final lower = url.toLowerCase();
    final match = RegExp(r'\.(png|jpe?g|gif|webp|bmp)(\?|#|$)').hasMatch(lower);
    if (match) {
      return true;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    final path = uri.path.toLowerCase();
    return RegExp(r'\.(png|jpe?g|gif|webp|bmp)$').hasMatch(path);
  }

  Set<String> _ownReactions(Map<String, List<String>> reactions) {
    final sender = selfReactionSenderId.trim();
    if (sender.isEmpty) {
      return <String>{};
    }
    final result = <String>{};
    reactions.forEach((emoji, senders) {
      if (senders.contains(sender)) {
        result.add(emoji);
      }
    });
    return result;
  }

  Widget _buildReactionRow(
    BuildContext context,
    Map<String, List<String>> reactions,
    Set<String> ownReactions,
  ) {
    final theme = Theme.of(context);
    final entries = reactions.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final entry in entries)
          Tooltip(
            message: entry.value.join(', '),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onReact == null ? null : () => onReact!(entry.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: ownReactions.contains(entry.key)
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: ownReactions.contains(entry.key)
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                  child: Text(
                    '${entry.key} ${entry.value.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: ownReactions.contains(entry.key)
                          ? theme.colorScheme.onPrimaryContainer
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Detects touch long presses without competing with selectable message text.
class _TouchLongPressRegion extends StatefulWidget {
  const _TouchLongPressRegion({
    super.key,
    required this.onLongPress,
    required this.child,
  });

  final ValueChanged<Offset> onLongPress;
  final Widget child;

  @override
  State<_TouchLongPressRegion> createState() => _TouchLongPressRegionState();
}

class _TouchLongPressRegionState extends State<_TouchLongPressRegion> {
  Timer? _timer;
  int? _pointer;
  Offset? _startPosition;

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    _cancel();
    _pointer = event.pointer;
    _startPosition = event.position;
    _timer = Timer(kLongPressTimeout, () {
      final position = _startPosition;
      _timer = null;
      if (position != null) {
        widget.onLongPress(position);
      }
    });
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _startPosition == null) {
      return;
    }
    if ((event.position - _startPosition!).distance > kTouchSlop) {
      _cancel();
    }
  }

  void _handlePointerEnd(PointerEvent event) {
    if (event.pointer == _pointer) {
      _cancel();
    }
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _pointer = null;
    _startPosition = null;
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
      child: widget.child,
    );
  }
}

class _ContactActionsMenu extends StatelessWidget {
  const _ContactActionsMenu({
    required this.isBookmark,
    required this.isBlocked,
    required this.onEditContact,
    required this.onRemoveContact,
    required this.onBlockContact,
    required this.onUnblockContact,
    required this.onEditBookmark,
    required this.onRemoveBookmark,
  });

  final bool isBookmark;
  final bool isBlocked;
  final VoidCallback onEditContact;
  final VoidCallback onRemoveContact;
  final VoidCallback onBlockContact;
  final VoidCallback onUnblockContact;
  final VoidCallback onEditBookmark;
  final VoidCallback onRemoveBookmark;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        switch (value) {
          case 'edit_contact':
            onEditContact();
            break;
          case 'remove_contact':
            onRemoveContact();
            break;
          case 'block_contact':
            onBlockContact();
            break;
          case 'unblock_contact':
            onUnblockContact();
            break;
          case 'edit_bookmark':
            onEditBookmark();
            break;
          case 'remove_bookmark':
            onRemoveBookmark();
            break;
        }
      },
      itemBuilder: (context) {
        if (isBookmark) {
          return [
            const PopupMenuItem(
              value: 'edit_bookmark',
              child: Text('Edit bookmark'),
            ),
            const PopupMenuItem(
              value: 'remove_bookmark',
              child: Text('Remove bookmark'),
            ),
          ];
        }
        return [
          const PopupMenuItem(
            value: 'edit_contact',
            child: Text('Edit contact'),
          ),
          const PopupMenuItem(
            value: 'remove_contact',
            child: Text('Remove contact'),
          ),
          PopupMenuItem(
            value: isBlocked ? 'unblock_contact' : 'block_contact',
            child: Text(isBlocked ? 'Unblock' : 'Block'),
          ),
        ];
      },
    );
  }
}

enum _AddTargetType { person, room }

class _AddByJidResult {
  const _AddByJidResult({
    required this.jid,
    required this.isRoom,
    this.nick,
    this.password,
    required this.saveBookmark,
    this.roomName,
    required this.autoJoin,
  });

  final String jid;
  final bool isRoom;
  final String? nick;
  final String? password;
  final bool saveBookmark;
  final String? roomName;
  final bool autoJoin;
}

class _AddByJidDialog extends StatefulWidget {
  const _AddByJidDialog({required this.service});

  final XmppService service;

  @override
  State<_AddByJidDialog> createState() => _AddByJidDialogState();
}

class _AddByJidDialogState extends State<_AddByJidDialog> {
  final TextEditingController _jidController = TextEditingController();
  final TextEditingController _nickController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _roomNameController = TextEditingController();
  Timer? _discoveryDebounce;
  int _discoveryToken = 0;
  bool _discovering = false;
  bool _manualTypeOverride = false;
  bool _saveBookmark = false;
  bool _autoJoin = false;
  String? _jidError;
  String? _discoveryMessage;
  String? _discoveredName;
  _AddTargetType _selectedType = _AddTargetType.person;

  @override
  void initState() {
    super.initState();
    _jidController.addListener(_handleJidChanged);
  }

  @override
  void dispose() {
    _discoveryDebounce?.cancel();
    _jidController.removeListener(_handleJidChanged);
    _jidController.dispose();
    _nickController.dispose();
    _passwordController.dispose();
    _roomNameController.dispose();
    super.dispose();
  }

  void _handleJidChanged() {
    final raw = _jidController.text.trim();
    final normalized = _normalizeJid(raw);
    final token = ++_discoveryToken;
    _manualTypeOverride = false;
    _discoveryDebounce?.cancel();
    if (raw.isEmpty) {
      setState(() {
        _discovering = false;
        _discoveryMessage = null;
        _discoveredName = null;
        _jidError = null;
        _selectedType = _AddTargetType.person;
      });
      return;
    }
    if (normalized == null) {
      setState(() {
        _discovering = false;
        _discoveryMessage = null;
        _discoveredName = null;
        _jidError = 'Enter a valid JID.';
      });
      return;
    }
    setState(() {
      _jidError = null;
      _discovering = true;
      _discoveryMessage = 'Checking...';
    });
    _discoveryDebounce = Timer(const Duration(milliseconds: 500), () async {
      final result = await widget.service.discoverJidKind(normalized);
      if (!mounted || token != _discoveryToken) {
        return;
      }
      setState(() {
        _discovering = false;
        _discoveredName = result.identityName?.trim();
        switch (result.kind) {
          case DiscoveredJidKind.room:
            _discoveryMessage = 'Detected: Room';
            if (!_manualTypeOverride) {
              _selectedType = _AddTargetType.room;
            }
          case DiscoveredJidKind.person:
            _discoveryMessage = 'Detected: Person';
            if (!_manualTypeOverride) {
              _selectedType = _AddTargetType.person;
            }
          case DiscoveredJidKind.unknown:
            _discoveryMessage =
                'Couldn’t determine type. Using manual selection.';
        }
      });
    });
  }

  String? _normalizeJid(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final parsed = Jid.fromFullJid(trimmed);
    final bare = parsed.userAtDomain;
    if (!_isValidBareJid(bare)) {
      return null;
    }
    return bare;
  }

  bool _isValidBareJid(String bare) {
    if (bare.isEmpty || bare.contains(' ')) {
      return false;
    }
    final atIndex = bare.indexOf('@');
    if (atIndex <= 0 || atIndex != bare.lastIndexOf('@')) {
      return false;
    }
    final local = bare.substring(0, atIndex);
    final domain = bare.substring(atIndex + 1);
    if (local.isEmpty ||
        domain.isEmpty ||
        domain.startsWith('.') ||
        domain.endsWith('.') ||
        domain.contains('..')) {
      return false;
    }
    return true;
  }

  void _submit() {
    final normalized = _normalizeJid(_jidController.text);
    if (normalized == null) {
      setState(() {
        _jidError = 'Enter a valid JID.';
      });
      return;
    }
    final isRoom = _selectedType == _AddTargetType.room;
    final nick = _nickController.text.trim();
    final password = _passwordController.text.trim();
    final roomName = _roomNameController.text.trim();
    Navigator.of(context).pop(
      _AddByJidResult(
        jid: normalized,
        isRoom: isRoom,
        nick: nick.isEmpty ? null : nick,
        password: password.isEmpty ? null : password,
        saveBookmark: isRoom && _saveBookmark,
        roomName: roomName.isEmpty ? null : roomName,
        autoJoin: isRoom && _saveBookmark ? _autoJoin : false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final normalized = _normalizeJid(_jidController.text);
        final previewLabel = normalized ?? _jidController.text.trim();
        final avatarBytes = normalized == null
            ? null
            : widget.service.avatarBytesFor(normalized);
        final serviceName = (normalized == null || normalized.isEmpty)
            ? ''
            : widget.service.displayNameFor(normalized);
        final name = _discoveredName?.isNotEmpty == true
            ? _discoveredName!
            : (serviceName != normalized ? serviceName : '');
        final isRoom = _selectedType == _AddTargetType.room;
        return AlertDialog(
          title: const Text('Add by JID'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _jidController,
                  decoration: InputDecoration(
                    labelText: 'JID',
                    hintText: 'user@example.com',
                    errorText: _jidError,
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                SegmentedButton<_AddTargetType>(
                  segments: const [
                    ButtonSegment<_AddTargetType>(
                      value: _AddTargetType.person,
                      label: Text('Person'),
                      icon: Icon(Icons.person_outline),
                    ),
                    ButtonSegment<_AddTargetType>(
                      value: _AddTargetType.room,
                      label: Text('Room'),
                      icon: Icon(Icons.meeting_room_outlined),
                    ),
                  ],
                  selected: <_AddTargetType>{_selectedType},
                  onSelectionChanged: (selection) {
                    if (selection.isEmpty) {
                      return;
                    }
                    setState(() {
                      _manualTypeOverride = true;
                      _selectedType = selection.first;
                    });
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _AvatarPlaceholder(label: previewLabel, bytes: avatarBytes),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.isNotEmpty ? name : 'Name not available yet',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (previewLabel.isNotEmpty)
                            Text(
                              previewLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _discovering
                        ? 'Checking...'
                        : (_discoveryMessage ?? 'Type a JID to detect type.'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (isRoom) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _nickController,
                    decoration: const InputDecoration(
                      labelText: 'Nickname (optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordController,
                    decoration: const InputDecoration(
                      labelText: 'Password (optional)',
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _saveBookmark,
                    onChanged: (value) => setState(() => _saveBookmark = value),
                    title: const Text('Save bookmark'),
                  ),
                  if (_saveBookmark) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _roomNameController,
                      decoration: const InputDecoration(
                        labelText: 'Room name (optional)',
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _autoJoin,
                      onChanged: (value) => setState(() => _autoJoin = value),
                      title: const Text('Auto-join'),
                    ),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _submit,
              child: Text(isRoom ? 'Join room' : 'Add contact'),
            ),
          ],
        );
      },
    );
  }
}

extension ListLastOrNull<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}

class _AvatarPlaceholder extends StatelessWidget {
  const _AvatarPlaceholder({required this.label, this.bytes});

  final String label;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final initial = label.trim().isEmpty ? '?' : label.trim()[0].toUpperCase();
    if (bytes != null) {
      return CircleAvatar(radius: 18, backgroundImage: MemoryImage(bytes!));
    }
    final baseColor = xep0392ColorForLabel(label);
    final onBase = baseColor.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    return CircleAvatar(
      radius: 18,
      backgroundColor: baseColor,
      foregroundColor: onBase,
      child: Text(initial),
    );
  }
}

class _MessageMenuButton extends StatefulWidget {
  const _MessageMenuButton({
    super.key,
    required this.message,
    required this.recentReactionOptions,
    required this.ownReactions,
    required this.onReact,
    required this.onEdit,
    required this.onReply,
    this.child,
  });

  final ChatMessage message;
  final List<String> recentReactionOptions;
  final Set<String> ownReactions;
  final void Function(String emoji)? onReact;
  final VoidCallback? onEdit;
  final VoidCallback? onReply;
  final Widget? child;

  @override
  State<_MessageMenuButton> createState() => _MessageMenuButtonState();
}

class _MessageMenuButtonState extends State<_MessageMenuButton> {
  Future<void> showAt(Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: _items(),
    );
    if (value != null && mounted) {
      _handleSelected(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 0, minHeight: 0),
      icon: widget.child == null
          ? const Icon(Icons.more_horiz, size: 16)
          : null,
      onSelected: _handleSelected,
      itemBuilder: (context) => _items(),
      child: widget.child,
    );
  }

  List<PopupMenuEntry<String>> _items() {
    final reactions = widget.message.reactions ?? const {};
    return [
      if (widget.onEdit != null)
        const PopupMenuItem(value: 'edit_message', child: Text('Edit message')),
      if (widget.onReply != null)
        const PopupMenuItem(value: 'reply_message', child: Text('Reply')),
      if (widget.onReact != null)
        const PopupMenuItem(value: 'add_reaction', child: Text('Add reaction')),
      if (reactions.isNotEmpty)
        const PopupMenuItem(
          value: 'view_reactions',
          child: Text('View reactions'),
        ),
      const PopupMenuItem(value: 'view_xml', child: Text('View XML')),
    ];
  }

  void _handleSelected(String value) {
    switch (value) {
      case 'edit_message':
        widget.onEdit?.call();
      case 'reply_message':
        widget.onReply?.call();
      case 'add_reaction':
        _showReactionSheet(context);
      case 'view_reactions':
        _showReactions(context);
      case 'view_xml':
        _showXml(context);
    }
  }

  void _showReactionSheet(BuildContext context) {
    if (widget.onReact == null) {
      return;
    }
    _showReactionPickerSheet(
      context: context,
      onReact: widget.onReact!,
      recentReactionOptions: widget.recentReactionOptions,
      ownReactions: widget.ownReactions,
    );
  }

  void _showReactions(BuildContext context) {
    final reactions = widget.message.reactions ?? const {};
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Reactions'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry
                      in reactions.entries.toList()
                        ..sort((a, b) => a.key.compareTo(b.key)))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('${entry.key} ${entry.value.join(', ')}'),
                    ),
                  if (reactions.isEmpty) const Text('No reactions yet.'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  void _showXml(BuildContext context) {
    final xml = widget.message.rawXml?.trim();
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Message XML'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: SelectableText(
                (xml == null || xml.isEmpty)
                    ? 'No XML cached for this message.'
                    : xml,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

String _formatTimestamp(DateTime timestamp) {
  final local = timestamp.toLocal();
  final now = DateTime.now();
  final todayStart = DateTime(now.year, now.month, now.day);
  final showDate = local.isBefore(todayStart);
  final hours = local.hour.toString().padLeft(2, '0');
  final minutes = local.minute.toString().padLeft(2, '0');
  if (!showDate) {
    return '$hours:$minutes';
  }
  final year = local.year.toString().padLeft(4, '0');
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$year-$month-$day $hours:$minutes';
}

String _roomSubtitle(RoomEntry? entry) {
  if (entry == null) {
    return 'Room';
  }
  final parts = <String>[];
  parts.add(entry.joined ? 'Joined' : 'Not joined');
  if (entry.occupantCount > 0) {
    parts.add('${entry.occupantCount} online');
  }
  return parts.join(' · ');
}

Color _presenceDotColor(ThemeData theme, PresenceShowElement? show) {
  if (show == null) {
    return theme.colorScheme.outlineVariant;
  }
  switch (show) {
    case PresenceShowElement.CHAT:
      return const Color(0xFF2FB84D);
    case PresenceShowElement.AWAY:
      return const Color(0xFFF9A825);
    case PresenceShowElement.DND:
      return const Color(0xFFC62828);
    case PresenceShowElement.XA:
      return const Color(0xFFF9A825);
  }
}

class _PresenceMenu extends StatelessWidget {
  const _PresenceMenu({
    required this.service,
    required this.preferences,
    required this.onClearCacheExit,
    required this.onExit,
  });

  final XmppService service;
  final PreferencesService preferences;
  final VoidCallback? onClearCacheExit;
  final VoidCallback onExit;

  Future<void> _setSentryOptIn(BuildContext context, bool enabled) async {
    await preferences.setSentryOptIn(enabled);
    if (enabled) {
      await _enableSentryAndRestart();
      return;
    }
    await _restartWithoutSentry();
  }

  Future<bool> _getSentryOptIn() async => preferences.sentryOptIn;

  Future<void> _editProfile(BuildContext context) async {
    final selfJid = service.currentUserBareJid;
    if (selfJid == null || selfJid.isEmpty) {
      return;
    }
    final isDesktop =
        !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);
    final supportsPickerCamera =
        !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final useWebRtcCamera = kIsWeb || isDesktop;
    final supportsCamera = useWebRtcCamera || supportsPickerCamera;
    final nameController = TextEditingController(
      text: service.displayNameFor(selfJid),
    );
    Uint8List? avatarBytes = service.avatarBytesFor(selfJid);
    String? avatarMimeType;
    var clearAvatar = false;
    var saving = false;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Edit profile'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundImage: avatarBytes != null
                          ? MemoryImage(avatarBytes!)
                          : null,
                      child: avatarBytes == null
                          ? const Icon(Icons.person, size: 32)
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () async {
                                  final result = await FilePicker.pickFiles(
                                    type: FileType.image,
                                    withData: true,
                                  );
                                  if (result == null || result.files.isEmpty) {
                                    return;
                                  }
                                  final file = result.files.first;
                                  final bytes = await _readPickedFileBytes(
                                    file,
                                  );
                                  if (bytes == null || bytes.isEmpty) {
                                    return;
                                  }
                                  setState(() {
                                    avatarBytes = bytes;
                                    avatarMimeType = _guessImageMimeType(
                                      file.name,
                                    );
                                    clearAvatar = false;
                                  });
                                },
                          icon: const Icon(Icons.image),
                          label: const Text('Choose file'),
                        ),
                        OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : (supportsCamera
                                    ? () async {
                                        final messenger = ScaffoldMessenger.of(
                                          context,
                                        );
                                        try {
                                          Uint8List? bytes;
                                          String? mimeType;
                                          if (useWebRtcCamera) {
                                            bytes =
                                                await _capturePhotoViaWebRtc(
                                                  context,
                                                );
                                            mimeType = bytes == null
                                                ? null
                                                : 'image/png';
                                          } else if (supportsPickerCamera) {
                                            final picker = ImagePicker();
                                            final picked = await picker
                                                .pickImage(
                                                  source: ImageSource.camera,
                                                );
                                            if (picked == null) {
                                              return;
                                            }
                                            bytes = await picked.readAsBytes();
                                            if (bytes.isEmpty) {
                                              return;
                                            }
                                            mimeType = _guessImageMimeType(
                                              picked.path,
                                            );
                                          }
                                          if (bytes == null || bytes.isEmpty) {
                                            return;
                                          }
                                          setState(() {
                                            avatarBytes = bytes;
                                            avatarMimeType = mimeType;
                                            clearAvatar = false;
                                          });
                                        } catch (_) {
                                          if (!context.mounted) {
                                            return;
                                          }
                                          messenger.showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Camera not available.',
                                              ),
                                            ),
                                          );
                                        }
                                      }
                                    : () {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Camera not available.',
                                            ),
                                          ),
                                        );
                                      }),
                          icon: const Icon(Icons.photo_camera),
                          label: const Text('Take photo'),
                        ),
                        TextButton(
                          onPressed: saving
                              ? null
                              : () {
                                  setState(() {
                                    avatarBytes = null;
                                    avatarMimeType = null;
                                    clearAvatar = true;
                                  });
                                },
                          child: const Text('Clear photo'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          setState(() => saving = true);
                          final error = await service.updateSelfVcard(
                            displayName: nameController.text,
                            avatarBytes: avatarBytes,
                            avatarMimeType: avatarMimeType,
                            clearAvatar: clearAvatar,
                          );
                          if (context.mounted) {
                            if (error != null) {
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(SnackBar(content: Text(error)));
                            } else {
                              Navigator.of(context).pop();
                            }
                          }
                          if (context.mounted) {
                            setState(() => saving = false);
                          }
                        },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOnline = service.isConnected;
    final latencyMs = service.lastPingLatency?.inMilliseconds;
    final latencyLabel = latencyMs == null ? '--' : '$latencyMs ms';
    final dotColor = _presenceDotColor(
      theme,
      service.selfPresence.showElement ??
          (service.isConnected ? PresenceShowElement.CHAT : null),
    );
    return FutureBuilder<bool>(
      future: _getSentryOptIn(),
      builder: (context, snapshot) {
        final sentryEnabled = snapshot.data ?? false;
        return PopupMenuButton<_PresenceAction>(
          tooltip: 'Set presence',
          icon: Icon(Icons.circle, color: dotColor),
          onSelected: (action) async {
            switch (action) {
              case _PresenceAction.online:
                service.setSelfPresence(
                  show: PresenceShowElement.CHAT,
                  status: service.selfPresence.status,
                );
                break;
              case _PresenceAction.away:
                service.setSelfPresence(
                  show: PresenceShowElement.AWAY,
                  status: service.selfPresence.status,
                );
                break;
              case _PresenceAction.dnd:
                service.setSelfPresence(
                  show: PresenceShowElement.DND,
                  status: service.selfPresence.status,
                );
                break;
              case _PresenceAction.xa:
                service.setSelfPresence(
                  show: PresenceShowElement.XA,
                  status: service.selfPresence.status,
                );
                break;
              case _PresenceAction.setStatus:
                final status = await _promptStatus(
                  context,
                  service.selfPresence.status ?? '',
                );
                if (status != null) {
                  service.setSelfPresence(
                    show:
                        service.selfPresence.showElement ??
                        PresenceShowElement.CHAT,
                    status: status,
                  );
                }
                break;
              case _PresenceAction.editProfile:
                await _editProfile(context);
                break;
              case _PresenceAction.clearCacheExit:
                onClearCacheExit?.call();
                break;
              case _PresenceAction.simulateDisconnect:
                service.simulateServerDisconnect();
                break;
              case _PresenceAction.keepaliveSettings:
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => KeepaliveSettingsScreen(
                      service: service,
                      preferences: preferences,
                    ),
                  ),
                );
                break;
              case _PresenceAction.csiAuto:
                service.setCsiOverrideMode(CsiOverrideMode.auto);
                break;
              case _PresenceAction.csiForceActive:
                service.setCsiOverrideMode(CsiOverrideMode.active);
                break;
              case _PresenceAction.csiForceInactive:
                service.setCsiOverrideMode(CsiOverrideMode.inactive);
                break;
              case _PresenceAction.toggleSentry:
                await _setSentryOptIn(context, !sentryEnabled);
                break;
              case _PresenceAction.exit:
                onExit();
                break;
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              enabled: false,
              child: Text('Session: ${isOnline ? 'online' : 'offline'}'),
            ),
            PopupMenuItem(
              enabled: false,
              child: Text('Latency: $latencyLabel'),
            ),
            PopupMenuItem(
              enabled: false,
              child: Text(
                'CSI: ${service.isCsiInactive ? 'inactive' : 'active'}',
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: _PresenceAction.online,
              child: Text('Online'),
            ),
            const PopupMenuItem(
              value: _PresenceAction.away,
              child: Text('Away'),
            ),
            const PopupMenuItem(
              value: _PresenceAction.dnd,
              child: Text('Do not disturb'),
            ),
            const PopupMenuItem(
              value: _PresenceAction.xa,
              child: Text('Extended away'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: _PresenceAction.setStatus,
              child: Text('Set status message...'),
            ),
            const PopupMenuItem(
              value: _PresenceAction.editProfile,
              child: Text('Edit profile...'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: _PresenceAction.csiAuto,
              child: Text(
                service.csiOverrideMode == CsiOverrideMode.auto
                    ? 'CSI override: Auto (current)'
                    : 'CSI override: Auto',
              ),
            ),
            PopupMenuItem(
              value: _PresenceAction.csiForceActive,
              child: Text(
                service.csiOverrideMode == CsiOverrideMode.active
                    ? 'CSI override: Force active (current)'
                    : 'CSI override: Force active',
              ),
            ),
            PopupMenuItem(
              value: _PresenceAction.csiForceInactive,
              child: Text(
                service.csiOverrideMode == CsiOverrideMode.inactive
                    ? 'CSI override: Force inactive (current)'
                    : 'CSI override: Force inactive',
              ),
            ),
            PopupMenuItem(
              value: _PresenceAction.toggleSentry,
              child: Text(
                sentryEnabled
                    ? 'Disable crash reporting'
                    : 'Enable crash reporting',
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: _PresenceAction.simulateDisconnect,
              child: Text('Simulate disconnect'),
            ),
            const PopupMenuItem(
              value: _PresenceAction.keepaliveSettings,
              child: Text('Keepalive settings...'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              enabled: onClearCacheExit != null,
              value: _PresenceAction.clearCacheExit,
              child: const Text('Clear Cache & Exit'),
            ),
            const PopupMenuItem(
              value: _PresenceAction.exit,
              child: Text('Exit'),
            ),
          ],
        );
      },
    );
  }
}

Future<Uint8List?> _capturePhotoViaWebRtc(BuildContext context) async {
  final renderer = RTCVideoRenderer();
  MediaStream? stream;
  try {
    await renderer.initialize();
    stream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': true,
    });
    renderer.srcObject = stream;
    if (!context.mounted) {
      return null;
    }
    Rect? cropRect;
    Size? previewSize;
    var cropScale = 0.7;
    final boundaryKey = GlobalKey();
    final result = await showDialog<Uint8List?>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Take photo'),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AspectRatio(
                      aspectRatio: 4 / 3,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final size = constraints.biggest;
                          if (previewSize != size) {
                            previewSize = size;
                            final side =
                                math.min(size.width, size.height) * cropScale;
                            cropRect ??= Rect.fromCenter(
                              center: Offset(size.width / 2, size.height / 2),
                              width: side,
                              height: side,
                            );
                          }
                          final rect = cropRect;
                          return RepaintBoundary(
                            key: boundaryKey,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  RTCVideoView(renderer, mirror: true),
                                  if (rect != null)
                                    Positioned.fill(
                                      child: CustomPaint(
                                        painter: _CropMaskPainter(rect),
                                      ),
                                    ),
                                  if (rect != null)
                                    Positioned.fromRect(
                                      rect: rect,
                                      child: GestureDetector(
                                        onPanUpdate: (details) {
                                          final current = cropRect;
                                          if (current == null ||
                                              previewSize == null) {
                                            return;
                                          }
                                          final next = current.shift(
                                            details.delta,
                                          );
                                          final bounds = Rect.fromLTWH(
                                            0,
                                            0,
                                            previewSize!.width,
                                            previewSize!.height,
                                          );
                                          final clamped = Rect.fromLTWH(
                                            next.left.clamp(
                                              bounds.left,
                                              bounds.right - next.width,
                                            ),
                                            next.top.clamp(
                                              bounds.top,
                                              bounds.bottom - next.height,
                                            ),
                                            next.width,
                                            next.height,
                                          );
                                          setState(() {
                                            cropRect = clamped;
                                          });
                                        },
                                        child: Container(
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Crop'),
                        Expanded(
                          child: Slider(
                            value: cropScale,
                            min: 0.4,
                            max: 1.0,
                            divisions: 6,
                            onChanged: (value) {
                              if (previewSize == null) {
                                return;
                              }
                              final size = previewSize!;
                              final center =
                                  cropRect?.center ??
                                  Offset(size.width / 2, size.height / 2);
                              final side =
                                  math.min(size.width, size.height) * value;
                              final rect = Rect.fromCenter(
                                center: center,
                                width: side,
                                height: side,
                              );
                              final bounds = Rect.fromLTWH(
                                0,
                                0,
                                size.width,
                                size.height,
                              );
                              final clamped = Rect.fromLTWH(
                                rect.left.clamp(
                                  bounds.left,
                                  bounds.right - rect.width,
                                ),
                                rect.top.clamp(
                                  bounds.top,
                                  bounds.bottom - rect.height,
                                ),
                                rect.width,
                                rect.height,
                              );
                              setState(() {
                                cropScale = value;
                                cropRect = clamped;
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final bytes = await _captureBoundaryPng(boundaryKey);
                    if (!context.mounted) {
                      return;
                    }
                    if (bytes == null || bytes.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Unable to capture photo.'),
                        ),
                      );
                      return;
                    }
                    final rect = cropRect;
                    final size = previewSize;
                    if (rect != null && size != null) {
                      final cropped = await _cropPngBytes(bytes, rect, size);
                      if (!context.mounted) {
                        return;
                      }
                      if (cropped != null && cropped.isNotEmpty) {
                        Navigator.of(context).pop(cropped);
                        return;
                      }
                    }
                    if (!context.mounted) {
                      return;
                    }
                    Navigator.of(context).pop(bytes);
                  },
                  child: const Text('Capture'),
                ),
              ],
            );
          },
        );
      },
    );
    return result;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Camera not available.')));
    }
    return null;
  } finally {
    renderer.srcObject = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
      await stream.dispose();
    }
    await renderer.dispose();
  }
}

Future<Uint8List?> _captureBoundaryPng(GlobalKey boundaryKey) async {
  final context = boundaryKey.currentContext;
  if (context == null) {
    return null;
  }
  final boundary = context.findRenderObject();
  if (boundary is! RenderRepaintBoundary) {
    return null;
  }
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}

Future<Uint8List?> _cropPngBytes(
  Uint8List bytes,
  Rect cropRect,
  Size renderSize,
) async {
  if (bytes.isEmpty || renderSize.width == 0 || renderSize.height == 0) {
    return null;
  }
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final scaleX = image.width / renderSize.width;
  final scaleY = image.height / renderSize.height;
  final src =
      Rect.fromLTRB(
        cropRect.left * scaleX,
        cropRect.top * scaleY,
        cropRect.right * scaleX,
        cropRect.bottom * scaleY,
      ).intersect(
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      );
  if (src.width <= 0 || src.height <= 0) {
    return null;
  }
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final dst = Rect.fromLTWH(0, 0, src.width, src.height);
  canvas.drawImageRect(image, src, dst, Paint());
  final picture = recorder.endRecording();
  final cropped = await picture.toImage(src.width.round(), src.height.round());
  final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}

Future<Uint8List?> _readPickedFileBytes(PlatformFile file) async {
  if (file.bytes != null) {
    return file.bytes;
  }
  final path = file.path;
  if (path == null || path.isEmpty) {
    return null;
  }
  try {
    return await File(path).readAsBytes();
  } catch (_) {
    return null;
  }
}

String? _guessImageMimeType(String fileName) {
  final parts = fileName.toLowerCase().split('.');
  if (parts.length < 2) {
    return null;
  }
  switch (parts.last) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    default:
      return null;
  }
}

enum _PresenceAction {
  online,
  away,
  dnd,
  xa,
  setStatus,
  editProfile,
  csiAuto,
  csiForceActive,
  csiForceInactive,
  toggleSentry,
  simulateDisconnect,
  keepaliveSettings,
  clearCacheExit,
  exit,
}

Future<String?> _promptStatus(BuildContext context, String current) async {
  final controller = TextEditingController(text: current);
  String? result;
  await showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Status message'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Message'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              result = controller.text.trim();
              Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
  controller.dispose();
  return result;
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _CropMaskPainter extends CustomPainter {
  _CropMaskPainter(this.cropRect);

  final Rect cropRect;

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = Paint()..color = Colors.black.withValues(alpha: 0.45);
    final clear = Paint()..blendMode = BlendMode.clear;
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, overlay);
    canvas.drawRect(cropRect, clear);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CropMaskPainter oldDelegate) {
    return oldDelegate.cropRect != cropRect;
  }
}

class _PinSetupScreen extends StatefulWidget {
  const _PinSetupScreen({required this.onPinSet, required this.preferences});

  final Future<void> Function(String pin, {required bool ignored}) onPinSet;
  final PreferencesService preferences;

  @override
  State<_PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<_PinSetupScreen> {
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  String? _error;
  bool _submitting = false;
  bool _sentryOptIn = false;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Set a PIN', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 12),
                Text(
                  'Your PIN encrypts local storage for messages, passwords, and other account data.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'You can continue without a PIN, but device access will allow access to local data.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _pinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'PIN'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirmController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Confirm PIN'),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _sentryOptIn,
                  title: const Text('Share crash reports'),
                  subtitle: const Text(
                    'Help improve Wimsy by sending anonymized crash reports.',
                  ),
                  onChanged: _submitting
                      ? null
                      : (value) => setState(() => _sentryOptIn = value),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: Text(_submitting ? 'Setting...' : 'Set PIN'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _submitting ? null : _continueWithoutPin,
                  child: const Text('Continue without PIN'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final pin = _pinController.text.trim();
    final confirm = _confirmController.text.trim();
    if (pin.isEmpty || pin.length < 4) {
      setState(() => _error = 'Choose a PIN with at least 4 digits.');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'PIN entries do not match.');
      return;
    }
    setState(() {
      _error = null;
      _submitting = true;
    });
    try {
      await widget.preferences.setSentryOptIn(_sentryOptIn);
      await widget.onPinSet(pin, ignored: false);
      if (_sentryOptIn && mounted) {
        await _enableSentryAndRestart();
      }
    } catch (error) {
      setState(() => _error = 'Failed to set PIN: $error');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _continueWithoutPin() async {
    setState(() {
      _error = null;
      _submitting = true;
    });
    try {
      await widget.preferences.setSentryOptIn(_sentryOptIn);
      await widget.onPinSet('0000', ignored: true);
      if (_sentryOptIn && mounted) {
        await _enableSentryAndRestart();
      }
    } catch (error) {
      setState(() => _error = 'Failed to continue without PIN: $error');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }
}

class _PinUnlockScreen extends StatefulWidget {
  const _PinUnlockScreen({
    required this.onUnlocked,
    required this.pinIgnored,
    required this.preferences,
  });

  final Future<void> Function(String pin) onUnlocked;
  final bool pinIgnored;
  final PreferencesService preferences;

  @override
  State<_PinUnlockScreen> createState() => _PinUnlockScreenState();
}

class _PinUnlockScreenState extends State<_PinUnlockScreen> {
  final TextEditingController _pinController = TextEditingController();
  String? _error;
  bool _submitting = false;
  bool _sentryOptIn = false;
  bool _loadedSentryPref = false;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Unlock', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 12),
                if (!widget.pinIgnored)
                  TextField(
                    controller: _pinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'PIN'),
                    onSubmitted: (_) => _submit(),
                  )
                else
                  Text(
                    'Unlocked automatically because PIN was skipped on first run.',
                    style: theme.textTheme.bodyMedium,
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: Text(
                    _submitting
                        ? 'Unlocking...'
                        : (widget.pinIgnored ? 'Continue' : 'Unlock'),
                  ),
                ),
                if (_loadedSentryPref && !_sentryOptIn) ...[
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _sentryOptIn,
                    title: const Text('Share crash reports'),
                    subtitle: const Text(
                      'Help improve Wimsy by sending anonymized crash reports.',
                    ),
                    onChanged: _submitting
                        ? null
                        : (value) => setState(() => _sentryOptIn = value),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final pin = widget.pinIgnored ? '0000' : _pinController.text.trim();
    if (!widget.pinIgnored && pin.isEmpty) {
      setState(() => _error = 'Enter your PIN.');
      return;
    }
    setState(() {
      _error = null;
      _submitting = true;
    });
    try {
      final existingOptIn = widget.preferences.sentryOptIn;
      if (_sentryOptIn && !existingOptIn) {
        await widget.preferences.setSentryOptIn(true);
      }
      await widget.onUnlocked(pin);
      if (_sentryOptIn && !existingOptIn && mounted) {
        await _enableSentryAndRestart();
      }
    } catch (_) {
      setState(() => _error = 'Incorrect PIN.');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _loadSentryOptIn();
  }

  Future<void> _loadSentryOptIn() async {
    final existing = widget.preferences.sentryOptIn;
    if (!mounted) {
      return;
    }
    setState(() {
      _sentryOptIn = existing;
      _loadedSentryPref = true;
    });
  }
}

class _CallVideoView extends StatefulWidget {
  const _CallVideoView({
    required this.stream,
    required this.mirrored,
    required this.placeholder,
  });

  final MediaStream? stream;
  final bool mirrored;
  final String placeholder;

  @override
  State<_CallVideoView> createState() => _CallVideoViewState();
}

class _CallVideoViewState extends State<_CallVideoView> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _renderer.initialize();
    if (!mounted) {
      return;
    }
    _renderer.srcObject = widget.stream;
    setState(() {
      _initialized = true;
    });
  }

  @override
  void didUpdateWidget(covariant _CallVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_renderer.srcObject != widget.stream) {
      _renderer.srcObject = widget.stream;
    }
  }

  @override
  void dispose() {
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_initialized || widget.stream == null) {
      return Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(
          widget.placeholder,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: RTCVideoView(
        _renderer,
        mirror: widget.mirrored,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      ),
    );
  }
}

class _SpeakingFrame extends StatelessWidget {
  const _SpeakingFrame({
    required this.child,
    required this.active,
    required this.color,
  });

  final Widget child;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active ? color : theme.colorScheme.outlineVariant,
          width: active ? 2 : 1,
        ),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: child),
    );
  }
}

class _SpeakingPill extends StatelessWidget {
  const _SpeakingPill({
    required this.label,
    required this.active,
    required this.color,
  });

  final String label;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active
            ? color.withAlpha(31)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? color : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: active ? color : theme.colorScheme.outlineVariant,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _QuicStatsGraph extends StatelessWidget {
  const _QuicStatsGraph({
    required this.label,
    required this.data,
    required this.color,
    required this.unit,
    this.showAverage = false,
  });

  final String label;
  final List<int> data;
  final Color color;
  final String unit;
  final bool showAverage;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const SizedBox.shrink();
    final value = showAverage
        ? formatGraphAverage(graphAverage(data)!)
        : data.last.toString();
    final description = showAverage ? '$label average' : label;
    final theme = Theme.of(context);
    return Tooltip(
      message: '$description: $value$unit',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '$value$unit',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 8,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 1),
          Container(
            width: 36,
            height: 12,
            decoration: BoxDecoration(
              border: Border.all(
                color: theme.colorScheme.outlineVariant,
                width: 0.5,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
            child: CustomPaint(
              painter: _SparklinePainter(data: data, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.data, required this.color});

  final List<int> data;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final maxVal = data.reduce((a, b) => a > b ? a : b).toDouble();
    final minVal = data.reduce((a, b) => a < b ? a : b).toDouble();
    final range = (maxVal - minVal).clamp(1.0, double.infinity);

    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - ((data[i] - minVal) / range * size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.data != data;
}
