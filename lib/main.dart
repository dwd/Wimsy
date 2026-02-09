import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xmpp_stone/xmpp_stone.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/chat_message.dart';
import 'models/room_entry.dart';
import 'notifications/notification_service.dart';
import 'storage/account_record.dart';
import 'storage/storage_service.dart';
import 'xmpp/xmpp_service.dart';
import 'background/foreground_task_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Log.logLevel = LogLevel.VERBOSE;
  Log.logXmpp = true;
  runApp(const WimsyApp());
}

const bool _isFlutterTest = bool.fromEnvironment('FLUTTER_TEST');

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
  final TextEditingController _manualContactController = TextEditingController();
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

  @override
  void initState() {
    super.initState();
    _messageScrollController.addListener(_handleScrollPosition);
    widget.service.attachStorage(widget.storage);
    widget.service.setRosterPersistor((roster) => widget.storage.storeRoster(roster));
    widget.service.setBookmarkPersistor((bookmarks) => widget.storage.storeBookmarks(bookmarks));
    widget.service.setMessagePersistor(
      (bareJid, messages) => widget.storage.storeMessagesForJid(bareJid, messages),
    );
    _seedRoster();
    _seedBookmarks();
    _seedMessages();
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
    _messageFocusNode.dispose();
    _messageScrollController.dispose();
    _jidController.dispose();
    _passwordController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _resourceController.dispose();
    _wsEndpointController.dispose();
    _wsProtocolsController.dispose();
    _manualContactController.dispose();
    _messageController.dispose();
    super.dispose();
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
                  child: TextField(
                    controller: _manualContactController,
                    decoration: const InputDecoration(
                      labelText: 'Start chat with JID',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () {
                    service.addManualContact(_manualContactController.text);
                    _manualContactController.clear();
                  },
                  icon: const Icon(Icons.add_circle_outline),
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
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
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
                        final lastReadAt = _lastReadAtByChat[jid];
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
                                          isBookmark ? bookmarkStatusText : (effectiveStatusText ?? ''),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: theme.colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (latest != null) ...[
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        latest.body,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.right,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ],
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
    _handleAutoScroll(messages.length);
    if (activeChat != null) {
      _markChatRead(activeChat, messages);
    }
    if (activeChat == null) {
      _lastFocusedChat = null;
      _lastMessageCount = 0;
    } else if (activeChat != _lastFocusedChat) {
      _lastFocusedChat = activeChat;
      _lastMessageCount = messages.length;
      _markChatRead(activeChat, messages);
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
              ],
            ),
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
                      return _MessageBubble(
                        message: message,
                        senderName: senderName,
                        timestamp: timestamp,
                        avatarBytes: avatarBytes,
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
    _messageController.clear();
    if (widget.service.isBookmark(activeChat)) {
      widget.service.sendRoomMessage(activeChat, text);
    } else {
      widget.service.sendMessage(toBareJid: activeChat, text: text);
      _setChatState(activeChat, ChatState.ACTIVE);
    }
    if (_messageFocusNode.canRequestFocus) {
      _messageFocusNode.requestFocus();
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.senderName,
    required this.timestamp,
    required this.avatarBytes,
  });

  final ChatMessage message;
  final String senderName;
  final String timestamp;
  final Uint8List? avatarBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    final linkColor = theme.colorScheme.primary;
    final tickIcon = _tickIcon(theme);

    return Container(
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
                        style: theme.textTheme.labelMedium?.copyWith(color: textColor.withValues(alpha: 0.85)),
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
                        if (tickIcon != null) ...[
                          const SizedBox(width: 6),
                          tickIcon,
                        ],
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                RichText(
                  text: TextSpan(
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
              ],
            ),
          ),
        ],
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
    final theme = Theme.of(context);
    final initial = label.trim().isEmpty ? '?' : label.trim()[0].toUpperCase();
    if (bytes != null) {
      return CircleAvatar(
        radius: 18,
        backgroundImage: MemoryImage(bytes!),
      );
    }
    return CircleAvatar(
      radius: 18,
      backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
      foregroundColor: theme.colorScheme.primary,
      child: Text(initial),
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
          case _PresenceAction.clearCacheExit:
            onClearCacheExit?.call();
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
        const PopupMenuDivider(),
        PopupMenuItem(
          enabled: onClearCacheExit != null,
          value: _PresenceAction.clearCacheExit,
          child: const Text('Clear Cache & Exit'),
        ),
        const PopupMenuItem(value: _PresenceAction.exit, child: Text('Exit')),
      ],
    );
  }
}

enum _PresenceAction { online, away, dnd, xa, setStatus, clearCacheExit, exit }

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
      await widget.onPinSet(pin);
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
      await widget.onUnlocked(pin);
    } catch (_) {
      setState(() => _error = 'Incorrect PIN.');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }
}
