import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:xmpp_stone/xmpp_stone.dart';
import 'package:url_launcher/url_launcher.dart';

import 'av/call_session.dart';
import 'models/chat_message.dart';
import 'models/contact_entry.dart';
import 'models/room_entry.dart';
import 'notifications/notification_service.dart';
import 'storage/account_record.dart';
import 'storage/storage_service.dart';
import 'xmpp/xmpp_service.dart';
import 'background/foreground_task_handler.dart';
import 'utils/xep0392_color.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

const String _sentryOptInKey = 'sentry_opt_in';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Log.logLevel = LogLevel.VERBOSE;
  Log.logXmpp = true;
  final prefs = await SharedPreferences.getInstance();
  final optIn = prefs.getBool(_sentryOptInKey) ?? false;
  await _startApp(sentryEnabled: optIn);
}

const bool _isFlutterTest = bool.fromEnvironment('FLUTTER_TEST');

Future<void> _startApp({required bool sentryEnabled}) async {
  if (sentryEnabled) {
    await SentryFlutter.init(
      (options) {
        options.dsn = 'https://7d58998fe2d0e488aa5f11020778c9f6@sentry.cridland.io/8';
        options.tracesSampleRate = 1.0;
      },
      appRunner: () {
        Connection.errorReporter = (error, stackTrace) {
          Sentry.captureException(error, stackTrace: stackTrace);
        };
        runApp(SentryWidget(child: const WimsyApp()));
      },
    );
    return;
  }
  Connection.errorReporter = null;
  runApp(const WimsyApp());
}

Future<void> _enableSentryAndRestart() async {
  if (Sentry.isEnabled) {
    return;
  }
  await _startApp(sentryEnabled: true);
}

Future<void> _restartWithoutSentry() async {
  if (!Sentry.isEnabled) {
    return;
  }
  await _startApp(sentryEnabled: false);
}

class WimsyApp extends StatefulWidget {
  const WimsyApp({super.key});

  @override
  State<WimsyApp> createState() => _WimsyAppState();
}

class _WimsyAppState extends State<WimsyApp> with WidgetsBindingObserver {
  final XmppService _service = XmppService();
  final StorageService _storage = StorageService();
  final NotificationService _notifications = NotificationService();
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _appIsForeground = true;
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!_isFlutterTest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notifications.initialize();
      });
      _service.setIncomingMessageHandler(_handleIncomingMessage);
      _service.setIncomingRoomMessageHandler(_handleIncomingRoomMessage);
      if (Platform.isAndroid) {
        _startAndroidForegroundService();
        _connectivitySubscription =
            _connectivity.onConnectivityChanged.listen((results) {
          final online = results.any((result) => result != ConnectivityResult.none);
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
    _service.dispose();
    _storage.lock();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsForeground = state == AppLifecycleState.resumed;
    if (Platform.isAndroid) {
      _service.setBackgroundMode(state != AppLifecycleState.resumed);
    }
  }

  void _handleIncomingMessage(String bareJid, ChatMessage message) {
    if (!_shouldNotifyFor(bareJid)) {
      return;
    }
    if (!_service.isMessageUnseen(bareJid, message)) {
      return;
    }
    final title = _service.displayNameFor(bareJid);
    _notifications.showMessage(
      id: DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
      title: title,
      body: message.body,
      tag: bareJid,
    );
  }

  void _handleIncomingRoomMessage(String roomJid, ChatMessage message) {
    if (!_shouldNotifyFor(roomJid)) {
      return;
    }
    if (!_service.isMessageUnseen(roomJid, message)) {
      return;
    }
    final title = '$roomJid • ${message.from}';
    _notifications.showMessage(
      id: DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
      title: title,
      body: message.body,
      tag: roomJid,
    );
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

    FlutterForegroundTask.setTaskHandler(WimsyForegroundTaskHandler());

    final running = await FlutterForegroundTask.isRunningService;
    if (!running) {
      await FlutterForegroundTask.startService(
        notificationTitle: 'Wimsy is running',
        notificationText: 'Keeping your XMPP session connected.',
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
          fontFamily: 'Georgia',
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
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
          home: FutureBuilder<void>(
            future: _initFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const _SplashScreen();
              }
              return _Gatekeeper(service: _service, storage: _storage);
            },
          ),
        ),
      ),
    );
  }
}

class _Gatekeeper extends StatefulWidget {
  const _Gatekeeper({required this.service, required this.storage});

  final XmppService service;
  final StorageService storage;

  @override
  State<_Gatekeeper> createState() => _GatekeeperState();
}

class _GatekeeperState extends State<_Gatekeeper> {
  bool _checkingPin = true;
  bool _hasPin = false;

  @override
  void initState() {
    super.initState();
    _loadPinState();
  }

  Future<void> _loadPinState() async {
    final hasPin = await widget.storage.hasPin();
    if (!mounted) {
      return;
    }
    setState(() {
      _hasPin = hasPin;
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
        onPinSet: (pin) async {
          await widget.storage.setupPin(pin);
          if (!mounted) {
            return;
          }
          setState(() {
            _hasPin = true;
          });
        },
      );
    }
    if (!widget.storage.isUnlocked) {
      return _PinUnlockScreen(
        onUnlocked: (pin) async {
          await widget.storage.unlock(pin);
          if (!mounted) {
            return;
          }
          setState(() {});
        },
      );
    }
    return WimsyHome(service: widget.service, storage: widget.storage);
  }
}

class WimsyHome extends StatefulWidget {
  const WimsyHome({super.key, required this.service, required this.storage});

  final XmppService service;
  final StorageService storage;

  @override
  State<WimsyHome> createState() => _WimsyHomeState();
}

class _WimsyHomeState extends State<WimsyHome> {
  final TextEditingController _jidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: '5222');
  final TextEditingController _resourceController = TextEditingController(text: 'wimsy');
  final TextEditingController _wsEndpointController = TextEditingController();
  final TextEditingController _wsProtocolsController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  final ScrollController _messageScrollController = ScrollController();
  final Map<String, DateTime> _lastReadAtByChat = {};
  bool _loadedAccount = false;
  bool _clearingCache = false;
  bool _rememberPassword = false;
  bool _useWebSocket = kIsWeb;
  bool _useDirectTls = false;
  Timer? _typingDebounce;
  Timer? _idleTimer;
  ChatState? _lastSentChatState;
  String? _lastFocusedChat;
  int _lastMessageCount = 0;
  bool _wasAtBottom = true;
  String? _editingMessageId;
  String? _editingChatBareJid;
  bool _editingIsRoom = false;
  String? _activeChatForKeyHandler;
  bool _activeChatIsBookmark = false;
  bool _activeChatRoomJoined = false;

  @override
  void initState() {
    super.initState();
    _messageScrollController.addListener(_handleScrollPosition);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    widget.service.attachStorage(widget.storage);
    widget.service.setRosterPersistor((roster) => widget.storage.storeRoster(roster));
    widget.service.setBookmarkPersistor((bookmarks) => widget.storage.storeBookmarks(bookmarks));
    widget.service.setMessagePersistor(
      (bareJid, messages) => widget.storage.storeMessagesForJid(bareJid, messages),
    );
    widget.service.setRoomMessagePersistor(
      (roomJid, messages) => widget.storage.storeRoomMessagesForJid(roomJid, messages),
    );
    _seedRoster();
    _seedBookmarks();
    _seedMessages();
    _seedRoomMessages();
    _loadAccount();
  }

  Future<void> _seedRoster() async {
    final roster = widget.storage.loadRoster();
    widget.service.seedRoster(roster);
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

  Future<void> _loadAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedJid = prefs.getString('wimsy_last_jid');
    final account = AccountRecord.fromMap(widget.storage.loadAccount());
    if (!mounted) {
      return;
    }
    setState(() {
      if (cachedJid != null && cachedJid.isNotEmpty) {
        _jidController.text = cachedJid;
      }
      if (account != null) {
        _jidController.text = account.jid;
        _rememberPassword = account.rememberPassword;
        if (_rememberPassword) {
          _passwordController.text = account.password;
        } else {
          _passwordController.clear();
        }
        _hostController.text = account.host;
        _portController.text = account.port.toString();
        _resourceController.text = account.resource;
        _useWebSocket = kIsWeb ? true : account.useWebSocket;
        _useDirectTls = kIsWeb ? false : account.directTls;
        _wsEndpointController.text = account.wsEndpoint;
        if (account.wsProtocols.isNotEmpty) {
          _wsProtocolsController.text = account.wsProtocols.join(', ');
        } else {
          _wsProtocolsController.clear();
        }
      }
      _loadedAccount = true;
    });
  }

  @override
  void dispose() {
    _typingDebounce?.cancel();
    _idleTimer?.cancel();
    _messageScrollController.removeListener(_handleScrollPosition);
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _messageFocusNode.dispose();
    _messageScrollController.dispose();
    _jidController.dispose();
    _passwordController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _resourceController.dispose();
    _wsEndpointController.dispose();
    _wsProtocolsController.dispose();
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
          return _buildLogin(context, service);
        }
        return _buildClient(context, service);
      },
    );
  }

  Widget _buildLogin(BuildContext context, XmppService service) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final stateLabel = service.lastConnectionState?.name ?? 'Idle';

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF7E7CE), Color(0xFFE3F0F1), Color(0xFFFDFBF7)],
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: size.width > 640 ? 520 : double.infinity),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Wimsy',
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w300,
                      letterSpacing: 1.2,
                      color: const Color(0xFFA97BFF),
                      fontFamily: 'SF Pro Display',
                      fontFamilyFallback: const ['Helvetica Neue', 'Arial', 'Roboto'],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'A modern XMPP client built for secure servers.',
                    style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 24,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Connect', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _jidController,
                          enabled: !service.isConnecting,
                          decoration: const InputDecoration(
                            labelText: 'JID',
                            hintText: 'user@domain',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _passwordController,
                          enabled: !service.isConnecting,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Password',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: _hostController,
                                enabled: !service.isConnecting,
                                decoration: const InputDecoration(
                                  labelText: 'Host (optional)',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: _portController,
                                enabled: !service.isConnecting,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Port',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('Direct TLS (XEP-0368)'),
                          subtitle: const Text('Uses direct TLS when the server advertises it via SRV.'),
                          value: _useDirectTls,
                          onChanged: service.isConnecting || kIsWeb
                              ? null
                              : (value) {
                                  if (value == null) {
                                    return;
                                  }
                                  setState(() {
                                    _useDirectTls = value;
                                  });
                                },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _resourceController,
                          enabled: !service.isConnecting,
                          decoration: const InputDecoration(
                            labelText: 'Resource',
                          ),
                        ),
                        const SizedBox(height: 12),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('Remember password on this device'),
                          value: _rememberPassword,
                          onChanged: service.isConnecting
                              ? null
                              : (value) {
                                  if (value == null) {
                                    return;
                                  }
                                  setState(() {
                                    _rememberPassword = value;
                                  });
                                },
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('Use WebSocket transport'),
                          subtitle: kIsWeb
                              ? const Text('Required for web builds.')
                              : const Text('Useful for testing server WebSocket support.'),
                          value: kIsWeb ? true : _useWebSocket,
                          onChanged: service.isConnecting || kIsWeb
                              ? null
                              : (value) {
                                  if (value == null) {
                                    return;
                                  }
                                  setState(() {
                                    _useWebSocket = value;
                                  });
                                },
                        ),
                        if (_useWebSocket || kIsWeb) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _wsEndpointController,
                            enabled: !service.isConnecting,
                            decoration: const InputDecoration(
                              labelText: 'WebSocket endpoint',
                              hintText: 'wss://host/xmpp-websocket',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _wsProtocolsController,
                            enabled: !service.isConnecting,
                            decoration: const InputDecoration(
                              labelText: 'WebSocket subprotocols (optional)',
                              hintText: 'xmpp, stanza',
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: service.isConnecting ? null : _handleConnect,
                                child: Text(service.isConnecting ? 'Connecting...' : 'Connect'),
                              ),
                            ),
                          ],
                        ),
                        if (!_loadedAccount) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Unlocking storage...',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          'Status: ${service.status.name} · $stateLabel',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (service.errorMessage != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            service.errorMessage!,
                            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                          ),
                        ]
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildClient(BuildContext context, XmppService service) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 900;
        final activeChat = service.activeChatBareJid;

        return Scaffold(
          appBar: AppBar(
            title: Text('Signed in as ${service.currentUserBareJid ?? ''}'),
            actions: [
              _PresenceMenu(
                service: service,
                onClearCacheExit: _clearingCache ? null : _confirmClearCacheAndExit,
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
                    : _buildChatPane(
                        context,
                        service,
                        activeChat,
                        showBack: true,
                      ),
          ),
        );
      },
    );
  }

  Widget _buildRosterPane(BuildContext context, XmppService service, {required bool isWide}) {
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
                    onPressed: () => _showContactDialog(),
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Add contact'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showJoinRoomDialog(),
                    icon: const Icon(Icons.meeting_room_outlined),
                    label: const Text('Join room'),
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
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      itemCount: contacts.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 8),
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
                            statusText != null && statusText.toLowerCase() == 'unavailable'
                                ? null
                                : statusText;
                        final show = (statusText != null && statusText.toLowerCase() == 'unavailable')
                            ? null
                            : (presence?.showElement ?? (presence != null ? PresenceShowElement.CHAT : null));
                        final dotColor = _presenceDotColor(theme, show);
                        final avatarBytes = service.avatarBytesFor(jid);
                        final messages = isBookmark
                            ? service.roomMessagesFor(jid)
                            : service.messagesFor(jid);
                        DateTime? lastIncomingTime;
                        for (var i = messages.length - 1; i >= 0; i--) {
                          if (!messages[i].outgoing) {
                            lastIncomingTime = messages[i].timestamp;
                            break;
                          }
                        }
                        final lastReadAt = service.displayedAtFor(jid) ?? _lastReadAtByChat[jid];
                        final isUnread = lastIncomingTime != null &&
                            (lastReadAt == null || lastIncomingTime.isAfter(lastReadAt));
                        final bookmarkStatusText = contact.bookmarkNick?.isNotEmpty == true
                            ? 'Nickname: ${contact.bookmarkNick}'
                            : (contact.bookmarkAutoJoin ? 'Auto-join room' : 'Room bookmark');
                        return InkWell(
                          onTap: () => service.selectChat(jid),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isBookmark
                                    ? theme.colorScheme.primary.withValues(alpha: 0.35)
                                    : theme.colorScheme.outlineVariant,
                              ),
                            ),
                            child: Opacity(
                              opacity: isServerNotFound ? 0.5 : 1.0,
                              child: Row(
                                children: [
                                  Stack(
                                    children: [
                                      _AvatarPlaceholder(label: contact.displayName, bytes: avatarBytes),
                                      if (isBookmark)
                                        Positioned(
                                          right: 0,
                                          bottom: 0,
                                          child: Container(
                                            padding: const EdgeInsets.all(2),
                                            decoration: BoxDecoration(
                                              color: theme.colorScheme.surface,
                                              shape: BoxShape.circle,
                                              border: Border.all(color: theme.colorScheme.primary, width: 1.2),
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
                                              border: Border.all(color: theme.colorScheme.surface, width: 2),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                contact.displayName,
                                                style: theme.textTheme.titleMedium?.copyWith(
                                                  fontWeight: isUnread ? FontWeight.w600 : null,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (isBookmark) ...[
                                              const SizedBox(width: 6),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                                                  borderRadius: BorderRadius.circular(10),
                                                ),
                                                child: Text(
                                                  'ROOM',
                                                  style: theme.textTheme.labelSmall?.copyWith(
                                                    color: theme.colorScheme.primary,
                                                    letterSpacing: 0.6,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        if (contact.displayName != jid) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            jid,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodySmall?.copyWith(
                                              color: theme.colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 2),
                                        Text(
                                          isBookmark
                                              ? bookmarkStatusText
                                              : ((effectiveStatusText?.isNotEmpty == true)
                                                  ? effectiveStatusText!
                                                  : service.presenceLabelFor(jid)),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: theme.colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                        if (latest != null) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            _messagePreviewText(service, latest),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodySmall?.copyWith(
                                              color: theme.colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                        if (!isBookmark && contact.groups.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            contact.groups.map((group) => '#${group.trim()}').join(' '),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.labelSmall?.copyWith(
                                              color: theme.colorScheme.primary,
                                              letterSpacing: 0.2,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  _ContactActionsMenu(
                                    isBookmark: isBookmark,
                                    isBlocked: service.isBlocked(jid),
                                    onEditContact: () => _showContactDialog(contact: contact),
                                    onRemoveContact: () => _confirmRemoveContact(contact),
                                    onBlockContact: () => _blockContact(contact),
                                    onUnblockContact: () => _unblockContact(contact),
                                    onEditBookmark: () => _showBookmarkDialog(contact),
                                    onRemoveBookmark: () => _confirmRemoveBookmark(contact),
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
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildChatPane(
    BuildContext context,
    XmppService service,
    String? activeChat,
    {
    required bool showBack,
  }) {
    final theme = Theme.of(context);
    final isBookmark = activeChat != null && service.isBookmark(activeChat);
    final messages = activeChat == null
        ? const <ChatMessage>[]
        : isBookmark
            ? service.roomMessagesFor(activeChat)
            : service.messagesFor(activeChat);
    final roomEntry = activeChat == null ? null : service.roomFor(activeChat);
    _activeChatForKeyHandler = activeChat;
    _activeChatIsBookmark = isBookmark;
    _activeChatRoomJoined = roomEntry?.joined ?? false;
    _handleAutoScroll(messages.length);
    if (activeChat != null) {
      _markChatRead(activeChat, messages);
    }
    if (activeChat == null) {
      _lastFocusedChat = null;
      _lastMessageCount = 0;
      if (_editingChatBareJid != null) {
        _cancelEditing();
      }
    } else if (activeChat != _lastFocusedChat) {
      _lastFocusedChat = activeChat;
      _lastMessageCount = messages.length;
      _markChatRead(activeChat, messages);
      if (_editingChatBareJid != null && _editingChatBareJid != activeChat) {
        _cancelEditing();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          if (!isBookmark) {
            _messageFocusNode.requestFocus();
          }
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
                  IconButton(
                    onPressed: service.callSessionFor(activeChat) != null
                        ? null
                        : () => _startCall(activeChat, video: false),
                    icon: const Icon(Icons.call),
                    tooltip: 'Start voice call',
                  ),
                  IconButton(
                    onPressed: service.callSessionFor(activeChat) != null
                        ? null
                        : () => _startCall(activeChat, video: true),
                    icon: const Icon(Icons.videocam),
                    tooltip: 'Start video call',
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
          const Divider(height: 1),
          Expanded(
            child: activeChat == null
                ? Center(
                    child: Text(
                      'Pick a contact to start messaging.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    controller: _messageScrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final senderName = isBookmark
                          ? (message.outgoing ? 'You' : message.from)
                          : message.outgoing
                              ? 'You'
                              : service.displayNameFor(message.from);
                      final timestamp = _formatTimestamp(message.timestamp);
                      final avatarBytes = isBookmark ? null : service.avatarBytesFor(message.from);
                      final inviteRoomJid = message.inviteRoomJid;
                      final inviteRoomName = inviteRoomJid == null || inviteRoomJid.isEmpty
                          ? null
                          : service.displayNameFor(inviteRoomJid);
                      final inviteAvatarBytes = inviteRoomJid == null || inviteRoomJid.isEmpty
                          ? null
                          : service.avatarBytesFor(inviteRoomJid);
                      final joinRoom = (inviteRoomJid != null &&
                              inviteRoomJid.isNotEmpty &&
                              !message.outgoing)
                          ? () => service.joinRoom(inviteRoomJid, password: message.invitePassword)
                          : null;
                      return _MessageBubble(
                        message: message,
                        senderName: senderName,
                        timestamp: timestamp,
                        avatarBytes: avatarBytes,
                        inviteRoomJid: inviteRoomJid,
                        inviteRoomName: inviteRoomName,
                        inviteAvatarBytes: inviteAvatarBytes,
                        inviteReason: message.inviteReason,
                        onJoinInvite: joinRoom,
                        onReact: (emoji) {
                          service.sendReaction(
                            bareJid: activeChat,
                            message: message,
                            emoji: emoji,
                            isRoom: isBookmark,
                          );
                        },
                        onEdit: (message.outgoing && (message.messageId ?? '').isNotEmpty)
                            ? () => _startEditingMessage(
                                  activeChat: activeChat,
                                  message: message,
                                  isRoom: isBookmark,
                                )
                            : null,
                        onAcceptFile: (!isBookmark &&
                                !message.outgoing &&
                                (message.fileTransferId ?? '').isNotEmpty &&
                                message.fileState == 'offered')
                            ? () => _promptAcceptFileTransfer(activeChat, message)
                            : null,
                        onDeclineFile: (!isBookmark &&
                                !message.outgoing &&
                                (message.fileTransferId ?? '').isNotEmpty &&
                                message.fileState == 'offered')
                            ? () => _declineFileTransfer(message)
                            : null,
                        onFallbackUpload: (!isBookmark &&
                                message.outgoing &&
                                (message.fileTransferId ?? '').isNotEmpty &&
                                (message.fileState == 'failed' || message.fileState == 'declined'))
                            ? () => _fallbackFileTransfer(message)
                            : null,
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
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
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        focusNode: _messageFocusNode,
                        autofocus: activeChat != null && (!isBookmark || (roomEntry?.joined ?? false)),
                        enabled: activeChat != null && (!isBookmark || (roomEntry?.joined ?? false)),
                        decoration: const InputDecoration(
                          labelText: 'Message',
                        ),
                        onChanged: (value) {
                          if (activeChat == null || isBookmark) {
                            return;
                          }
                          _handleTypingState(service, activeChat, value);
                        },
                        onSubmitted: (_) => _sendMessage(activeChat),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: activeChat == null || (isBookmark && !(roomEntry?.joined ?? false))
                          ? null
                          : () => _sendAttachment(
                                activeChat,
                                isBookmark: isBookmark,
                                roomEntry: roomEntry,
                              ),
                      icon: const Icon(Icons.attach_file),
                      tooltip: 'Send file',
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: activeChat == null || (isBookmark && !(roomEntry?.joined ?? false))
                          ? null
                          : () => _sendMessage(activeChat),
                      child: const Text('Send'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _handleConnect() {
    final port = int.tryParse(_portController.text.trim()) ?? 5222;
    final useWebSocket = kIsWeb || _useWebSocket;
    final useDirectTls = kIsWeb ? false : _useDirectTls;
    final wsProtocols = _wsProtocolsController.text
        .split(',')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList();
    final account = AccountRecord(
      jid: _jidController.text.trim(),
      password: _rememberPassword ? _passwordController.text : '',
      host: _hostController.text.trim(),
      port: port,
      resource: _resourceController.text.trim().isEmpty ? 'wimsy' : _resourceController.text.trim(),
      rememberPassword: _rememberPassword,
      useWebSocket: useWebSocket,
      directTls: useDirectTls,
      wsEndpoint: _wsEndpointController.text.trim(),
      wsProtocols: wsProtocols,
    );
    widget.storage.storeAccount(account.toMap());
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('wimsy_last_jid', account.jid);
    });
    widget.service.connect(
      jid: account.jid,
      password: _passwordController.text,
      resource: account.resource,
      host: account.host,
      port: port,
      useWebSocket: useWebSocket,
      directTls: useDirectTls,
      wsEndpoint: account.wsEndpoint,
      wsProtocols: wsProtocols,
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
      widget.service.sendRoomMessage(activeChat, trimmed);
    } else {
      widget.service.sendMessage(toBareJid: activeChat, text: trimmed);
      _setChatState(activeChat, ChatState.ACTIVE);
    }
    if (_messageFocusNode.canRequestFocus) {
      _messageFocusNode.requestFocus();
    }
  }

  Future<void> _startCall(String bareJid, {required bool video}) async {
    final result = await widget.service.startCall(bareJid: bareJid, video: video);
    if (!mounted || result == null) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result)),
    );
  }

  Future<void> _acceptCall(CallSession session) async {
    await widget.service.acceptCall(session);
  }

  Future<void> _declineCall(CallSession session) async {
    await widget.service.declineCall(session);
  }

  Future<void> _endCall(CallSession session) async {
    await widget.service.endCall(session);
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
      _startEditingMessage(activeChat: activeChat, message: message, isRoom: isRoom);
      break;
    }
  }

  Widget _buildCallBanner(XmppService service, String bareJid) {
    final session = service.callSessionFor(bareJid);
    if (session == null) {
      return const SizedBox.shrink();
    }
    if (session.state != CallState.ringing && session.state != CallState.active) {
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
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
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
                      child: _CallVideoView(
                        stream: remoteStream ?? localStream,
                        mirrored: false,
                        placeholder: 'Remote video',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _CallVideoView(
                        stream: localStream,
                        mirrored: true,
                        placeholder: 'Local preview',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _sendAttachment(String? activeChat, {required bool isBookmark, RoomEntry? roomEntry}) async {
    if (activeChat == null) {
      return;
    }
    if (isBookmark && !(roomEntry?.joined ?? false)) {
      return;
    }
    final selection = await FilePicker.platform.pickFiles(withData: true);
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

  Future<void> _promptAcceptFileTransfer(String activeChat, ChatMessage message) async {
    final transferId = message.fileTransferId;
    if (transferId == null || transferId.isEmpty) {
      return;
    }
    final suggested = message.fileName?.isNotEmpty == true ? message.fileName! : 'file';
    final path = await FilePicker.platform.saveFile(
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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
    final groupsController = TextEditingController(text: contact?.groups.join(' ') ?? '');
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
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                  ),
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
    }
  }

  Future<void> _showBookmarkDialog(ContactEntry bookmark) async {
    final jidController = TextEditingController(text: bookmark.jid);
    final nameController = TextEditingController(text: bookmark.name ?? '');
    final nickController = TextEditingController(text: bookmark.bookmarkNick ?? '');
    final passwordController = TextEditingController(text: bookmark.bookmarkPassword ?? '');
    var autoJoin = bookmark.bookmarkAutoJoin;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          return AlertDialog(
            title: const Text('Edit bookmark'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: jidController,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Room JID',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Room name',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nickController,
                    decoration: const InputDecoration(
                      labelText: 'Nickname',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passwordController,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    value: autoJoin,
                    onChanged: (value) => setState(() => autoJoin = value),
                    title: const Text('Auto-join'),
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
        });
      },
    );
    if (result != true) {
      return;
    }
    final updated = ContactEntry(
      jid: bookmark.jid,
      name: nameController.text.trim().isNotEmpty ? nameController.text.trim() : null,
      groups: const [],
      isBookmark: true,
      bookmarkNick: nickController.text.trim().isNotEmpty ? nickController.text.trim() : null,
      bookmarkPassword: passwordController.text.trim().isNotEmpty
          ? passwordController.text.trim()
          : null,
      bookmarkAutoJoin: autoJoin,
    );
    final ok = await widget.service.upsertBookmark(updated);
    if (!ok) {
      _showSnack('Failed to save bookmark.');
    }
  }

  Future<void> _showJoinRoomDialog() async {
    final jidController = TextEditingController();
    final nickController = TextEditingController();
    final passwordController = TextEditingController();
    final nameController = TextEditingController();
    var saveBookmark = false;
    var autoJoin = false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          return AlertDialog(
            title: const Text('Join room'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: jidController,
                    decoration: const InputDecoration(
                      labelText: 'Room JID',
                      hintText: 'room@conference.example.com',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nickController,
                    decoration: const InputDecoration(
                      labelText: 'Nickname (optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passwordController,
                    decoration: const InputDecoration(
                      labelText: 'Password (optional)',
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    value: saveBookmark,
                    onChanged: (value) => setState(() => saveBookmark = value),
                    title: const Text('Save bookmark'),
                  ),
                  if (saveBookmark) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Room name (optional)',
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      value: autoJoin,
                      onChanged: (value) => setState(() => autoJoin = value),
                      title: const Text('Auto-join'),
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
                child: const Text('Join'),
              ),
            ],
          );
        });
      },
    );
    if (result != true) {
      return;
    }
    final roomJid = jidController.text.trim();
    if (roomJid.isEmpty) {
      _showSnack('Enter a room JID.');
      return;
    }
    widget.service.joinRoom(
      roomJid,
      nick: nickController.text.trim(),
      password: passwordController.text.trim(),
    );
    if (saveBookmark) {
      final bookmark = ContactEntry(
        jid: roomJid,
        name: nameController.text.trim().isNotEmpty ? nameController.text.trim() : null,
        groups: const [],
        isBookmark: true,
        bookmarkNick: nickController.text.trim().isNotEmpty ? nickController.text.trim() : null,
        bookmarkPassword: passwordController.text.trim().isNotEmpty
            ? passwordController.text.trim()
            : null,
        bookmarkAutoJoin: autoJoin,
      );
      final ok = await widget.service.upsertBookmark(bookmark);
      if (!ok) {
        _showSnack('Failed to save bookmark.');
      }
    }
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

  void _handleTypingState(XmppService service, String activeChat, String value) {
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
      return;
    }
    final position = _messageScrollController.position;
    _wasAtBottom = position.pixels >= (position.maxScrollExtent - 48);
    if (position.pixels <= 24) {
      final activeChat = widget.service.activeChatBareJid;
      if (activeChat != null) {
        widget.service.requestOlderMessages(activeChat);
      }
    }
  }

  void _scrollToBottom() {
    if (!_messageScrollController.hasClients) {
      return;
    }
    _messageScrollController.animateTo(
      _messageScrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<bool> _confirmClearCache() async {
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Clear cached data?'),
          content: const Text('This removes cached roster and messages from this device.'),
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
  return oob.isNotEmpty ? oob : 'Message';
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.senderName,
    required this.timestamp,
    required this.avatarBytes,
    required this.inviteRoomJid,
    required this.inviteRoomName,
    required this.inviteAvatarBytes,
    required this.inviteReason,
    required this.onJoinInvite,
    required this.onReact,
    required this.onEdit,
    required this.onAcceptFile,
    required this.onDeclineFile,
    required this.onFallbackUpload,
  });

  final ChatMessage message;
  final String senderName;
  final String timestamp;
  final Uint8List? avatarBytes;
  final String? inviteRoomJid;
  final String? inviteRoomName;
  final Uint8List? inviteAvatarBytes;
  final String? inviteReason;
  final VoidCallback? onJoinInvite;
  final void Function(String emoji)? onReact;
  final VoidCallback? onEdit;
  final VoidCallback? onAcceptFile;
  final VoidCallback? onDeclineFile;
  final VoidCallback? onFallbackUpload;

  static const List<String> _reactionOptions = [
    '👍',
    '❤️',
    '😂',
    '😮',
    '😢',
    '👎',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    final linkColor = theme.colorScheme.primary;
    final tickIcon = _tickIcon(theme);
    final nameColor = message.outgoing
        ? textColor.withValues(alpha: 0.85)
        : xep0392ColorForLabel(senderName);
    final oobImage = _buildOobImage(context);
    final fileTransferCard = _buildFileTransferCard(context);
    final inviteCard = _buildInviteCard(context);
    final reactions = message.reactions ?? const {};

    return GestureDetector(
      onLongPress: onReact == null ? null : () => _showReactionSheet(context),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AvatarPlaceholder(label: senderName, bytes: avatarBytes),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          senderName,
                          style: theme.textTheme.labelMedium?.copyWith(color: nameColor),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            timestamp,
                            style: theme.textTheme.labelSmall?.copyWith(color: textColor.withValues(alpha: 0.7)),
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
                          const SizedBox(width: 6),
                          _MessageMenuButton(
                            message: message,
                            onReact: onReact,
                            onEdit: onEdit,
                          ),
                        ],
                      ),
                    ],
                  ),
                const SizedBox(height: 6),
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
                if (_meCommandAction(message.body) != null)
                  SelectableText(
                    _formatMeCommand(senderName, _meCommandAction(message.body)!),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: textColor,
                      fontStyle: FontStyle.italic,
                    ),
                  )
                else if (_shouldShowBody(message.body, message.oobUrl))
                  SelectableText.rich(
                    TextSpan(
                      style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
                      children: _linkifyText(
                        message.body,
                        theme.textTheme.bodyMedium?.copyWith(color: textColor),
                        theme.textTheme.bodyMedium?.copyWith(
                          color: linkColor,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                if (reactions.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _buildReactionRow(context, reactions),
                ],
              ],
            ),
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

  List<TextSpan> _linkifyText(String input, TextStyle? baseStyle, TextStyle? linkStyle) {
    final regex = RegExp(r'((https?:\/\/)|(www\.))[^\s<]+', caseSensitive: false);
    final matches = regex.allMatches(input).toList();
    if (matches.isEmpty) {
      return [TextSpan(text: input, style: baseStyle)];
    }

    final spans = <TextSpan>[];
    var lastIndex = 0;
    for (final match in matches) {
      if (match.start > lastIndex) {
        spans.add(TextSpan(text: input.substring(lastIndex, match.start), style: baseStyle));
      }
      final raw = input.substring(match.start, match.end);
      final normalized = _normalizeUrl(raw);
      spans.add(TextSpan(
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
      ));
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
    while (result.isNotEmpty && RegExp(r'[\\).,!?;:\\]]').hasMatch(result[result.length - 1])) {
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
    final title = inviteRoomName?.isNotEmpty == true ? inviteRoomName! : roomJid;
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
                Text(
                  title,
                  style: theme.textTheme.titleSmall,
                ),
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
    final name = message.fileName?.isNotEmpty == true ? message.fileName! : 'File';
    final size = message.fileSize;
    final bytes = message.fileBytes ?? 0;
    final state = message.fileState ?? '';
    final status = _fileTransferStatusLabel(state, message.outgoing);
    final showActions = !message.outgoing &&
        state == 'offered' &&
        (onAcceptFile != null || onDeclineFile != null);
    final showFallback = message.outgoing &&
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
          Text(
            name,
            style: theme.textTheme.titleSmall,
          ),
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
    final value = size >= 10 ? size.roundToDouble() : double.parse(size.toStringAsFixed(1));
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
        final maxWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : 260.0;
        final cap = math.min(maxWidth, 280.0);
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: cap, maxHeight: cap),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () async {
                  final uri = Uri.tryParse(url);
                  if (uri == null) {
                    return;
                  }
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                },
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

  void _showReactionSheet(BuildContext context) {
    if (onReact == null) {
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final emoji in _reactionOptions)
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onReact?.call(emoji);
                    },
                    child: Text(emoji, style: const TextStyle(fontSize: 20)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildReactionRow(BuildContext context, Map<String, List<String>> reactions) {
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
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${entry.key} ${entry.value.length}',
                style: theme.textTheme.labelSmall,
              ),
            ),
          ),
      ],
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
      return CircleAvatar(
        radius: 18,
        backgroundImage: MemoryImage(bytes!),
      );
    }
    final baseColor = xep0392ColorForLabel(label);
    final onBase = baseColor.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return CircleAvatar(
      radius: 18,
      backgroundColor: baseColor,
      foregroundColor: onBase,
      child: Text(initial),
    );
  }
}

class _MessageMenuButton extends StatelessWidget {
  const _MessageMenuButton({
    required this.message,
    required this.onReact,
    required this.onEdit,
  });

  final ChatMessage message;
  final void Function(String emoji)? onReact;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final reactions = message.reactions ?? const {};
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_horiz, size: 16),
      onSelected: (value) {
        switch (value) {
          case 'edit_message':
            onEdit?.call();
            break;
          case 'add_reaction':
            _showReactionSheet(context);
            break;
          case 'view_reactions':
            _showReactions(context);
            break;
          case 'view_xml':
            _showXml(context);
            break;
        }
      },
      itemBuilder: (context) => [
        if (onEdit != null)
          const PopupMenuItem(
            value: 'edit_message',
            child: Text('Edit message'),
          ),
        if (onReact != null)
          const PopupMenuItem(
            value: 'add_reaction',
            child: Text('Add reaction'),
          ),
        if (reactions.isNotEmpty)
          const PopupMenuItem(
            value: 'view_reactions',
            child: Text('View reactions'),
          ),
        const PopupMenuItem(
          value: 'view_xml',
          child: Text('View XML'),
        ),
      ],
    );
  }

  void _showReactionSheet(BuildContext context) {
    if (onReact == null) {
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final emoji in _MessageBubble._reactionOptions)
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onReact?.call(emoji);
                    },
                    child: Text(emoji, style: const TextStyle(fontSize: 20)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showReactions(BuildContext context) {
    final reactions = message.reactions ?? const {};
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
                  for (final entry in reactions.entries.toList()
                    ..sort((a, b) => a.key.compareTo(b.key)))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${entry.key} ${entry.value.join(', ')}',
                      ),
                    ),
                  if (reactions.isEmpty)
                    const Text('No reactions yet.'),
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
    final xml = message.rawXml?.trim();
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Message XML'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: SelectableText(
                (xml == null || xml.isEmpty) ? 'No XML cached for this message.' : xml,
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
  if (entry.subject != null && entry.subject!.isNotEmpty) {
    parts.add(entry.subject!);
  }
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
    required this.onClearCacheExit,
    required this.onExit,
  });

  final XmppService service;
  final VoidCallback? onClearCacheExit;
  final VoidCallback onExit;

  Future<void> _setSentryOptIn(BuildContext context, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sentryOptInKey, enabled);
    if (enabled) {
      await _enableSentryAndRestart();
      return;
    }
    await _restartWithoutSentry();
  }

  Future<bool> _getSentryOptIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_sentryOptInKey) ?? false;
  }

  Future<void> _editProfile(BuildContext context) async {
    final selfJid = service.currentUserBareJid;
    if (selfJid == null || selfJid.isEmpty) {
      return;
    }
    final supportsCamera = !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
    final nameController = TextEditingController(text: service.displayNameFor(selfJid));
    Uint8List? avatarBytes = service.avatarBytesFor(selfJid);
    String? avatarMimeType;
    var clearAvatar = false;
    var saving = false;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          return AlertDialog(
            title: const Text('Edit profile'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundImage: avatarBytes != null ? MemoryImage(avatarBytes!) : null,
                    child: avatarBytes == null ? const Icon(Icons.person, size: 32) : null,
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
                                final result = await FilePicker.platform.pickFiles(
                                  type: FileType.image,
                                  withData: true,
                                );
                                if (result == null || result.files.isEmpty) {
                                  return;
                                }
                                final file = result.files.first;
                                final bytes = await _readPickedFileBytes(file);
                                if (bytes == null || bytes.isEmpty) {
                                  return;
                                }
                                setState(() {
                                  avatarBytes = bytes;
                                  avatarMimeType = _guessImageMimeType(file.name);
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
                                    final messenger = ScaffoldMessenger.of(context);
                                    try {
                                      final picker = ImagePicker();
                                      final picked =
                                          await picker.pickImage(source: ImageSource.camera);
                                      if (picked == null) {
                                        return;
                                      }
                                      final bytes = await picked.readAsBytes();
                                      if (bytes.isEmpty) {
                                        return;
                                      }
                                      setState(() {
                                        avatarBytes = bytes;
                                        avatarMimeType = _guessImageMimeType(picked.path);
                                        clearAvatar = false;
                                      });
                                    } catch (_) {
                                      if (!context.mounted) {
                                        return;
                                      }
                                      messenger.showSnackBar(
                                        const SnackBar(content: Text('Camera not available.')),
                                      );
                                    }
                                  }
                                : () {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Camera not available.')),
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
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error)),
                            );
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
        });
      },
    );
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOnline = service.isConnected;
    final latencyMs = service.lastPingLatency?.inMilliseconds;
    final latencyLabel = latencyMs == null ? '--' : '$latencyMs ms';
    final dotColor = _presenceDotColor(
      theme,
      service.selfPresence.showElement ?? (service.isConnected ? PresenceShowElement.CHAT : null),
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
                service.setSelfPresence(show: PresenceShowElement.CHAT, status: service.selfPresence.status);
                break;
          case _PresenceAction.away:
            service.setSelfPresence(show: PresenceShowElement.AWAY, status: service.selfPresence.status);
            break;
          case _PresenceAction.dnd:
            service.setSelfPresence(show: PresenceShowElement.DND, status: service.selfPresence.status);
            break;
          case _PresenceAction.xa:
            service.setSelfPresence(show: PresenceShowElement.XA, status: service.selfPresence.status);
            break;
          case _PresenceAction.setStatus:
            final status = await _promptStatus(context, service.selfPresence.status ?? '');
            if (status != null) {
              service.setSelfPresence(show: service.selfPresence.showElement ?? PresenceShowElement.CHAT, status: status);
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
            const PopupMenuDivider(),
            const PopupMenuItem(value: _PresenceAction.online, child: Text('Online')),
            const PopupMenuItem(value: _PresenceAction.away, child: Text('Away')),
            const PopupMenuItem(value: _PresenceAction.dnd, child: Text('Do not disturb')),
            const PopupMenuItem(value: _PresenceAction.xa, child: Text('Extended away')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: _PresenceAction.setStatus, child: Text('Set status message...')),
            const PopupMenuItem(value: _PresenceAction.editProfile, child: Text('Edit profile...')),
            PopupMenuItem(
              value: _PresenceAction.toggleSentry,
              child: Text(sentryEnabled ? 'Disable crash reporting' : 'Enable crash reporting'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: _PresenceAction.simulateDisconnect, child: Text('Simulate disconnect')),
            const PopupMenuDivider(),
            PopupMenuItem(
              enabled: onClearCacheExit != null,
              value: _PresenceAction.clearCacheExit,
              child: const Text('Clear Cache & Exit'),
            ),
            const PopupMenuItem(value: _PresenceAction.exit, child: Text('Exit')),
          ],
        );
      },
    );
  }
}

enum _PresenceAction {
  online,
  away,
  dnd,
  xa,
  setStatus,
  editProfile,
  toggleSentry,
  simulateDisconnect,
  clearCacheExit,
  exit
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
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class _PinSetupScreen extends StatefulWidget {
  const _PinSetupScreen({required this.onPinSet});

  final Future<void> Function(String pin) onPinSet;

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
                  subtitle: const Text('Help improve Wimsy by sending anonymized crash reports.'),
                  onChanged: _submitting ? null : (value) => setState(() => _sentryOptIn = value),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: Text(_submitting ? 'Setting...' : 'Set PIN'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_sentryOptInKey, _sentryOptIn);
      await widget.onPinSet(pin);
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
}

class _PinUnlockScreen extends StatefulWidget {
  const _PinUnlockScreen({required this.onUnlocked});

  final Future<void> Function(String pin) onUnlocked;

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
                TextField(
                  controller: _pinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'PIN'),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: Text(_submitting ? 'Unlocking...' : 'Unlock'),
                ),
                if (_loadedSentryPref && !_sentryOptIn) ...[
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _sentryOptIn,
                    title: const Text('Share crash reports'),
                    subtitle: const Text('Help improve Wimsy by sending anonymized crash reports.'),
                    onChanged: _submitting ? null : (value) => setState(() => _sentryOptIn = value),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
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
    if (pin.isEmpty) {
      setState(() => _error = 'Enter your PIN.');
      return;
    }
    setState(() {
      _error = null;
      _submitting = true;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final existingOptIn = prefs.getBool(_sentryOptInKey) ?? false;
      if (_sentryOptIn && !existingOptIn) {
        await prefs.setBool(_sentryOptInKey, true);
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
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    final existing = prefs.getBool(_sentryOptInKey) ?? false;
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
