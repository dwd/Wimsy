import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:xmpp_stone/xmpp_stone.dart';
import '../models/chat_message.dart';
import '../models/contact_entry.dart';
import '../models/room_entry.dart';
import '../bookmarks/bookmarks_manager.dart';
import '../pep/pep_manager.dart';
import '../pep/pep_caps_manager.dart';
import '../storage/storage_service.dart';
import 'ws_endpoint.dart';
import 'srv_lookup.dart';

class _ReconnectConfig {
  _ReconnectConfig({
    required this.jid,
    required this.password,
    required this.resource,
    required this.host,
    required this.port,
    required this.useWebSocket,
    required this.directTls,
    required this.wsEndpoint,
    required this.wsProtocols,
  });

  final String jid;
  final String password;
  final String resource;
  final String host;
  final int port;
  final bool useWebSocket;
  final bool directTls;
  final String wsEndpoint;
  final List<String> wsProtocols;
}

enum XmppStatus {
  disconnected,
  connecting,
  connected,
  error,
}

class XmppService extends ChangeNotifier {
  Connection? _connection;
  ChatManager? _chatManager;
  StreamSubscription<XmppConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<Buddy>>? _rosterSubscription;
  StreamSubscription<List<Chat>>? _chatListSubscription;
  StreamSubscription<PresenceData>? _presenceSubscription;
  StreamSubscription<PresenceErrorEvent>? _presenceErrorSubscription;
  StreamSubscription<Nonza>? _smNonzaSubscription;
  StreamSubscription<AbstractStanza?>? _pingSubscription;
  StreamSubscription<MessageStanza?>? _messageStanzaSubscription;
  StreamSubscription<AbstractStanza>? _smDeliveredSubscription;
  StreamSubscription<AbstractStanza?>? _pepSubscription;
  Timer? _pingTimer;
  Timer? _smAckTimeoutTimer;
  Timer? _csiIdleTimer;
  final Map<String, DateTime> _pendingPings = {};
  final Map<String, Timer> _pingTimeoutTimers = {};
  final Map<String, bool> _pingTimeoutShort = {};
  DateTime? _pendingSmAckAt;
  String? _carbonsRequestId;
  DateTime? _lastSmAckRequestAt;
  static const Duration _smAckIntervalForeground = Duration(minutes: 1);
  static const Duration _smAckIntervalBackground = Duration(minutes: 5);
  static const Duration _pingIntervalForeground = Duration(seconds: 30);
  static const Duration _pingIntervalBackground = Duration(minutes: 5);
  final Map<String, StreamSubscription<Message>> _chatMessageSubscriptions = {};
  final Map<String, StreamSubscription<ChatState?>> _chatStateSubscriptions = {};

  XmppStatus _status = XmppStatus.disconnected;
  String? _errorMessage;
  String? _currentUserBareJid;
  XmppConnectionState? _lastConnectionState;
  bool _backgroundMode = false;
  bool _networkOnline = true;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  _ReconnectConfig? _reconnectConfig;
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, List<ChatMessage>> _roomMessages = {};
  final Set<String> _seededMessageJids = {};
  final Set<String> _seededRoomMessageJids = {};
  final List<ContactEntry> _contacts = [];
  final List<ContactEntry> _bookmarks = [];
  final Map<String, RoomEntry> _rooms = {};
  final Map<String, Set<String>> _roomOccupants = {};
  final Map<String, StreamSubscription> _roomSubscriptions = {};
  final Map<String, PresenceData> _presenceByBareJid = {};
  final Map<String, DateTime> _lastSeenAt = {};
  final Set<String> _serverNotFound = {};
  final Map<String, ChatState?> _chatStates = {};
  final Map<String, String> _lastDisplayedMarkerIdByChat = {};
  String? _activeChatBareJid;
  void Function(String bareJid, ChatMessage message)? _incomingMessageHandler;
  void Function(String roomJid, ChatMessage message)? _incomingRoomMessageHandler;
  void Function(List<ContactEntry> roster)? _rosterPersistor;
  void Function(List<ContactEntry> bookmarks)? _bookmarkPersistor;
  void Function(String bareJid, List<ChatMessage> messages)? _messagePersistor;
  void Function(String roomJid, List<ChatMessage> messages)? _roomMessagePersistor;
  PresenceData _selfPresence = PresenceData(PresenceShowElement.CHAT, 'Online', null);
  Duration? _lastPingLatency;
  DateTime? _lastPingAt;
  bool _carbonsEnabled = false;
  static const String _capsNode = 'https://wimsy.im/caps';
  static const String _capsHash = 'sha-1';
  String? _capsVer;
  bool _csiInactive = false;
  static const Duration _csiIdleDelay = Duration(minutes: 1);
  final Map<String, DateTime> _mamBackfillAt = {};
  final Map<String, DateTime> _mamPageRequestAt = {};
  final Map<String, int> _mamPrependOffset = {};
  final Map<String, Timer> _mamPrependReset = {};
  DateTime? _lastGlobalMamSyncAt;
  bool _globalBackfillInProgress = false;
  Timer? _globalBackfillTimer;
  StorageService? _storage;
  String? _rosterVersion;
  final Map<String, String> _displayedStanzaIdByChat = {};
  final Map<String, DateTime> _displayedAtByChat = {};
  PepManager? _pepManager;
  PepCapsManager? _pepCapsManager;
  BookmarksManager? _bookmarksManager;
  PrivacyListsManager? _privacyListsManager;
  final Set<String> _blockedJids = {};
  static const String _blockListName = 'wimsy-blocked';
  MucManager? _mucManager;
  final Map<String, Uint8List> _vcardAvatarBytes = {};
  final Map<String, String> _vcardAvatarState = {};
  final Set<String> _vcardRequests = {};
  static const _vcardNoAvatar = 'none';
  static const _vcardUnknown = 'unknown';

  XmppStatus get status => _status;
  String? get errorMessage => _errorMessage;
  String? get currentUserBareJid => _currentUserBareJid;
  XmppConnectionState? get lastConnectionState => _lastConnectionState;
  List<ContactEntry> get contacts {
    final combined = <ContactEntry>[
      ..._bookmarks,
      ..._contacts,
    ];
    combined.sort(_contactSort);
    return List.unmodifiable(combined);
  }
  String? get activeChatBareJid => _activeChatBareJid;
  RoomEntry? roomFor(String bareJid) => _rooms[_bareJid(bareJid)];
  Duration? get lastPingLatency => _lastPingLatency;
  DateTime? get lastPingAt => _lastPingAt;
  bool get carbonsEnabled => _carbonsEnabled;
  bool isBlocked(String bareJid) => _blockedJids.contains(_bareJid(bareJid));

  void attachStorage(StorageService storage) {
    _storage = storage;
    _seedVcardAvatars(storage.loadVcardAvatars());
    _seedVcardAvatarState(storage.loadVcardAvatarState());
    _rosterVersion = storage.loadRosterVersion();
    _displayedStanzaIdByChat
      ..clear()
      ..addAll(storage.loadDisplayedSync());
  }

  List<ChatMessage> messagesFor(String bareJid) {
    return List.unmodifiable(_messages[bareJid] ?? const []);
  }

  List<ChatMessage> roomMessagesFor(String roomJid) {
    return List.unmodifiable(_roomMessages[_bareJid(roomJid)] ?? const []);
  }

  DateTime? displayedAtFor(String bareJid) {
    return _displayedAtByChat[_bareJid(bareJid)];
  }

  bool isMessageUnseen(String bareJid, ChatMessage message) {
    if (message.outgoing) {
      return false;
    }
    final normalized = _bareJid(bareJid);
    final displayedAt = _displayedAtByChat[normalized];
    if (displayedAt == null) {
      return true;
    }
    return message.timestamp.isAfter(displayedAt);
  }

  String displayNameFor(String bareJid) {
    final normalized = _bareJid(bareJid);
    final contact = _findContact(normalized) ??
        ContactEntry(jid: normalized);
    return contact.displayName;
  }

  bool isBookmark(String bareJid) {
    final normalized = _bareJid(bareJid);
    return _bookmarks.any((entry) => entry.jid == normalized);
  }

  bool isServerNotFound(String bareJid) {
    return _serverNotFound.contains(_bareJid(bareJid));
  }

  ContactEntry? _findContact(String bareJid) {
    final normalized = _bareJid(bareJid);
    final bookmark = _bookmarks.firstWhere(
      (entry) => entry.jid == normalized,
      orElse: () => ContactEntry(jid: ''),
    );
    if (bookmark.jid.isNotEmpty) {
      return bookmark;
    }
    final contact = _contacts.firstWhere(
      (entry) => entry.jid == normalized,
      orElse: () => ContactEntry(jid: ''),
    );
    return contact.jid.isNotEmpty ? contact : null;
  }

  String? oldestMamIdFor(String bareJid) {
    final messages = _messages[_bareJid(bareJid)];
    if (messages == null || messages.isEmpty) {
      return null;
    }
    final withMam = messages.where((m) => m.mamId != null).toList();
    if (withMam.isEmpty) {
      return null;
    }
    withMam.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return withMam.first.mamId;
  }

  String? _oldestRoomMamIdFor(String roomJid) {
    final messages = _roomMessages[_bareJid(roomJid)];
    if (messages == null || messages.isEmpty) {
      return null;
    }
    final withMam = messages.where((m) => m.mamId != null && m.mamId!.isNotEmpty).toList();
    if (withMam.isEmpty) {
      return null;
    }
    withMam.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return withMam.first.mamId;
  }

  String? latestMamIdFor(String bareJid) {
    final messages = _messages[_bareJid(bareJid)];
    if (messages == null || messages.isEmpty) {
      return null;
    }
    final withMam = messages.where((m) => m.mamId != null).toList();
    if (withMam.isEmpty) {
      return null;
    }
    withMam.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return withMam.first.mamId;
  }

  String? _latestGlobalMamId({required bool includeRooms}) {
    ChatMessage? latest;
    for (final entry in _messages.entries) {
      final bareJid = _bareJid(entry.key);
      if (!includeRooms && isBookmark(bareJid)) {
        continue;
      }
      for (final message in entry.value) {
        final mamId = message.mamId;
        if (mamId == null || mamId.isEmpty) {
          continue;
        }
        if (latest == null || message.timestamp.isAfter(latest.timestamp)) {
          latest = message;
        }
      }
    }
    return latest?.mamId;
  }

  String? _oldestGlobalMamId({required bool includeRooms}) {
    ChatMessage? oldest;
    for (final entry in _messages.entries) {
      final bareJid = _bareJid(entry.key);
      if (!includeRooms && isBookmark(bareJid)) {
        continue;
      }
      for (final message in entry.value) {
        final mamId = message.mamId;
        if (mamId == null || mamId.isEmpty) {
          continue;
        }
        if (oldest == null || message.timestamp.isBefore(oldest.timestamp)) {
          oldest = message;
        }
      }
    }
    return oldest?.mamId;
  }

  PresenceData? presenceFor(String bareJid) {
    return _presenceByBareJid[_bareJid(bareJid)];
  }

  String presenceLabelFor(String bareJid) {
    final presence = presenceFor(bareJid);
    if (presence == null) {
      return 'offline';
    }
    final status = presence.status?.toLowerCase();
    if (status == 'unavailable') {
      return 'offline';
    }
    final show = presence.showElement;
    if (show == null) {
      return 'online';
    }
    switch (show) {
      case PresenceShowElement.CHAT:
        return 'online';
      case PresenceShowElement.AWAY:
        return 'away';
      case PresenceShowElement.DND:
        return 'do not disturb';
      case PresenceShowElement.XA:
        return 'extended away';
    }
  }

  Future<bool> requestPresenceSubscription(String bareJid) async {
    final connection = _connection;
    if (connection == null) {
      return false;
    }
    final normalized = _bareJid(bareJid);
    if (normalized.isEmpty) {
      return false;
    }
    final presenceManager = PresenceManager.getInstance(connection);
    presenceManager.subscribe(Jid.fromFullJid(normalized));
    return true;
  }

  Future<bool> preauthorizePresenceSubscription(String bareJid) async {
    final connection = _connection;
    if (connection == null) {
      return false;
    }
    final normalized = _bareJid(bareJid);
    if (normalized.isEmpty) {
      return false;
    }
    final presenceManager = PresenceManager.getInstance(connection);
    presenceManager.acceptSubscription(Jid.fromFullJid(normalized));
    return true;
  }

  ChatState? chatStateFor(String bareJid) {
    return _chatStates[_bareJid(bareJid)];
  }

  String chatStateLabelFor(String bareJid) {
    final state = chatStateFor(bareJid);
    switch (state) {
      case null:
        return '';
      case ChatState.COMPOSING:
        return 'typing...';
      case ChatState.PAUSED:
        return 'paused';
      case ChatState.ACTIVE:
        return 'active';
      case ChatState.INACTIVE:
        return 'inactive';
      case ChatState.GONE:
        return 'gone';
    }
  }

  PresenceData get selfPresence => _selfPresence;

  void setSelfPresence({required PresenceShowElement show, String? status}) {
    _selfPresence = PresenceData(show, status, null);
    _sendPresence(_selfPresence);
    notifyListeners();
  }

  bool get isConnected => _status == XmppStatus.connected;
  bool get isConnecting => _status == XmppStatus.connecting;
  bool get isBackgroundMode => _backgroundMode;

  void setBackgroundMode(bool enabled) {
    if (_backgroundMode == enabled) {
      return;
    }
    _backgroundMode = enabled;
    if (!_backgroundMode) {
      _reconnectTimer?.cancel();
    }
    _applyClientState();
    _restartKeepaliveTimer();
    if (_backgroundMode && !_networkOnline) {
      return;
    }
    if (_backgroundMode && !isConnected && !isConnecting) {
      _scheduleReconnect();
    }
  }

  void handleConnectivityChange(bool online) {
    _networkOnline = online;
    if (!_networkOnline) {
      return;
    }
    _probeConnection(shortTimeout: true);
    if (_backgroundMode && !isConnected && !isConnecting) {
      _scheduleReconnect();
    }
  }

  void noteUserActivity() {
    if (_backgroundMode) {
      return;
    }
    if (_csiInactive) {
      _sendClientState(active: true);
    }
    _scheduleCsiIdle();
  }

  void simulateServerDisconnect() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    connection.simulateForcefulClose();
  }

  Future<void> connect({
    required String jid,
    required String password,
    required String resource,
    String? host,
    required int port,
    bool useWebSocket = false,
    bool directTls = false,
    String? wsEndpoint,
    List<String>? wsProtocols,
  }) async {
    final shouldUseWebSocket = kIsWeb || useWebSocket;
    WsEndpointConfig? wsConfig;
    if (shouldUseWebSocket) {
      wsConfig = parseWsEndpoint(wsEndpoint ?? '');
      if (wsConfig == null) {
        _setError('Enter a WebSocket endpoint like wss://host/path.');
        return;
      }
    }

    final normalized = jid.trim();
    if (!_looksLikeJid(normalized)) {
      _setError('Enter a full JID like user@domain.');
      return;
    }

    final bareJid = _bareJid(normalized);
    final fullJid = normalized.contains('/') ? normalized : '$bareJid/$resource';
    var resolvedHost = host?.trim().isNotEmpty == true ? host!.trim() : '';
    var resolvedPort = port;
    var resolvedDirectTls = directTls;
    if (!kIsWeb && resolvedHost.isEmpty) {
      final domain = _domainFromBareJid(bareJid);
      final srvTarget = await resolveXmppSrv(domain);
      if (srvTarget != null) {
        resolvedHost = srvTarget.host;
        resolvedPort = srvTarget.port;
        resolvedDirectTls = srvTarget.directTls;
      } else if (resolvedPort == 0 || resolvedPort == 5222) {
        resolvedPort = directTls ? 5223 : 5222;
      }
    }

    await _safeClose(preserveCache: true);

    _status = XmppStatus.connecting;
    _errorMessage = null;
    _currentUserBareJid = bareJid;
    notifyListeners();

    try {
      final normalizedHost = resolvedHost.isNotEmpty ? resolvedHost : 'auto';
      debugPrint('XMPP TLS: directTls=$resolvedDirectTls useWebSocket=$shouldUseWebSocket');
      debugPrint('XMPP connect: bareJid=$bareJid host=$normalizedHost port=$resolvedPort resource=$resource');
      final account = XmppAccountSettings.fromJid(fullJid, password);
      account.host = resolvedHost.isNotEmpty ? resolvedHost : null;
      account.port = resolvedPort;
      account.resource = resource;
      account.useWebSocket = shouldUseWebSocket;
      account.directTls = resolvedDirectTls;
      if (wsConfig != null) {
        account.wsUrl = wsConfig.uri.toString();
        account.wsHost = wsConfig.host;
        account.wsPort = wsConfig.port;
        account.wsPath = wsConfig.path;
        final protocols = wsProtocols ?? const [];
        account.wsProtocols = protocols.isEmpty ? null : protocols;
      }

      final connection = Connection.getInstance(account);
      _connection = connection;
      _reconnectConfig = _ReconnectConfig(
        jid: fullJid,
        password: password,
        resource: resource,
        host: resolvedHost,
        port: resolvedPort,
        useWebSocket: shouldUseWebSocket,
        directTls: resolvedDirectTls,
        wsEndpoint: wsConfig?.uri.toString() ?? '',
        wsProtocols: (wsConfig != null ? (wsProtocols ?? const []) : const []),
      );

      final completer = Completer<void>();
      _connectionStateSubscription =
          connection.connectionStateStream.listen((state) {
        debugPrint('XMPP state: $state');
        Log.i('XmppService', 'Connection state: $state');
        _lastConnectionState = state;
        if (state == XmppConnectionState.Reconnecting) {
          _status = XmppStatus.connecting;
          _errorMessage = null;
          notifyListeners();
          return;
        }
        if (state == XmppConnectionState.Resumed) {
          _status = XmppStatus.connected;
          _errorMessage = null;
          notifyListeners();
          _setupKeepalive();
          _setupDeliveryTracking();
          return;
        }
        if (state == XmppConnectionState.Ready) {
          _reconnectAttempt = 0;
          _reconnectTimer?.cancel();
          if (!completer.isCompleted) {
            completer.complete();
          }
          _status = XmppStatus.connected;
          _errorMessage = null;
          notifyListeners();
          _setupRoster();
          _setupChatManager();
          _setupMuc();
          _setupMessageSignals();
          _setupPresence();
          _setupKeepalive();
          _setupDeliveryTracking();
          _setupPep();
          _setupBookmarks();
          _setupPrivacyLists();
          _setupDisplayedSync();
          _primeMamSync();
          _sendInitialPresence();
          _applyClientState();
        } else if (_isTerminalError(state)) {
          final message = _connectionErrorMessage(state);
          debugPrint('XMPP error: $message');
          if (!completer.isCompleted) {
            completer.completeError(message);
          }
          _setError(message);
          _scheduleReconnect();
        } else if (_status == XmppStatus.connecting) {
          notifyListeners();
        }
      });

      connection.connect();

      await completer.future.timeout(const Duration(seconds: 20));
    } catch (error) {
      await _safeClose(preserveCache: true);
      if (_status != XmppStatus.error) {
        _setError('Connection failed: $error');
      }
      _scheduleReconnect();
    }
  }

  Future<void> disconnect() async {
    await _safeClose(preserveCache: true);
    _status = XmppStatus.disconnected;
    _errorMessage = null;
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    notifyListeners();
  }

  void clearCache() {
    _contacts.clear();
    _bookmarks.clear();
    _messages.clear();
    _roomMessages.clear();
    _seededMessageJids.clear();
    _seededRoomMessageJids.clear();
    _rooms.clear();
    _roomOccupants.clear();
    _presenceByBareJid.clear();
    _lastSeenAt.clear();
    _serverNotFound.clear();
    _chatStates.clear();
    _rosterVersion = null;
    _pepManager?.clearCache();
    _bookmarksManager?.clearCache();
    _vcardAvatarBytes.clear();
    _vcardAvatarState.clear();
    _messagePersistor?.call('', const []);
    _roomMessagePersistor?.call('', const []);
    _rosterPersistor?.call(const []);
    _bookmarkPersistor?.call(const []);
    _storage?.storeRosterVersion(null);
    _displayedStanzaIdByChat.clear();
    _displayedAtByChat.clear();
    _storage?.clearDisplayedSync();
    notifyListeners();
  }

  void selectChat(String? bareJid) {
    _activeChatBareJid = bareJid;
    if (bareJid != null && !isBookmark(bareJid)) {
      setMyChatState(bareJid, ChatState.ACTIVE);
      _requestMamBackfill(bareJid);
      _sendDisplayedForChat(bareJid);
      _publishDisplayedState(bareJid);
    }
    if (bareJid != null && isBookmark(bareJid)) {
      _ensureRoom(_bareJid(bareJid));
      _publishDisplayedState(bareJid);
    }
    notifyListeners();
  }

  void requestOlderMessages(String bareJid) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final mam = connection.getMamModule();
    if (!mam.enabled) {
      return;
    }
    final normalized = _bareJid(bareJid);
    final lastRequest = _mamPageRequestAt[normalized];
    if (lastRequest != null && DateTime.now().difference(lastRequest).inSeconds < 5) {
      return;
    }
    _mamPageRequestAt[normalized] = DateTime.now();
    if (isBookmark(normalized)) {
      final oldest = _oldestRoomMamIdFor(normalized);
      if (oldest == null || oldest.isEmpty) {
        _requestRoomMam(normalized, before: '');
        return;
      }
      _startMamPrepend(normalized);
      if (_seededRoomMessageJids.contains(normalized)) {
        mam.queryById(
          toJid: Jid.fromFullJid(normalized),
          max: 25,
          beforeId: oldest,
        );
      } else {
        mam.queryById(
          toJid: Jid.fromFullJid(normalized),
          max: 25,
          before: oldest,
        );
      }
      return;
    }
    final oldest = oldestMamIdFor(normalized);
    if (oldest == null || oldest.isEmpty) {
      _requestMamBackfill(normalized);
      return;
    }
    _startMamPrepend(normalized);
    if (_seededMessageJids.contains(normalized)) {
      mam.queryById(
        jid: Jid.fromFullJid(normalized),
        max: 50,
        beforeId: oldest,
      );
    } else {
      mam.queryById(
        jid: Jid.fromFullJid(normalized),
        max: 50,
        before: oldest,
      );
    }
  }

  void setRosterPersistor(void Function(List<ContactEntry> roster)? persistor) {
    _rosterPersistor = persistor;
  }

  void setIncomingMessageHandler(
      void Function(String bareJid, ChatMessage message)? handler) {
    _incomingMessageHandler = handler;
  }

  void setIncomingRoomMessageHandler(
      void Function(String roomJid, ChatMessage message)? handler) {
    _incomingRoomMessageHandler = handler;
  }

  void setBookmarkPersistor(void Function(List<ContactEntry> bookmarks)? persistor) {
    _bookmarkPersistor = persistor;
  }

  void setMessagePersistor(
      void Function(String bareJid, List<ChatMessage> messages)? persistor) {
    _messagePersistor = persistor;
  }

  void setRoomMessagePersistor(
      void Function(String roomJid, List<ChatMessage> messages)? persistor) {
    _roomMessagePersistor = persistor;
  }

  void seedRoster(List<ContactEntry> roster) {
    for (final entry in roster) {
      _ensureContact(
        entry.jid,
        name: entry.name,
        groups: entry.groups,
        subscriptionType: entry.subscriptionType,
      );
    }
  }

  void seedBookmarks(List<ContactEntry> bookmarks) {
    _bookmarks
      ..clear()
      ..addAll(
        bookmarks.map((entry) => entry.isBookmark ? entry : entry.copyWith(isBookmark: true)),
      );
    notifyListeners();
  }

  void seedMessages(Map<String, List<ChatMessage>> messages) {
    for (final entry in messages.entries) {
      final bareJid = _bareJid(entry.key);
      _messages[bareJid] = List<ChatMessage>.from(entry.value);
      _seededMessageJids.add(bareJid);
      _ensureContact(bareJid);
      _applyDisplayedStateForChat(bareJid);
    }
    notifyListeners();
  }

  void seedRoomMessages(Map<String, List<ChatMessage>> messages) {
    for (final entry in messages.entries) {
      final roomJid = _bareJid(entry.key);
      _roomMessages[roomJid] = List<ChatMessage>.from(entry.value);
      _seededRoomMessageJids.add(roomJid);
      _ensureRoom(roomJid);
      _applyDisplayedStateForChat(roomJid);
    }
    notifyListeners();
  }

  Uint8List? avatarBytesFor(String bareJid) {
    final normalized = _bareJid(bareJid);
    final pepBytes = _pepManager?.avatarBytesFor(normalized);
    if (pepBytes != null) {
      return pepBytes;
    }
    final vcardBytes = _vcardAvatarBytes[normalized];
    if (vcardBytes != null) {
      return vcardBytes;
    }
    final state = _vcardAvatarState[normalized];
    if (state == _vcardNoAvatar) {
      return null;
    }
    if (!_vcardRequests.contains(normalized)) {
      _requestVcardAvatar(normalized);
    }
    return null;
  }

  void sendMessage({
    required String toBareJid,
    required String text,
  }) {
    if (isBookmark(toBareJid)) {
      _setError('Joining bookmarked rooms is not supported yet.');
      return;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final chatManager = _chatManager;
    if (chatManager == null) {
      _setError('Not connected.');
      return;
    }

    final jid = Jid.fromFullJid(toBareJid);
    final chat = chatManager.getChat(jid);
    _ensureChatSubscription(chat);
    chat.sendMessage(trimmed);
    chat.myState = ChatState.ACTIVE;
  }

  void setMyChatState(String bareJid, ChatState state) {
    final chatManager = _chatManager;
    if (chatManager == null) {
      return;
    }
    final chat = chatManager.getChat(Jid.fromFullJid(bareJid));
    chat.myState = state;
  }

  void addManualContact(String bareJid) {
    final normalized = _bareJid(bareJid);
    if (normalized.isEmpty) {
      return;
    }
    upsertRosterContact(normalized);
    selectChat(normalized);
  }

  Future<bool> upsertRosterContact(String bareJid, {String? name, List<String>? groups}) async {
    final connection = _connection;
    if (connection == null) {
      return false;
    }
    final normalized = _bareJid(bareJid);
    if (normalized.isEmpty) {
      return false;
    }
    final buddy = Buddy(Jid.fromFullJid(normalized));
    if (name != null && name.trim().isNotEmpty) {
      buddy.name = name.trim();
    }
    if (groups != null && groups.isNotEmpty) {
      buddy.groups = groups;
    }
    final rosterManager = RosterManager.getInstance(connection);
    final result = await rosterManager.addRosterItem(buddy);
    if (result.type == IqStanzaType.ERROR) {
      return false;
    }
    final existingIndex = _contacts.indexWhere((entry) => entry.jid == normalized);
    if (existingIndex == -1) {
      _contacts.add(ContactEntry(
        jid: normalized,
        name: buddy.name,
        groups: buddy.groups,
        subscriptionType: null,
      ));
    } else {
      final existing = _contacts[existingIndex];
      _contacts[existingIndex] = existing.copyWith(
        name: buddy.name ?? existing.name,
        groups: buddy.groups.isNotEmpty ? buddy.groups : existing.groups,
      );
    }
    _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
    notifyListeners();
    _rosterPersistor?.call(List.unmodifiable(_contacts));
    return true;
  }

  Future<bool> removeRosterContact(String bareJid) async {
    final connection = _connection;
    if (connection == null) {
      return false;
    }
    final normalized = _bareJid(bareJid);
    if (normalized.isEmpty) {
      return false;
    }
    final buddy = Buddy(Jid.fromFullJid(normalized));
    final rosterManager = RosterManager.getInstance(connection);
    final result = await rosterManager.removeRosterItem(buddy);
    if (result.type == IqStanzaType.ERROR) {
      return false;
    }
    _contacts.removeWhere((entry) => entry.jid == normalized);
    notifyListeners();
    _rosterPersistor?.call(List.unmodifiable(_contacts));
    return true;
  }

  Future<bool> upsertBookmark(ContactEntry bookmark) async {
    final manager = _bookmarksManager;
    if (manager == null) {
      return false;
    }
    await manager.upsertBookmark(bookmark);
    return true;
  }

  Future<bool> removeBookmark(String roomJid) async {
    final manager = _bookmarksManager;
    if (manager == null) {
      return false;
    }
    await manager.removeBookmark(_bareJid(roomJid));
    return true;
  }

  Future<bool> blockContact(String bareJid) async {
    final normalized = _bareJid(bareJid);
    if (normalized.isEmpty) {
      return false;
    }
    _blockedJids.add(normalized);
    return _applyBlockList();
  }

  Future<bool> unblockContact(String bareJid) async {
    final normalized = _bareJid(bareJid);
    if (normalized.isEmpty) {
      return false;
    }
    _blockedJids.remove(normalized);
    return _applyBlockList();
  }

  void joinRoom(String roomJid, {String? nick, String? password}) {
    final muc = _mucManager;
    if (muc == null || _currentUserBareJid == null) {
      _setError('Not connected.');
      return;
    }
    final normalized = _bareJid(roomJid);
    final resolvedNick = (nick != null && nick.trim().isNotEmpty)
        ? nick.trim()
        : _roomNickFor(normalized);
    final resolvedPassword = (password != null && password.trim().isNotEmpty)
        ? password.trim()
        : _roomPasswordFor(normalized);
    muc.joinRoom(Jid.fromFullJid(normalized), resolvedNick, password: resolvedPassword);
    final existing = _rooms[normalized] ?? RoomEntry(roomJid: normalized);
    _rooms[normalized] = existing.copyWith(joined: true, nick: resolvedNick);
    notifyListeners();
    _requestRoomMam(normalized, before: '');
  }

  void leaveRoom(String roomJid) {
    final muc = _mucManager;
    final entry = _rooms[_bareJid(roomJid)];
    if (muc == null || entry == null || entry.nick == null) {
      return;
    }
    muc.leaveRoom(Jid.fromFullJid(entry.roomJid), entry.nick!);
    _rooms[entry.roomJid] = entry.copyWith(joined: false);
    notifyListeners();
  }

  void sendRoomMessage(String roomJid, String text) {
    final muc = _mucManager;
    if (muc == null) {
      _setError('Not connected.');
      return;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final normalized = _bareJid(roomJid);
    final messageId = AbstractStanza.getRandomId();
    muc.sendGroupMessage(Jid.fromFullJid(normalized), trimmed, messageId: messageId);
    final rawXml = _buildOutgoingGroupStanzaXml(normalized, messageId, trimmed);
    final nick = _roomNickFor(normalized);
    _addRoomMessage(
      roomJid: normalized,
      from: nick,
      body: trimmed,
      rawXml: rawXml,
      outgoing: true,
      timestamp: DateTime.now(),
      messageId: messageId,
    );
  }

  void _setupRoster() {
    final connection = _connection;
    if (connection == null) {
      return;
    }

    final rosterManager = RosterManager.getInstance(connection);
    rosterManager.setRosterVersion(_rosterVersion);

    _rosterSubscription?.cancel();
    _rosterSubscription = rosterManager.rosterStream.listen((buddies) {
      for (final buddy in buddies) {
        final jid = buddy.jid?.userAtDomain;
        if (jid != null && jid.isNotEmpty) {
          final subscriptionType = buddy.subscriptionType?.toString().split('.').last.toLowerCase();
          _ensureContact(
            jid,
            name: buddy.name,
            groups: buddy.groups,
            subscriptionType: subscriptionType,
          );
          _pepManager?.requestMetadataIfMissing(jid);
        }
      }
      final nextVersion = rosterManager.rosterVersion;
      if (nextVersion != null && nextVersion != _rosterVersion) {
        _rosterVersion = nextVersion;
        _storage?.storeRosterVersion(nextVersion);
      }
    });

    rosterManager.queryForRoster();
  }

  void _setupChatManager() {
    final connection = _connection;
    if (connection == null) {
      return;
    }

    final chatManager = ChatManager.getInstance(connection);
    _chatManager = chatManager;

    _chatListSubscription?.cancel();
    _chatListSubscription = chatManager.chatListStream.listen((chats) {
      for (final chat in chats) {
        _ensureChatSubscription(chat);
      }
    });
  }

  void _setupMessageSignals() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final handler = MessageHandler.getInstance(connection);
    _messageStanzaSubscription?.cancel();
    _messageStanzaSubscription = handler.messagesStream.listen((stanza) {
      if (stanza == null) {
        return;
      }
      _handleMessageStanza(stanza);
    });
  }

  void _setupDeliveryTracking() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final streamManagement = connection.streamManagementModule;
    if (streamManagement == null) {
      return;
    }
    _smDeliveredSubscription?.cancel();
    _smDeliveredSubscription = streamManagement.deliveredStanzasStream.listen((stanza) {
      if (stanza is! MessageStanza) {
        return;
      }
      final id = stanza.id;
      if (id == null || id.isEmpty) {
        return;
      }
      if (stanza.type == MessageStanzaType.CHAT) {
        _applyAckByMessageId(id);
        return;
      }
      if (stanza.type == MessageStanzaType.GROUPCHAT) {
        _applyRoomAckByMessageId(id);
      }
    });
  }

  void _setupMuc() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    _mucManager = connection.getMucModule();
    _roomSubscriptions['message']?.cancel();
    _roomSubscriptions['message'] =
        _mucManager!.roomMessageStream.listen((message) {
      _addRoomMessage(
        roomJid: message.roomJid,
        from: message.nick,
        body: message.body,
        oobUrl: message.oobUrl,
        rawXml: message.rawXml ?? _buildIncomingGroupFallbackXml(message),
        outgoing: false,
        timestamp: message.timestamp,
        messageId: message.messageId ?? message.stanzaId,
        mamId: message.mamResultId,
        stanzaId: message.stanzaId,
      );
    });
    _roomSubscriptions['presence']?.cancel();
    _roomSubscriptions['presence'] =
        _mucManager!.roomPresenceStream.listen((presence) {
      final roomJid = _bareJid(presence.roomJid);
      final occupants = _roomOccupants.putIfAbsent(roomJid, () => <String>{});
      if (presence.unavailable) {
        occupants.remove(presence.nick);
      } else {
        occupants.add(presence.nick);
      }
      final existing = _rooms[roomJid] ?? RoomEntry(roomJid: roomJid);
      final next = existing.copyWith(
        joined: existing.joined || presence.isSelf,
        occupantCount: occupants.length,
      );
      _rooms[roomJid] = next;
      notifyListeners();
    });
    _roomSubscriptions['subject']?.cancel();
    _roomSubscriptions['subject'] =
        _mucManager!.roomSubjectStream.listen((subject) {
      final roomJid = _bareJid(subject.roomJid);
      final existing = _rooms[roomJid] ?? RoomEntry(roomJid: roomJid);
      _rooms[roomJid] = existing.copyWith(subject: subject.subject);
      notifyListeners();
    });
  }

  void _handleMessageStanza(MessageStanza stanza) {
    if (stanza.type != MessageStanzaType.CHAT) {
      return;
    }
    final fromBare = stanza.fromJid?.userAtDomain ?? '';
    if (fromBare.isEmpty) {
      return;
    }
    final receiptId = _extractReceiptsId(stanza);
    if (receiptId != null) {
      _applyReceipt(fromBare, receiptId);
      return;
    }
    final displayedId = _extractMarkerId(stanza, 'displayed');
    if (displayedId != null) {
      _applyDisplayed(fromBare, displayedId);
      return;
    }
    final body = stanza.body ?? '';
    final oobUrl = _extractOobUrlFromStanza(stanza);
    if (body.trim().isEmpty && (oobUrl == null || oobUrl.isEmpty)) {
      return;
    }
    if (_isArchivedStanza(stanza)) {
      return;
    }
    if (_currentUserBareJid != null && _bareJid(fromBare) == _currentUserBareJid) {
      return;
    }
    final messageId = stanza.id;
    if (messageId == null || messageId.isEmpty) {
      return;
    }
    if (_hasReceiptRequest(stanza)) {
      _sendReceipt(fromBare, messageId);
    }
    if (_hasMarkable(stanza)) {
      _sendMarker(fromBare, messageId, 'received');
      if (_activeChatBareJid != null &&
          _bareJid(_activeChatBareJid!) == _bareJid(fromBare)) {
        _sendMarker(fromBare, messageId, 'displayed');
      }
    }
  }

  bool _hasReceiptRequest(MessageStanza stanza) {
    return _hasChildWithXmlns(stanza, 'request', 'urn:xmpp:receipts');
  }

  bool _hasMarkable(MessageStanza stanza) {
    return _hasChildWithXmlns(stanza, 'markable', 'urn:xmpp:chat-markers:0');
  }

  String? _extractReceiptsId(MessageStanza stanza) {
    final element = _findChildWithXmlns(stanza, 'received', 'urn:xmpp:receipts');
    return element?.getAttribute('id')?.value;
  }

  String? _extractMarkerId(MessageStanza stanza, String name) {
    final element = _findChildWithXmlns(stanza, name, 'urn:xmpp:chat-markers:0');
    return element?.getAttribute('id')?.value;
  }

  bool _hasChildWithXmlns(XmppElement stanza, String name, String xmlns) {
    return _findChildWithXmlns(stanza, name, xmlns) != null;
  }

  XmppElement? _findChildWithXmlns(XmppElement stanza, String name, String xmlns) {
    for (final child in stanza.children) {
      if (child.name == name && child.getAttribute('xmlns')?.value == xmlns) {
        return child;
      }
    }
    return null;
  }

  String? _extractOobUrlFromStanza(XmppElement stanza) {
    final candidates = <XmppElement>[stanza];
    for (final child in stanza.children) {
      if (child.name != 'result' && child.name != 'sent' && child.name != 'received') {
        continue;
      }
      final forwarded = child.getChild('forwarded');
      final message = forwarded?.getChild('message');
      if (message != null) {
        candidates.add(message);
      }
    }
    final directForwarded = stanza.getChild('forwarded');
    final forwardedMessage = directForwarded?.getChild('message');
    if (forwardedMessage != null) {
      candidates.add(forwardedMessage);
    }
    for (final candidate in candidates) {
      for (final child in candidate.children) {
        if (child.name != 'x') {
          continue;
        }
        if (child.getAttribute('xmlns')?.value != 'jabber:x:oob') {
          continue;
        }
        final url = child.getChild('url')?.textValue?.trim();
        if (url != null && url.isNotEmpty) {
          return url;
        }
      }
    }
    return null;
  }

  String _serializeStanza(XmppElement stanza) {
    try {
      return stanza.buildXml().toXmlString(pretty: false);
    } catch (_) {
      return stanza.buildXmlString();
    }
  }

  String _buildOutgoingGroupStanzaXml(String roomJid, String messageId, String body) {
    final stanza = MessageStanza(messageId, MessageStanzaType.GROUPCHAT);
    stanza.toJid = Jid.fromFullJid(roomJid);
    stanza.body = body;
    return _serializeStanza(stanza);
  }

  String _buildIncomingGroupFallbackXml(MucMessage message) {
    final id = message.messageId ?? message.stanzaId ?? AbstractStanza.getRandomId();
    final stanza = MessageStanza(id, MessageStanzaType.GROUPCHAT);
    stanza.fromJid = Jid.fromFullJid('${message.roomJid}/${message.nick}');
    stanza.body = message.body;
    return _serializeStanza(stanza);
  }

  bool _isArchivedStanza(MessageStanza stanza) {
    for (final child in stanza.children) {
      if (child.name == 'result') {
        return true;
      }
      if (child.name == 'delay' && child.getAttribute('xmlns')?.value == 'urn:xmpp:delay') {
        return true;
      }
    }
    return false;
  }

  void _sendReceipt(String toBareJid, String messageId) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final stanza =
        MessageStanza(AbstractStanza.getRandomId(), MessageStanzaType.CHAT);
    stanza.toJid = Jid.fromFullJid(toBareJid);
    stanza.fromJid = connection.fullJid;
    final receipt = XmppElement()..name = 'received';
    receipt.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:receipts'));
    receipt.addAttribute(XmppAttribute('id', messageId));
    stanza.addChild(receipt);
    connection.writeStanza(stanza);
  }

  void _sendMarker(String toBareJid, String messageId, String name) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final stanza =
        MessageStanza(AbstractStanza.getRandomId(), MessageStanzaType.CHAT);
    stanza.toJid = Jid.fromFullJid(toBareJid);
    stanza.fromJid = connection.fullJid;
    final marker = XmppElement()..name = name;
    marker.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:chat-markers:0'));
    marker.addAttribute(XmppAttribute('id', messageId));
    stanza.addChild(marker);
    connection.writeStanza(stanza);
  }

  void _setupPresence() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final presenceManager = PresenceManager.getInstance(connection);
    _presenceSubscription?.cancel();
    _presenceSubscription = presenceManager.presenceStream.listen((presence) {
      final jid = presence.jid?.userAtDomain;
      if (jid == null || jid.isEmpty) {
        return;
      }
      final normalized = _bareJid(jid);
      _presenceByBareJid[normalized] = presence;
      final status = presence.status?.toLowerCase();
      if (status != 'unavailable') {
        _lastSeenAt[normalized] = DateTime.now();
        _serverNotFound.remove(normalized);
      }
      notifyListeners();
    });
    _presenceErrorSubscription?.cancel();
    _presenceErrorSubscription = presenceManager.errorStream.listen((error) {
      final stanza = error.presenceStanza;
      final jid = stanza?.fromJid?.userAtDomain;
      if (jid == null || jid.isEmpty) {
        return;
      }
      final normalized = _bareJid(jid);
      final errorElement = stanza?.getChild('error');
      final hasServerNotFound = errorElement?.children.any((child) =>
              child.name == 'remote-server-not-found' ||
              child.name == 'server-not-found') ??
          false;
      if (hasServerNotFound) {
        _serverNotFound.add(normalized);
        notifyListeners();
      }
    });
  }

  void _setupPep() {
    final connection = _connection;
    final storage = _storage;
    if (connection == null || storage == null || _currentUserBareJid == null) {
      return;
    }
    _pepManager = PepManager(
      connection: connection,
      storage: storage,
      selfBareJid: _currentUserBareJid!,
      onUpdate: notifyListeners,
    );
    _pepCapsManager = PepCapsManager(
      connection: connection,
      pepManager: _pepManager!,
    );
    _pepManager?.requestMetadataIfMissing(_currentUserBareJid!);
    for (final contact in _contacts) {
      _pepManager?.requestMetadataIfMissing(contact.jid);
    }
    _pepSubscription?.cancel();
    _pepSubscription = connection.inStanzasStream.listen((stanza) {
      if (stanza == null) {
        return;
      }
      _handleDisplayedSyncStanza(stanza);
      _pepManager?.handleStanza(stanza);
      _pepCapsManager?.handleStanza(stanza);
      _bookmarksManager?.handleStanza(stanza);
      if (stanza is PresenceStanza) {
        _handleVcardPresenceUpdate(stanza);
      }
    });
  }

  void _setupBookmarks() {
    final connection = _connection;
    if (connection == null || _currentUserBareJid == null) {
      return;
    }
    _bookmarksManager = BookmarksManager(
      connection: connection,
      selfBareJid: _currentUserBareJid!,
      onUpdate: (bookmarks) {
        _bookmarks
          ..clear()
          ..addAll(bookmarks);
        _bookmarkPersistor?.call(List.unmodifiable(_bookmarks));
        _autojoinRooms();
        notifyListeners();
      },
    );
    _bookmarksManager?.seedBookmarks(_bookmarks);
    _bookmarksManager?.requestBookmarks();
  }

  void _setupDisplayedSync() {
    final connection = _connection;
    if (connection == null || _currentUserBareJid == null) {
      return;
    }
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(_currentUserBareJid!);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', 'urn:xmpp:mds:displayed:0'));
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
  }

  void _handleDisplayedSyncStanza(AbstractStanza stanza) {
    if (stanza is MessageStanza) {
      _handleDisplayedSyncEvent(stanza);
      return;
    }
    if (stanza is IqStanza) {
      _handleDisplayedSyncResult(stanza);
    }
  }

  void _handleDisplayedSyncEvent(MessageStanza stanza) {
    final event = stanza.children.firstWhere(
      (child) => child.name == 'event' && child.getAttribute('xmlns')?.value == 'http://jabber.org/protocol/pubsub#event',
      orElse: () => XmppElement(),
    );
    if (event.name != 'event') {
      return;
    }
    final items = event.getChild('items');
    if (items == null || items.getAttribute('node')?.value != 'urn:xmpp:mds:displayed:0') {
      return;
    }
    _applyDisplayedSyncItems(items);
  }

  void _handleDisplayedSyncResult(IqStanza stanza) {
    if (stanza.type != IqStanzaType.RESULT) {
      return;
    }
    final pubsub = stanza.getChild('pubsub');
    if (pubsub == null || pubsub.getAttribute('xmlns')?.value != 'http://jabber.org/protocol/pubsub') {
      return;
    }
    final items = pubsub.getChild('items');
    if (items == null || items.getAttribute('node')?.value != 'urn:xmpp:mds:displayed:0') {
      return;
    }
    _applyDisplayedSyncItems(items);
  }

  void _applyDisplayedSyncItems(XmppElement items) {
    var updated = false;
    for (final item in items.children.where((child) => child.name == 'item')) {
      final id = item.getAttribute('id')?.value?.trim() ?? '';
      if (id.isEmpty) {
        continue;
      }
      final payload = item.getChild('displayed');
      if (payload == null ||
          payload.getAttribute('xmlns')?.value != 'urn:xmpp:mds:displayed:0') {
        continue;
      }
      final stanzaIdElement = payload.getChild('stanza-id');
      final stanzaId = stanzaIdElement?.getAttribute('id')?.value?.trim() ?? '';
      if (stanzaId.isEmpty) {
        continue;
      }
      if (_displayedStanzaIdByChat[id] == stanzaId) {
        continue;
      }
      _displayedStanzaIdByChat[id] = stanzaId;
      if (_applyDisplayedStateForChat(id)) {
        updated = true;
      }
    }
    if (updated) {
      _storage?.storeDisplayedSync(Map<String, String>.from(_displayedStanzaIdByChat));
      notifyListeners();
    }
  }

  bool _applyDisplayedStateForChat(String bareJid) {
    final normalized = _bareJid(bareJid);
    final stanzaId = _displayedStanzaIdByChat[normalized];
    if (stanzaId == null || stanzaId.isEmpty) {
      return false;
    }
    final list = isBookmark(normalized)
        ? _roomMessages[normalized]
        : _messages[normalized];
    if (list == null || list.isEmpty) {
      return false;
    }
    ChatMessage? matched;
    for (final message in list) {
      if (message.stanzaId == stanzaId) {
        matched = message;
      }
    }
    if (matched == null) {
      return false;
    }
    final existing = _displayedAtByChat[normalized];
    if (existing != null && !matched.timestamp.isAfter(existing)) {
      return false;
    }
    _displayedAtByChat[normalized] = matched.timestamp;
    return true;
  }

  void _setupPrivacyLists() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    _privacyListsManager = PrivacyListsManager.getInstance(connection);
    _refreshBlockList();
  }

  Future<void> _refreshBlockList() async {
    final manager = _privacyListsManager;
    if (manager == null || !manager.isPrivacyListsSupported()) {
      return;
    }
    try {
      final lists = await manager.getAllLists();
      if (lists.allPrivacyLists?.contains(_blockListName) != true) {
        return;
      }
      final items = await manager.getListByName(_blockListName);
      _blockedJids
        ..clear()
        ..addAll(items
            .where((item) => item.type == PrivacyType.JID && item.action == PrivacyAction.DENY)
            .map((item) => item.value ?? '')
            .where((jid) => jid.isNotEmpty));
      notifyListeners();
    } catch (_) {
      // Ignore privacy list failures.
    }
  }

  Future<bool> _applyBlockList() async {
    final manager = _privacyListsManager;
    if (manager == null || !manager.isPrivacyListsSupported()) {
      return false;
    }
    try {
      final items = <PrivacyListItem>[];
      var order = 1;
      for (final jid in _blockedJids) {
        items.add(PrivacyListItem(
          type: PrivacyType.JID,
          value: jid,
          action: PrivacyAction.DENY,
          order: order++,
          controlStanzas: const [
            PrivacyControlStanza.MESSAGE,
            PrivacyControlStanza.IQ,
            PrivacyControlStanza.PRESENCE_IN,
            PrivacyControlStanza.PRESENCE_OUT,
          ],
        ));
      }
      final list = PrivacyList(_blockListName, items);
      await manager.createPrivacyList(list);
      await manager.setActiveList(_blockListName);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _setupKeepalive() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    _smNonzaSubscription?.cancel();
    _smNonzaSubscription = connection.inNonzasStream.listen((nonza) {
      final xmlns = nonza.getAttribute('xmlns')?.value;
      if (nonza.name == 'a' && xmlns == 'urn:xmpp:sm:3') {
        final startedAt = _pendingSmAckAt;
        if (startedAt != null) {
          _pendingSmAckAt = null;
          _smAckTimeoutTimer?.cancel();
          _smAckTimeoutTimer = null;
          _lastPingLatency = DateTime.now().difference(startedAt);
          _lastPingAt = DateTime.now();
          notifyListeners();
        }
      }
    });

    _pingSubscription?.cancel();
    _pingSubscription = connection.inStanzasStream.listen((stanza) {
      if (stanza is IqStanza) {
        final carbonsId = _carbonsRequestId;
        if (carbonsId != null && stanza.id == carbonsId) {
          _carbonsEnabled = stanza.type == IqStanzaType.RESULT;
          _carbonsRequestId = null;
          notifyListeners();
          return;
        }
        final id = stanza.id;
        if (id == null || !_pendingPings.containsKey(id)) {
          return;
        }
        if (stanza.type == IqStanzaType.RESULT || stanza.type == IqStanzaType.ERROR) {
          final startedAt = _pendingPings.remove(id);
          final timer = _pingTimeoutTimers.remove(id);
          timer?.cancel();
          _pingTimeoutShort.remove(id);
          if (startedAt != null) {
            _lastPingLatency = DateTime.now().difference(startedAt);
            _lastPingAt = DateTime.now();
            notifyListeners();
          }
        }
      }
    });

    _restartKeepaliveTimer();
    _requestCarbons();
  }

  Duration get _currentPingInterval =>
      _backgroundMode ? _pingIntervalBackground : _pingIntervalForeground;

  Duration get _currentSmAckInterval =>
      _backgroundMode ? _smAckIntervalBackground : _smAckIntervalForeground;

  void _restartKeepaliveTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_currentPingInterval, (_) {
      if (_isStreamManagementEnabled()) {
        _sendSmAckRequest();
      } else {
        if (_pendingPings.isNotEmpty) {
          return;
        }
        _sendPing();
      }
    });
    if (_isStreamManagementEnabled()) {
      _sendSmAckRequest(force: true);
    } else {
      _sendPing();
    }
  }

  void _ensureChatSubscription(Chat chat) {
    final buddyJid = chat.jid.userAtDomain;
    if (_chatMessageSubscriptions.containsKey(buddyJid)) {
      return;
    }
    _ensureContact(buddyJid);
    final existing = _messages[buddyJid];
    if (existing == null || existing.isEmpty) {
      for (final message in chat.messages ?? const <Message>[]) {
        final from = message.from?.userAtDomain ?? 'unknown';
        final to = message.to?.userAtDomain ?? '';
        final body = message.text ?? '';
        final oobUrl = _extractOobUrlFromStanza(message.messageStanza);
        final rawXml = _serializeStanza(message.messageStanza);
        if (body.trim().isEmpty && (oobUrl == null || oobUrl.isEmpty)) {
          continue;
        }
        final outgoing = from == (_currentUserBareJid ?? '');
        _addMessage(
          bareJid: outgoing ? to : from,
          from: from,
          to: to,
          body: body,
          rawXml: rawXml,
          oobUrl: oobUrl,
          outgoing: outgoing,
          timestamp: message.time,
          messageId: message.messageId,
          mamId: message.mamResultId,
          stanzaId: message.stanzaId,
        );
      }
    }
    _chatMessageSubscriptions[buddyJid] =
        chat.newMessageStream.listen((message) {
      final from = message.from?.userAtDomain ?? 'unknown';
      final to = message.to?.userAtDomain ?? '';
      final body = message.text ?? '';
      final oobUrl = _extractOobUrlFromStanza(message.messageStanza);
      final rawXml = _serializeStanza(message.messageStanza);
      if (body.trim().isEmpty && (oobUrl == null || oobUrl.isEmpty)) {
        return;
      }
      final outgoing = from == (_currentUserBareJid ?? '');
      _addMessage(
        bareJid: outgoing ? to : from,
        from: from,
        to: to,
        body: body,
        rawXml: rawXml,
        oobUrl: oobUrl,
        outgoing: outgoing,
        timestamp: message.time,
        messageId: message.messageId,
        mamId: message.mamResultId,
        stanzaId: message.stanzaId,
      );
    });

    _chatStateSubscriptions[buddyJid]?.cancel();
    _chatStateSubscriptions[buddyJid] =
        chat.remoteStateStream.listen((state) {
      _chatStates[buddyJid] = state;
      notifyListeners();
    });
  }

  void _addMessage({
    required String bareJid,
    required String from,
    required String to,
    required String body,
    required String rawXml,
    required bool outgoing,
    required DateTime timestamp,
    String? messageId,
    String? mamId,
    String? stanzaId,
    String? oobUrl,
  }) {
    final normalized = _bareJid(bareJid);
    _ensureContact(normalized);

    final list = _messages.putIfAbsent(normalized, () => <ChatMessage>[]);
    if (messageId != null && messageId.isNotEmpty) {
      final existingIndex = list.indexWhere((message) =>
          message.messageId == messageId && _bareJid(message.from) == _bareJid(from));
      if (existingIndex != -1) {
        final existing = list[existingIndex];
        final nextMamId = (mamId != null && mamId.isNotEmpty) ? mamId : existing.mamId;
        final nextStanzaId =
            (stanzaId != null && stanzaId.isNotEmpty) ? stanzaId : existing.stanzaId;
        final nextOobUrl = (oobUrl != null && oobUrl.isNotEmpty) ? oobUrl : existing.oobUrl;
        final nextRawXml = rawXml.isNotEmpty ? rawXml : existing.rawXml;
        if (nextMamId != existing.mamId ||
            nextStanzaId != existing.stanzaId ||
            nextOobUrl != existing.oobUrl ||
            nextRawXml != existing.rawXml) {
          list[existingIndex] = ChatMessage(
            from: existing.from,
            to: existing.to,
            body: existing.body,
            outgoing: existing.outgoing,
            timestamp: existing.timestamp,
            messageId: existing.messageId,
            mamId: nextMamId,
            stanzaId: nextStanzaId,
            oobUrl: nextOobUrl,
            rawXml: nextRawXml,
            acked: existing.acked,
            receiptReceived: existing.receiptReceived,
            displayed: existing.displayed,
          );
          notifyListeners();
          _messagePersistor?.call(normalized, List.unmodifiable(list));
        }
        return;
      }
    }
    if (mamId != null && mamId.isNotEmpty && list.any((message) => message.mamId == mamId)) {
      return;
    }
    if (stanzaId != null &&
        stanzaId.isNotEmpty &&
        list.any((message) =>
            message.stanzaId == stanzaId && _bareJid(message.from) == _bareJid(from))) {
      return;
    }
    final hasIncomingIds =
        (mamId != null && mamId.isNotEmpty) || (stanzaId != null && stanzaId.isNotEmpty);
    if (hasIncomingIds) {
      final merged = _mergeMamIdsIntoExisting(
        list,
        from: from,
        to: to,
        body: body,
        oobUrl: oobUrl,
        rawXml: rawXml,
        outgoing: outgoing,
        timestamp: timestamp,
        messageId: messageId,
        mamId: mamId,
        stanzaId: stanzaId,
      );
      if (merged) {
        notifyListeners();
        _messagePersistor?.call(normalized, List.unmodifiable(list));
        return;
      }
    }
    final prependOffset = _mamPrependOffset[normalized];
    if (mamId != null && mamId.isNotEmpty && prependOffset != null) {
      final insertIndex = prependOffset.clamp(0, list.length);
      list.insert(
        insertIndex,
        ChatMessage(
          from: from,
          to: to,
          body: body,
          outgoing: outgoing,
          timestamp: timestamp,
          messageId: messageId,
          mamId: mamId,
          stanzaId: stanzaId,
          oobUrl: oobUrl,
          rawXml: rawXml,
        ),
      );
      _mamPrependOffset[normalized] = prependOffset + 1;
      if (!outgoing) {
        _lastSeenAt[normalized] ??= timestamp;
      }
      notifyListeners();
      _messagePersistor?.call(normalized, List.unmodifiable(list));
      return;
    }
    final newMessage = ChatMessage(
      from: from,
      to: to,
      body: body,
      outgoing: outgoing,
      timestamp: timestamp,
      messageId: messageId,
      mamId: mamId,
      stanzaId: stanzaId,
      oobUrl: oobUrl,
      rawXml: rawXml,
    );
    _insertMessageOrdered(list, newMessage);
    if (!outgoing) {
      _lastSeenAt[normalized] ??= timestamp;
    }
    notifyListeners();
    _messagePersistor?.call(normalized, List.unmodifiable(list));
    if (!outgoing && (mamId == null || mamId.isEmpty)) {
      _incomingMessageHandler?.call(normalized, newMessage);
    }
  }

  void _addRoomMessage({
    required String roomJid,
    required String from,
    required String body,
    required String rawXml,
    required bool outgoing,
    required DateTime timestamp,
    String? messageId,
    String? mamId,
    String? stanzaId,
    String? oobUrl,
  }) {
    final normalized = _bareJid(roomJid);
    final list = _roomMessages.putIfAbsent(normalized, () => <ChatMessage>[]);
    if (messageId != null && messageId.isNotEmpty) {
      final existingIndex = list.indexWhere((message) =>
          message.messageId == messageId && _bareJid(message.from) == _bareJid(from));
      if (existingIndex != -1) {
        final existing = list[existingIndex];
        final nextMamId = (mamId != null && mamId.isNotEmpty) ? mamId : existing.mamId;
        final nextStanzaId =
            (stanzaId != null && stanzaId.isNotEmpty) ? stanzaId : existing.stanzaId;
        final nextReceiptReceived =
            (!outgoing && existing.outgoing) ? true : existing.receiptReceived;
        final nextTimestamp = (!outgoing && existing.outgoing) ? timestamp : existing.timestamp;
        final nextOobUrl = (oobUrl != null && oobUrl.isNotEmpty) ? oobUrl : existing.oobUrl;
        final nextRawXml = rawXml.isNotEmpty ? rawXml : existing.rawXml;
        if (nextMamId != existing.mamId ||
            nextStanzaId != existing.stanzaId ||
            nextReceiptReceived != existing.receiptReceived ||
            nextTimestamp != existing.timestamp ||
            nextOobUrl != existing.oobUrl ||
            nextRawXml != existing.rawXml) {
          final updated = ChatMessage(
            from: existing.from,
            to: existing.to,
            body: existing.body,
            outgoing: existing.outgoing,
            timestamp: nextTimestamp,
            messageId: existing.messageId,
            mamId: nextMamId,
            stanzaId: nextStanzaId,
            oobUrl: nextOobUrl,
            rawXml: nextRawXml,
            acked: existing.acked,
            receiptReceived: nextReceiptReceived,
            displayed: existing.displayed,
          );
          list.removeAt(existingIndex);
          _insertMessageOrdered(list, updated);
          notifyListeners();
          _roomMessagePersistor?.call(normalized, List.unmodifiable(list));
        }
        return;
      }
    }
    if (mamId != null && mamId.isNotEmpty && list.any((message) => message.mamId == mamId)) {
      return;
    }
    if (stanzaId != null && stanzaId.isNotEmpty && list.any((message) => message.stanzaId == stanzaId)) {
      return;
    }
    final prependOffset = _mamPrependOffset[normalized];
    if (mamId != null && mamId.isNotEmpty && prependOffset != null) {
      final insertIndex = prependOffset.clamp(0, list.length);
      list.insert(
        insertIndex,
        ChatMessage(
          from: from,
          to: normalized,
          body: body,
          outgoing: outgoing,
          timestamp: timestamp,
          messageId: messageId,
          mamId: mamId,
          stanzaId: stanzaId,
          oobUrl: oobUrl,
          rawXml: rawXml,
        ),
      );
      _mamPrependOffset[normalized] = prependOffset + 1;
      notifyListeners();
      _roomMessagePersistor?.call(normalized, List.unmodifiable(list));
      if (!outgoing) {
        _incomingRoomMessageHandler?.call(normalized, list[insertIndex]);
      }
      return;
    }
    final newMessage = ChatMessage(
      from: from,
      to: normalized,
      body: body,
      outgoing: outgoing,
      timestamp: timestamp,
      messageId: messageId,
      mamId: mamId,
      stanzaId: stanzaId,
      oobUrl: oobUrl,
      rawXml: rawXml,
    );
    _insertMessageOrdered(list, newMessage);
    notifyListeners();
    _roomMessagePersistor?.call(normalized, List.unmodifiable(list));
    if (!outgoing && (mamId == null || mamId.isEmpty)) {
      _incomingRoomMessageHandler?.call(normalized, newMessage);
    }
  }

  void _applyAckByMessageId(String messageId) {
    for (final entry in _messages.entries) {
      final normalized = _bareJid(entry.key);
      if (_updateOutgoingStatus(normalized, messageId, acked: true)) {
        break;
      }
    }
  }

  void _applyRoomAckByMessageId(String messageId) {
    for (final entry in _roomMessages.entries) {
      final normalized = _bareJid(entry.key);
      if (_updateOutgoingRoomStatus(normalized, messageId, acked: true)) {
        break;
      }
    }
  }

  void _applyReceipt(String bareJid, String messageId) {
    final normalized = _bareJid(bareJid);
    _updateOutgoingStatus(normalized, messageId, receiptReceived: true);
  }

  void _applyDisplayed(String bareJid, String messageId) {
    final normalized = _bareJid(bareJid);
    _updateOutgoingStatus(normalized, messageId, displayed: true);
  }

  void _insertMessageOrdered(List<ChatMessage> list, ChatMessage message) {
    if (list.isEmpty) {
      list.add(message);
      return;
    }
    final insertIndex = list.indexWhere((existing) =>
        message.timestamp.isBefore(existing.timestamp));
    if (insertIndex == -1) {
      list.add(message);
    } else {
      list.insert(insertIndex, message);
    }
  }

  bool _updateOutgoingStatus(
    String bareJid,
    String messageId, {
    bool? acked,
    bool? receiptReceived,
    bool? displayed,
  }) {
    final list = _messages[bareJid];
    if (list == null || list.isEmpty) {
      return false;
    }
    for (var i = list.length - 1; i >= 0; i--) {
      final existing = list[i];
      if (!existing.outgoing || existing.messageId != messageId) {
        continue;
      }
      final nextAcked = acked ?? existing.acked;
      final nextReceipt = receiptReceived ?? existing.receiptReceived;
      final nextDisplayed = displayed ?? existing.displayed;
      if (nextAcked == existing.acked &&
          nextReceipt == existing.receiptReceived &&
          nextDisplayed == existing.displayed) {
        return true;
      }
      list[i] = ChatMessage(
        from: existing.from,
        to: existing.to,
        body: existing.body,
        outgoing: existing.outgoing,
        timestamp: existing.timestamp,
        messageId: existing.messageId,
        mamId: existing.mamId,
        stanzaId: existing.stanzaId,
        oobUrl: existing.oobUrl,
        acked: nextAcked,
        receiptReceived: nextReceipt,
        displayed: nextDisplayed,
      );
      notifyListeners();
      _messagePersistor?.call(bareJid, List.unmodifiable(list));
      return true;
    }
    return false;
  }

  bool _updateOutgoingRoomStatus(
    String roomJid,
    String messageId, {
    bool? acked,
    bool? receiptReceived,
    bool? displayed,
  }) {
    final normalized = _bareJid(roomJid);
    final list = _roomMessages[normalized];
    if (list == null || list.isEmpty) {
      return false;
    }
    for (var i = list.length - 1; i >= 0; i--) {
      final existing = list[i];
      if (!existing.outgoing || existing.messageId != messageId) {
        continue;
      }
      final nextAcked = acked ?? existing.acked;
      final nextReceipt = receiptReceived ?? existing.receiptReceived;
      final nextDisplayed = displayed ?? existing.displayed;
      if (nextAcked == existing.acked &&
          nextReceipt == existing.receiptReceived &&
          nextDisplayed == existing.displayed) {
        return true;
      }
      list[i] = ChatMessage(
        from: existing.from,
        to: existing.to,
        body: existing.body,
        outgoing: existing.outgoing,
        timestamp: existing.timestamp,
        messageId: existing.messageId,
        mamId: existing.mamId,
        stanzaId: existing.stanzaId,
        oobUrl: existing.oobUrl,
        acked: nextAcked,
        receiptReceived: nextReceipt,
        displayed: nextDisplayed,
      );
      notifyListeners();
      return true;
    }
    return false;
  }

  void _sendDisplayedForChat(String bareJid) {
    if (_currentUserBareJid == null) {
      return;
    }
    final normalized = _bareJid(bareJid);
    final list = _messages[normalized];
    if (list == null || list.isEmpty) {
      return;
    }
    for (var i = list.length - 1; i >= 0; i--) {
      final message = list[i];
      if (message.outgoing || message.messageId == null || message.messageId!.isEmpty) {
        continue;
      }
      final lastSent = _lastDisplayedMarkerIdByChat[normalized];
      if (lastSent == message.messageId) {
        return;
      }
      _lastDisplayedMarkerIdByChat[normalized] = message.messageId!;
      _sendMarker(normalized, message.messageId!, 'displayed');
      return;
    }
  }

  void _publishDisplayedState(String bareJid) {
    final connection = _connection;
    if (connection == null || _currentUserBareJid == null) {
      return;
    }
    final normalized = _bareJid(bareJid);
    final list = isBookmark(normalized)
        ? _roomMessages[normalized]
        : _messages[normalized];
    if (list == null || list.isEmpty) {
      return;
    }
    ChatMessage? latest;
    for (final message in list.reversed) {
      if (!message.outgoing && message.stanzaId != null && message.stanzaId!.isNotEmpty) {
        latest = message;
        break;
      }
    }
    if (latest == null) {
      return;
    }
    final stanzaId = latest.stanzaId!;
    if (_displayedStanzaIdByChat[normalized] == stanzaId) {
      return;
    }
    _displayedStanzaIdByChat[normalized] = stanzaId;
    _displayedAtByChat[normalized] = latest.timestamp;
    _storage?.storeDisplayedSync(Map<String, String>.from(_displayedStanzaIdByChat));
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    iqStanza.toJid = Jid.fromFullJid(_currentUserBareJid!);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    final publish = XmppElement()..name = 'publish';
    publish.addAttribute(XmppAttribute('node', 'urn:xmpp:mds:displayed:0'));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', normalized));
    final displayed = XmppElement()..name = 'displayed';
    displayed.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:mds:displayed:0'));
    final stanzaIdElement = XmppElement()..name = 'stanza-id';
    stanzaIdElement.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sid:0'));
    stanzaIdElement.addAttribute(XmppAttribute('id', stanzaId));
    final byValue = isBookmark(normalized) ? normalized : (_currentUserBareJid ?? '');
    if (byValue.isNotEmpty) {
      stanzaIdElement.addAttribute(XmppAttribute('by', byValue));
    }
    displayed.addChild(stanzaIdElement);
    item.addChild(displayed);
    publish.addChild(item);
    pubsub.addChild(publish);
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
    notifyListeners();
  }

  bool _mergeMamIdsIntoExisting(
    List<ChatMessage> list, {
    required String from,
    required String to,
    required String body,
    String? oobUrl,
    String? rawXml,
    required bool outgoing,
    required DateTime timestamp,
    String? messageId,
    String? mamId,
    String? stanzaId,
  }) {
    const mergeWindow = Duration(minutes: 2);
    for (var i = 0; i < list.length; i++) {
      final existing = list[i];
      if (messageId != null &&
          messageId.isNotEmpty &&
          existing.messageId == messageId &&
          ((existing.mamId ?? '').isEmpty || (existing.stanzaId ?? '').isEmpty)) {
        final nextRawXml = (rawXml != null && rawXml.isNotEmpty) ? rawXml : existing.rawXml;
        list[i] = ChatMessage(
          from: existing.from,
          to: existing.to,
          body: existing.body,
          outgoing: existing.outgoing,
          timestamp: existing.timestamp,
          messageId: existing.messageId,
          mamId: (mamId != null && mamId.isNotEmpty) ? mamId : existing.mamId,
          stanzaId: (stanzaId != null && stanzaId.isNotEmpty) ? stanzaId : existing.stanzaId,
          oobUrl: existing.oobUrl,
          rawXml: nextRawXml,
          acked: existing.acked,
          receiptReceived: existing.receiptReceived,
          displayed: existing.displayed,
        );
        return true;
      }
      if (existing.body != body ||
          (existing.oobUrl ?? '') != (oobUrl ?? '') ||
          existing.from != from ||
          existing.to != to ||
          existing.outgoing != outgoing) {
        continue;
      }
      final timeDelta = existing.timestamp.difference(timestamp).abs();
      if (timeDelta > mergeWindow) {
        continue;
      }
      if ((existing.mamId ?? '').isNotEmpty || (existing.stanzaId ?? '').isNotEmpty) {
        continue;
      }
      list[i] = ChatMessage(
        from: existing.from,
        to: existing.to,
        body: existing.body,
        outgoing: existing.outgoing,
        timestamp: existing.timestamp,
        mamId: (mamId != null && mamId.isNotEmpty) ? mamId : existing.mamId,
        stanzaId: (stanzaId != null && stanzaId.isNotEmpty) ? stanzaId : existing.stanzaId,
        oobUrl: existing.oobUrl,
        rawXml: existing.rawXml,
        acked: existing.acked,
        receiptReceived: existing.receiptReceived,
        displayed: existing.displayed,
      );
      return true;
    }
    return false;
  }

  void _ensureContact(String bareJid, {String? name, List<String>? groups, String? subscriptionType}) {
    final normalized = _bareJid(bareJid);
    if (isBookmark(normalized)) {
      return;
    }
    final index = _contacts.indexWhere((entry) => entry.jid == normalized);
    if (index == -1) {
      final entry = ContactEntry(
        jid: normalized,
        name: name,
        groups: groups ?? const [],
        subscriptionType: subscriptionType,
      );
      _contacts.add(entry);
      _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
      notifyListeners();
      _rosterPersistor?.call(List.unmodifiable(_contacts));
      _pepManager?.requestMetadataIfMissing(entry.jid);
      _requestVcardAvatar(entry.jid);
      return;
    }
    final existing = _contacts[index];
    final nextName = (name != null && name.trim().isNotEmpty) ? name : existing.name;
    final nextGroups = (groups != null && groups.isNotEmpty) ? groups : existing.groups;
    final nextSubscription = (subscriptionType != null && subscriptionType.isNotEmpty)
        ? subscriptionType
        : existing.subscriptionType;
    if (nextName != existing.name ||
        !_listEquals(nextGroups, existing.groups) ||
        nextSubscription != existing.subscriptionType) {
      _contacts[index] = existing.copyWith(
        name: nextName,
        groups: nextGroups,
        subscriptionType: nextSubscription,
      );
      _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
      notifyListeners();
      _rosterPersistor?.call(List.unmodifiable(_contacts));
    }
  }

  void _ensureRoom(String roomJid) {
    final normalized = _bareJid(roomJid);
    if (_rooms.containsKey(normalized)) {
      return;
    }
    _rooms[normalized] = RoomEntry(roomJid: normalized);
  }

  String _roomNickFor(String roomJid) {
    final existing = _rooms[roomJid]?.nick;
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final bookmark = _bookmarks.firstWhere(
      (entry) => entry.jid == roomJid,
      orElse: () => ContactEntry(jid: ''),
    );
    if (bookmark.jid.isNotEmpty && bookmark.bookmarkNick?.isNotEmpty == true) {
      return bookmark.bookmarkNick!;
    }
    final bare = _currentUserBareJid ?? '';
    final parts = bare.split('@');
    return parts.isNotEmpty ? parts.first : 'wimsy';
  }

  String? _roomPasswordFor(String roomJid) {
    final bookmark = _bookmarks.firstWhere(
      (entry) => entry.jid == roomJid,
      orElse: () => ContactEntry(jid: ''),
    );
    if (bookmark.jid.isNotEmpty && bookmark.bookmarkPassword?.isNotEmpty == true) {
      return bookmark.bookmarkPassword;
    }
    return null;
  }

  void _requestRoomMam(String roomJid, {String? before}) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final mam = connection.getMamModule();
    if (!mam.enabled) {
      return;
    }
    mam.queryById(
      toJid: Jid.fromFullJid(roomJid),
      max: 25,
      before: before,
    );
  }

  void _autojoinRooms() {
    if (_mucManager == null) {
      return;
    }
    for (final bookmark in _bookmarks) {
      if (!bookmark.bookmarkAutoJoin) {
        continue;
      }
      final normalized = _bareJid(bookmark.jid);
      final existing = _rooms[normalized];
      if (existing?.joined == true) {
        continue;
      }
      joinRoom(normalized);
    }
  }

  int _contactSort(ContactEntry a, ContactEntry b) {
    final aLastMessage = _latestTimestampForJid(a.jid);
    final bLastMessage = _latestTimestampForJid(b.jid);
    if (aLastMessage != null || bLastMessage != null) {
      if (aLastMessage == null) {
        return 1;
      }
      if (bLastMessage == null) {
        return -1;
      }
      final compareMessage = bLastMessage.compareTo(aLastMessage);
      if (compareMessage != 0) {
        return compareMessage;
      }
    }
    final aLastSeen = _lastSeenAt[_bareJid(a.jid)];
    final bLastSeen = _lastSeenAt[_bareJid(b.jid)];
    if (aLastSeen != null || bLastSeen != null) {
      if (aLastSeen == null) {
        return 1;
      }
      if (bLastSeen == null) {
        return -1;
      }
      final compareSeen = bLastSeen.compareTo(aLastSeen);
      if (compareSeen != 0) {
        return compareSeen;
      }
    }
    return a.displayName.compareTo(b.displayName);
  }

  DateTime? _latestTimestampForJid(String bareJid) {
    final normalized = _bareJid(bareJid);
    if (isBookmark(normalized)) {
      final roomMessages = _roomMessages[normalized];
      if (roomMessages == null || roomMessages.isEmpty) {
        return null;
      }
      return roomMessages.last.timestamp;
    }
    final messages = _messages[normalized];
    if (messages == null || messages.isEmpty) {
      return null;
    }
    return messages.last.timestamp;
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  void _setError(String message) {
    _status = XmppStatus.error;
    _errorMessage = message;
    notifyListeners();
  }

  Future<void> _safeClose({required bool preserveCache}) async {
    _pingTimer?.cancel();
    _pingTimer = null;
    _smAckTimeoutTimer?.cancel();
    _smAckTimeoutTimer = null;
    _csiIdleTimer?.cancel();
    _csiIdleTimer = null;
    _smNonzaSubscription?.cancel();
    _smNonzaSubscription = null;
    _pingSubscription?.cancel();
    _pingSubscription = null;
    _messageStanzaSubscription?.cancel();
    _messageStanzaSubscription = null;
    _smDeliveredSubscription?.cancel();
    _smDeliveredSubscription = null;
    _pepSubscription?.cancel();
    _pepSubscription = null;
    _pendingPings.clear();
    for (final timer in _pingTimeoutTimers.values) {
      timer.cancel();
    }
    _pingTimeoutTimers.clear();
    _pingTimeoutShort.clear();
    _pendingSmAckAt = null;
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _rosterSubscription?.cancel();
    _rosterSubscription = null;
    _chatListSubscription?.cancel();
    _chatListSubscription = null;
    _presenceSubscription?.cancel();
    _presenceSubscription = null;
    _presenceErrorSubscription?.cancel();
    _presenceErrorSubscription = null;
    for (final subscription in _roomSubscriptions.values) {
      subscription.cancel();
    }
    _roomSubscriptions.clear();
    for (final subscription in _chatMessageSubscriptions.values) {
      subscription.cancel();
    }
    _chatMessageSubscriptions.clear();
    for (final subscription in _chatStateSubscriptions.values) {
      subscription.cancel();
    }
    _chatStateSubscriptions.clear();

    _activeChatBareJid = null;
    _currentUserBareJid = null;
    _lastConnectionState = null;
    _chatManager = null;
    if (!preserveCache) {
      _contacts.clear();
      _bookmarks.clear();
      _messages.clear();
      _seededMessageJids.clear();
      _roomMessages.clear();
      _seededRoomMessageJids.clear();
      _rosterVersion = null;
    }
    _presenceByBareJid.clear();
    _roomMessages.clear();
    _rooms.clear();
    _roomOccupants.clear();
    _lastSeenAt.clear();
    _serverNotFound.clear();
    _chatStates.clear();
    _lastDisplayedMarkerIdByChat.clear();
    _displayedStanzaIdByChat.clear();
    _displayedAtByChat.clear();
    _lastPingLatency = null;
    _lastPingAt = null;
    _carbonsEnabled = false;
    _csiInactive = false;
    _carbonsRequestId = null;
    _mamBackfillAt.clear();
    _mamPageRequestAt.clear();
    _mamPrependOffset.clear();
    for (final timer in _mamPrependReset.values) {
      timer.cancel();
    }
    _mamPrependReset.clear();
    _lastGlobalMamSyncAt = null;
    _globalBackfillTimer?.cancel();
    _globalBackfillTimer = null;
    _globalBackfillInProgress = false;
    _pepManager = null;
    _pepCapsManager = null;
    _bookmarksManager = null;
    _privacyListsManager = null;
    _blockedJids.clear();
    _vcardAvatarBytes.clear();
    _vcardRequests.clear();

    try {
      final connection = _connection;
      if (connection != null) {
        connection.dispose();
        Connection.removeInstance(connection.account);
      }
    } catch (_) {
      // Ignore close errors to keep disconnect resilient.
    } finally {
      _connection = null;
    }
  }

  bool _looksLikeJid(String jid) {
    final parsed = Jid.fromFullJid(jid);
    return parsed.isValid();
  }

  String _domainFromBareJid(String bareJid) {
    final parts = bareJid.split('@');
    return parts.length == 2 ? parts[1] : '';
  }

  String _bareJid(String jid) {
    final trimmed = jid.trim();
    final slashIndex = trimmed.indexOf('/');
    if (slashIndex == -1) {
      return trimmed;
    }
    return trimmed.substring(0, slashIndex);
  }

  bool _isTerminalError(XmppConnectionState state) {
    return state == XmppConnectionState.AuthenticationFailure ||
        state == XmppConnectionState.AuthenticationNotSupported ||
        state == XmppConnectionState.StartTlsFailed ||
        state == XmppConnectionState.ForcefullyClosed ||
        state == XmppConnectionState.Closed;
  }

  String _connectionErrorMessage(XmppConnectionState state) {
    switch (state) {
      case XmppConnectionState.AuthenticationFailure:
        return 'Authentication failed.';
      case XmppConnectionState.AuthenticationNotSupported:
        return 'Authentication not supported.';
      case XmppConnectionState.StartTlsFailed:
        return 'StartTLS failed.';
      case XmppConnectionState.ForcefullyClosed:
      case XmppConnectionState.Closed:
        return 'Connection closed.';
      default:
        return 'Connection error.';
    }
  }

  void _sendInitialPresence() {
    _sendPresence(_selfPresence);
  }

  void _sendPresence(PresenceData presence) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    debugPrint('XMPP sending presence ${presence.showElement} ${presence.status ?? ''}');
    final stanza = PresenceStanza();
    stanza.show = presence.showElement;
    stanza.status = presence.status;
    stanza.addChild(_buildCapsElement());
    connection.writeStanza(stanza);
  }

  XmppElement _buildCapsElement() {
    final caps = XmppElement()..name = 'c';
    caps.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/caps'));
    caps.addAttribute(XmppAttribute('hash', _capsHash));
    caps.addAttribute(XmppAttribute('node', _capsNode));
    caps.addAttribute(XmppAttribute('ver', _capsVerValue()));
    return caps;
  }

  String _capsVerValue() {
    final cached = _capsVer;
    if (cached != null) {
      return cached;
    }
    final buffer = StringBuffer();
    final identities = SERVICE_DISCOVERY_IDENTITIES.map((identity) {
      return [
        identity['category'] ?? '',
        identity['type'] ?? '',
        identity['lang'] ?? '',
        identity['name'] ?? '',
      ];
    }).toList()
      ..sort((a, b) {
        for (var i = 0; i < 4; i += 1) {
          final cmp = a[i].compareTo(b[i]);
          if (cmp != 0) {
            return cmp;
          }
        }
        return 0;
      });
    for (final identity in identities) {
      buffer.write(identity[0]);
      buffer.write('/');
      buffer.write(identity[1]);
      buffer.write('/');
      buffer.write(identity[2]);
      buffer.write('/');
      buffer.write(identity[3]);
      buffer.write('<');
    }
    final features = List<String>.from(SERVICE_DISCOVERY_SUPPORT_LIST)..sort();
    for (final feature in features) {
      buffer.write(feature);
      buffer.write('<');
    }
    final hash = Sha1().toSync().hashSync(utf8.encode(buffer.toString()));
    final ver = base64Encode(hash.bytes);
    _capsVer = ver;
    return ver;
  }

  void _applyClientState() {
    if (_backgroundMode) {
      _sendClientState(active: false);
      _csiIdleTimer?.cancel();
      _csiIdleTimer = null;
      return;
    }
    _sendClientState(active: true);
    _scheduleCsiIdle();
  }

  void _scheduleCsiIdle() {
    _csiIdleTimer?.cancel();
    _csiIdleTimer = Timer(_csiIdleDelay, () {
      _sendClientState(active: false);
    });
  }

  void _sendClientState({required bool active}) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    if (active == !_csiInactive) {
      return;
    }
    final nonza = Nonza();
    nonza.name = active ? 'active' : 'inactive';
    nonza.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:csi:0'));
    connection.writeNonza(nonza);
    _csiInactive = !active;
  }

  void _requestCarbons() {
    final connection = _connection;
    if (connection == null || _carbonsRequestId != null) {
      return;
    }
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    iqStanza.addAttribute(XmppAttribute('xmlns', 'jabber:client'));
    final enable = XmppElement();
    enable.name = 'enable';
    enable.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:carbons:2'));
    iqStanza.addChild(enable);
    _carbonsRequestId = id;
    connection.writeStanza(iqStanza);
  }

  void _scheduleReconnect({bool immediate = false, bool shortTimeout = false}) {
    if (!_networkOnline) {
      return;
    }
    final config = _reconnectConfig;
    if (config == null || config.password.isEmpty) {
      return;
    }
    if (isConnected || isConnecting) {
      return;
    }
    if (_reconnectTimer?.isActive == true) {
      return;
    }
    if (_tryResumeStream()) {
      return;
    }
    final backoffSeconds = immediate
        ? 0
        : (shortTimeout ? _shortReconnectBackoffSeconds() : _nextReconnectBackoffSeconds());
    if (!immediate && !shortTimeout) {
      _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 10);
    }
    _reconnectTimer = Timer(Duration(seconds: backoffSeconds), () {
      _attemptReconnect(config);
    });
  }

  int _nextReconnectBackoffSeconds() {
    return (5 * (1 << _reconnectAttempt)).clamp(5, 300);
  }

  int _shortReconnectBackoffSeconds() {
    final base = _lastPingLatency ?? Duration.zero;
    final scaled = (base * 5).inSeconds;
    return scaled >= 5 ? scaled : 5;
  }

  bool _tryResumeStream() {
    final connection = _connection;
    final streamManagement = connection?.streamManagementModule;
    if (connection == null || streamManagement == null) {
      return false;
    }
    if (!streamManagement.isResumeAvailable()) {
      return false;
    }
    if (connection.state != XmppConnectionState.ForcefullyClosed) {
      return false;
    }
    debugPrint('XMPP attempting stream resume');
    connection.reconnect();
    _status = XmppStatus.connecting;
    _errorMessage = null;
    notifyListeners();
    return true;
  }

  void _attemptReconnect(_ReconnectConfig config) {
    if (!_backgroundMode || !_networkOnline) {
      return;
    }
    if (isConnected || isConnecting) {
      return;
    }
    connect(
      jid: config.jid,
      password: config.password,
      resource: config.resource,
      host: config.host,
      port: config.port,
      useWebSocket: config.useWebSocket,
      directTls: config.directTls,
      wsEndpoint: config.wsEndpoint,
      wsProtocols: config.wsProtocols,
    );
  }

  void _requestMamBackfill(String bareJid) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final mam = connection.getMamModule();
    if (!mam.enabled) {
      return;
    }
    final normalized = _bareJid(bareJid);
    final existingMessages = _messages[normalized];
    if (existingMessages != null && existingMessages.isNotEmpty) {
      return;
    }
    final lastRequest = _mamBackfillAt[normalized];
    if (lastRequest != null && DateTime.now().difference(lastRequest).inSeconds < 30) {
      return;
    }
    _mamBackfillAt[normalized] = DateTime.now();
    mam.queryById(
      jid: Jid.fromFullJid(normalized),
      max: 50,
      before: '',
    );
  }

  void _startMamPrepend(String bareJid) {
    final normalized = _bareJid(bareJid);
    _mamPrependOffset[normalized] = 0;
    _mamPrependReset[normalized]?.cancel();
    _mamPrependReset[normalized] = Timer(const Duration(seconds: 2), () {
      _mamPrependOffset.remove(normalized);
      _mamPrependReset.remove(normalized);
    });
  }

  void _primeMamSync() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final mam = connection.getMamModule();
    if (!mam.enabled) {
      return;
    }
    final now = DateTime.now();
    if (_lastGlobalMamSyncAt != null &&
        now.difference(_lastGlobalMamSyncAt!).inSeconds < 30) {
      return;
    }
    _lastGlobalMamSyncAt = now;

    final latestGlobalMamId = _latestGlobalMamId(includeRooms: false);
    if (latestGlobalMamId != null) {
      mam.queryAll(after: latestGlobalMamId, max: 50);
      mam.queryAll(before: '', max: 50);
      _startGlobalBackfill();
    } else {
      mam.queryAll(before: '', max: 50);
    }

    for (final bookmark in _bookmarks) {
      mam.queryById(
        toJid: Jid.fromFullJid(bookmark.jid),
        max: 25,
        before: '',
      );
    }
  }

  void _startGlobalBackfill() {
    if (_globalBackfillInProgress) {
      return;
    }
    _globalBackfillInProgress = true;
    _runGlobalBackfillStep();
  }

  void _runGlobalBackfillStep() {
    final connection = _connection;
    if (connection == null) {
      _globalBackfillInProgress = false;
      return;
    }
    final mam = connection.getMamModule();
    if (!mam.enabled) {
      _globalBackfillInProgress = false;
      return;
    }
    final oldest = _oldestGlobalMamId(includeRooms: false);
    if (oldest == null) {
      _globalBackfillInProgress = false;
      return;
    }
    mam.queryAll(before: oldest, max: 50);
    _globalBackfillTimer?.cancel();
    _globalBackfillTimer = Timer(const Duration(seconds: 2), () {
      final nextOldest = _oldestGlobalMamId(includeRooms: false);
      if (nextOldest != null && nextOldest != oldest) {
        _runGlobalBackfillStep();
      } else {
        _globalBackfillInProgress = false;
      }
    });
  }

  void _seedVcardAvatars(Map<String, String> base64ByJid) {
    for (final entry in base64ByJid.entries) {
      if (entry.value.trim().isEmpty) {
        continue;
      }
      try {
        _vcardAvatarBytes[entry.key] = base64Decode(entry.value);
      } catch (_) {
        // Ignore invalid cached data.
      }
    }
  }

  void _seedVcardAvatarState(Map<String, String> stateByJid) {
    _vcardAvatarState
      ..clear()
      ..addAll(stateByJid);
  }

  void _requestVcardAvatar(String bareJid) {
    final connection = _connection;
    final storage = _storage;
    if (connection == null || storage == null) {
      return;
    }
    if (_vcardRequests.contains(bareJid)) {
      return;
    }
    _vcardRequests.add(bareJid);
    final manager = VCardManager.getInstance(connection);
    manager.getVCardFor(Jid.fromFullJid(bareJid)).then((vcard) {
      final bytes = vcard.imageData;
      if (bytes is List<int> && bytes.isNotEmpty) {
        final data = base64Encode(bytes);
        _vcardAvatarBytes[bareJid] = Uint8List.fromList(bytes);
        storage.storeVcardAvatar(bareJid, data);
        if (!_vcardAvatarState.containsKey(bareJid)) {
          _vcardAvatarState[bareJid] = _vcardUnknown;
          storage.storeVcardAvatarState(bareJid, _vcardUnknown);
        }
        notifyListeners();
      } else {
        _vcardAvatarBytes.remove(bareJid);
        _vcardAvatarState[bareJid] = _vcardNoAvatar;
        storage.storeVcardAvatarState(bareJid, _vcardNoAvatar);
        storage.removeVcardAvatar(bareJid);
        notifyListeners();
      }
    }).catchError((_) {
      // Ignore errors for missing vCards.
    });
  }

  void _handleVcardPresenceUpdate(PresenceStanza stanza) {
    final bareJid = _vcardJidFromPresence(stanza);
    final storage = _storage;
    if (bareJid == null || bareJid.isEmpty || storage == null) {
      return;
    }
    final update = stanza.children.firstWhere(
      (child) =>
          child.name == 'x' &&
          child.getAttribute('xmlns')?.value == 'vcard-temp:x:update',
      orElse: () => XmppElement(),
    );
    if (update.name != 'x') {
      return;
    }
    final photo = update.getChild('photo');
    final hash = photo?.textValue?.trim() ?? '';
    final existing = _vcardAvatarState[bareJid];
    if (hash.isEmpty) {
      if (existing != _vcardNoAvatar) {
        _vcardAvatarState[bareJid] = _vcardNoAvatar;
        _vcardAvatarBytes.remove(bareJid);
        _vcardRequests.remove(bareJid);
        storage.storeVcardAvatarState(bareJid, _vcardNoAvatar);
        storage.removeVcardAvatar(bareJid);
        notifyListeners();
      }
      return;
    }
    if (existing == hash && _vcardAvatarBytes.containsKey(bareJid)) {
      return;
    }
    _vcardAvatarState[bareJid] = hash;
    storage.storeVcardAvatarState(bareJid, hash);
    _vcardRequests.remove(bareJid);
    _requestVcardAvatar(bareJid);
  }

  String? _vcardJidFromPresence(PresenceStanza stanza) {
    final from = stanza.fromJid;
    if (from == null) {
      return null;
    }
    XmppElement? mucUser;
    for (final child in stanza.children) {
      if (child.name == 'x' &&
          child.getAttribute('xmlns')?.value == 'http://jabber.org/protocol/muc#user') {
        mucUser = child;
        break;
      }
    }
    if (mucUser != null) {
      final realJid = mucUser.getChild('item')?.getAttribute('jid')?.value;
      if (realJid == null || realJid.isEmpty) {
        return null;
      }
      return Jid.fromFullJid(realJid).userAtDomain;
    }
    return from.userAtDomain;
  }

  void _sendPing({bool shortTimeout = false}) {
    final connection = _connection;
    if (connection == null || _currentUserBareJid == null) {
      return;
    }
    if (_pendingPings.isNotEmpty) {
      return;
    }
    final domain = _domainFromBareJid(_currentUserBareJid!);
    if (domain.isEmpty) {
      return;
    }
    final id = AbstractStanza.getRandomId();
    final stanza = IqStanza(id, IqStanzaType.GET);
    stanza.toJid = Jid.fromFullJid(domain);
    final ping = XmppElement()..name = 'ping';
    ping.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:ping'));
    stanza.addChild(ping);
    _pendingPings[id] = DateTime.now();
    connection.writeStanza(stanza);
    _schedulePingTimeout(id, shortTimeout: shortTimeout);
  }

  void _sendSmAckRequest({bool force = false, bool shortTimeout = false}) {
    final connection = _connection;
    if (connection == null || !_isStreamManagementEnabled()) {
      return;
    }
    if (!force && _lastSmAckRequestAt != null) {
      final elapsed = DateTime.now().difference(_lastSmAckRequestAt!);
      if (elapsed < _currentSmAckInterval) {
        return;
      }
    }
    if (_pendingSmAckAt != null) {
      if (shortTimeout) {
        _scheduleSmAckTimeout(shortTimeout: true);
      } else {
        _expireSmAck();
      }
      return;
    }
    _pendingSmAckAt = DateTime.now();
    _lastSmAckRequestAt = _pendingSmAckAt;
    connection.streamManagementModule?.sendAckRequest();
    _scheduleSmAckTimeout(shortTimeout: shortTimeout);
  }

  void _expireSmAck() {
    final startedAt = _pendingSmAckAt;
    if (startedAt == null) {
      return;
    }
    final timeout = _smAckTimeout(shortTimeout: false);
    if (DateTime.now().difference(startedAt) > timeout) {
      _handleSmAckTimeout(shortTimeout: false);
    }
  }

  bool _isStreamManagementEnabled() {
    return _connection?.streamManagementModule?.streamState.streamManagementEnabled == true;
  }

  void _scheduleSmAckTimeout({required bool shortTimeout}) {
    _smAckTimeoutTimer?.cancel();
    final timeout = _smAckTimeout(shortTimeout: shortTimeout);
    _smAckTimeoutTimer = Timer(timeout, () => _handleSmAckTimeout(shortTimeout: shortTimeout));
  }

  void _handleSmAckTimeout({required bool shortTimeout}) {
    if (_pendingSmAckAt == null) {
      return;
    }
    _pendingSmAckAt = null;
    _smAckTimeoutTimer?.cancel();
    _smAckTimeoutTimer = null;
    _lastPingLatency = null;
    _lastPingAt = DateTime.now();
    notifyListeners();
    if (_pendingPings.isEmpty) {
      _sendPing(shortTimeout: shortTimeout);
      return;
    }
    _scheduleReconnect(immediate: true, shortTimeout: shortTimeout);
  }

  void _schedulePingTimeout(String id, {required bool shortTimeout}) {
    _pingTimeoutTimers[id]?.cancel();
    final timeout = _pingTimeout(shortTimeout: shortTimeout);
    _pingTimeoutShort[id] = shortTimeout;
    _pingTimeoutTimers[id] = Timer(timeout, () {
      final startedAt = _pendingPings.remove(id);
      final timer = _pingTimeoutTimers.remove(id);
      timer?.cancel();
      final wasShort = _pingTimeoutShort.remove(id) ?? false;
      if (startedAt == null) {
        return;
      }
      _handlePingTimeout(shortTimeout: wasShort);
    });
  }

  void _handlePingTimeout({required bool shortTimeout}) {
    _lastPingLatency = null;
    _lastPingAt = DateTime.now();
    notifyListeners();
    _scheduleReconnect(immediate: true, shortTimeout: shortTimeout);
  }


  Duration _smAckTimeout({required bool shortTimeout}) {
    final base = _lastPingLatency ?? Duration.zero;
    final multiplier = shortTimeout ? 5 : 10;
    final scaled = base * multiplier;
    final floor = Duration(seconds: shortTimeout ? 5 : 10);
    return scaled > floor ? scaled : floor;
  }

  Duration _pingTimeout({required bool shortTimeout}) {
    final base = _lastPingLatency ?? Duration.zero;
    final multiplier = shortTimeout ? 5 : 10;
    final scaled = base * multiplier;
    final floor = Duration(seconds: shortTimeout ? 5 : 10);
    return scaled > floor ? scaled : floor;
  }

  void _probeConnection({required bool shortTimeout}) {
    if (!isConnected) {
      return;
    }
    if (_isStreamManagementEnabled()) {
      _sendSmAckRequest(force: true, shortTimeout: shortTimeout);
      return;
    }
    _sendPing(shortTimeout: shortTimeout);
  }
}
