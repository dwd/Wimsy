import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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
  final Map<String, DateTime> _pendingPings = {};
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
  PresenceData _selfPresence = PresenceData(PresenceShowElement.CHAT, 'Online', null);
  Duration? _lastPingLatency;
  DateTime? _lastPingAt;
  bool _carbonsEnabled = false;
  final Map<String, DateTime> _mamBackfillAt = {};
  final Map<String, DateTime> _mamPageRequestAt = {};
  DateTime? _lastGlobalMamSyncAt;
  bool _globalBackfillInProgress = false;
  Timer? _globalBackfillTimer;
  StorageService? _storage;
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
  }

  List<ChatMessage> messagesFor(String bareJid) {
    return List.unmodifiable(_messages[bareJid] ?? const []);
  }

  List<ChatMessage> roomMessagesFor(String roomJid) {
    return List.unmodifiable(_roomMessages[_bareJid(roomJid)] ?? const []);
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
    if (_backgroundMode && !isConnected && !isConnecting) {
      _scheduleReconnect();
    }
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
          _primeMamSync();
          _sendInitialPresence();
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
    _rooms.clear();
    _roomOccupants.clear();
    _presenceByBareJid.clear();
    _lastSeenAt.clear();
    _serverNotFound.clear();
    _chatStates.clear();
    _pepManager?.clearCache();
    _bookmarksManager?.clearCache();
    _vcardAvatarBytes.clear();
    _vcardAvatarState.clear();
    _messagePersistor?.call('', const []);
    _rosterPersistor?.call(const []);
    _bookmarkPersistor?.call(const []);
    notifyListeners();
  }

  void selectChat(String? bareJid) {
    _activeChatBareJid = bareJid;
    if (bareJid != null && !isBookmark(bareJid)) {
      setMyChatState(bareJid, ChatState.ACTIVE);
      _requestMamBackfill(bareJid);
      _sendDisplayedForChat(bareJid);
    }
    if (bareJid != null && isBookmark(bareJid)) {
      _ensureRoom(_bareJid(bareJid));
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
      mam.queryById(
        toJid: Jid.fromFullJid(normalized),
        max: 25,
        before: oldest,
      );
      return;
    }
    final oldest = oldestMamIdFor(normalized);
    if (oldest == null || oldest.isEmpty) {
      _requestMamBackfill(normalized);
      return;
    }
    mam.queryById(
      jid: Jid.fromFullJid(normalized),
      max: 50,
      before: oldest,
    );
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
      _ensureContact(bareJid);
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
    final nick = _roomNickFor(normalized);
    _addRoomMessage(
      roomJid: normalized,
      from: nick,
      body: trimmed,
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
          if (_shouldSubscribePep(jid)) {
            _pepManager?.subscribeToAvatarMetadata(jid);
          }
          _pepManager?.requestMetadataIfMissing(jid);
        }
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
      if (stanza is MessageStanza && stanza.type == MessageStanzaType.CHAT) {
        final id = stanza.id;
        if (id != null && id.isNotEmpty) {
          _applyAckByMessageId(id);
        }
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
        outgoing: false,
        timestamp: message.timestamp,
        messageId: message.stanzaId,
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
    if (body.trim().isEmpty) {
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
    if (_shouldSubscribePep(_currentUserBareJid!)) {
      _pepManager?.subscribeToAvatarMetadata(_currentUserBareJid!);
    }
    _pepManager?.requestMetadataIfMissing(_currentUserBareJid!);
    for (final contact in _contacts) {
      if (_shouldSubscribePep(contact.jid)) {
        _pepManager?.subscribeToAvatarMetadata(contact.jid);
      }
      _pepManager?.requestMetadataIfMissing(contact.jid);
    }
    _pepSubscription?.cancel();
    _pepSubscription = connection.inStanzasStream.listen((stanza) {
      if (stanza == null) {
        return;
      }
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
    _bookmarksManager?.requestBookmarks();
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
          _expireOldPing();
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
        if (body.trim().isEmpty) {
          continue;
        }
        final outgoing = from == (_currentUserBareJid ?? '');
        _addMessage(
          bareJid: outgoing ? to : from,
          from: from,
          to: to,
          body: body,
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
      if (body.trim().isEmpty) {
        return;
      }
      final outgoing = from == (_currentUserBareJid ?? '');
      _addMessage(
        bareJid: outgoing ? to : from,
        from: from,
        to: to,
        body: body,
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
    required bool outgoing,
    required DateTime timestamp,
    String? messageId,
    String? mamId,
    String? stanzaId,
  }) {
    final normalized = _bareJid(bareJid);
    _ensureContact(normalized);

    final list = _messages.putIfAbsent(normalized, () => <ChatMessage>[]);
    if (messageId != null && messageId.isNotEmpty) {
      final existingIndex = list.indexWhere((message) => message.messageId == messageId);
      if (existingIndex != -1) {
        final existing = list[existingIndex];
        final nextMamId = (mamId != null && mamId.isNotEmpty) ? mamId : existing.mamId;
        final nextStanzaId =
            (stanzaId != null && stanzaId.isNotEmpty) ? stanzaId : existing.stanzaId;
        if (nextMamId != existing.mamId || nextStanzaId != existing.stanzaId) {
          list[existingIndex] = ChatMessage(
            from: existing.from,
            to: existing.to,
            body: existing.body,
            outgoing: existing.outgoing,
            timestamp: existing.timestamp,
            messageId: existing.messageId,
            mamId: nextMamId,
            stanzaId: nextStanzaId,
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
    if (stanzaId != null && stanzaId.isNotEmpty && list.any((message) => message.stanzaId == stanzaId)) {
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
    final newMessage = ChatMessage(
      from: from,
      to: to,
      body: body,
      outgoing: outgoing,
      timestamp: timestamp,
      messageId: messageId,
      mamId: mamId,
      stanzaId: stanzaId,
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
    required bool outgoing,
    required DateTime timestamp,
    String? messageId,
    String? mamId,
    String? stanzaId,
  }) {
    final normalized = _bareJid(roomJid);
    final list = _roomMessages.putIfAbsent(normalized, () => <ChatMessage>[]);
    if (messageId != null && messageId.isNotEmpty) {
      final existingIndex = list.indexWhere((message) => message.messageId == messageId);
      if (existingIndex != -1) {
        final existing = list[existingIndex];
        final nextMamId = (mamId != null && mamId.isNotEmpty) ? mamId : existing.mamId;
        final nextStanzaId =
            (stanzaId != null && stanzaId.isNotEmpty) ? stanzaId : existing.stanzaId;
        if (nextMamId != existing.mamId || nextStanzaId != existing.stanzaId) {
          list[existingIndex] = ChatMessage(
            from: existing.from,
            to: existing.to,
            body: existing.body,
            outgoing: existing.outgoing,
            timestamp: existing.timestamp,
            messageId: existing.messageId,
            mamId: nextMamId,
            stanzaId: nextStanzaId,
            acked: existing.acked,
            receiptReceived: existing.receiptReceived,
            displayed: existing.displayed,
          );
          notifyListeners();
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
    final newMessage = ChatMessage(
      from: from,
      to: normalized,
      body: body,
      outgoing: outgoing,
      timestamp: timestamp,
      messageId: messageId,
      mamId: mamId,
      stanzaId: stanzaId,
    );
    _insertMessageOrdered(list, newMessage);
    notifyListeners();
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
    final first = list.first;
    if (message.timestamp.isBefore(first.timestamp)) {
      list.insert(0, message);
      return;
    }
    // Keep MAM order intact by appending when not strictly older than the first entry.
    if (!message.timestamp.isBefore(list.last.timestamp)) {
      list.add(message);
      return;
    }
    list.add(message);
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

  bool _mergeMamIdsIntoExisting(
    List<ChatMessage> list, {
    required String from,
    required String to,
    required String body,
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
        list[i] = ChatMessage(
          from: existing.from,
          to: existing.to,
          body: existing.body,
          outgoing: existing.outgoing,
          timestamp: existing.timestamp,
          messageId: existing.messageId,
          mamId: (mamId != null && mamId.isNotEmpty) ? mamId : existing.mamId,
          stanzaId: (stanzaId != null && stanzaId.isNotEmpty) ? stanzaId : existing.stanzaId,
          acked: existing.acked,
          receiptReceived: existing.receiptReceived,
          displayed: existing.displayed,
        );
        return true;
      }
      if (existing.body != body ||
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
      if (_shouldSubscribePep(entry.jid)) {
        _pepManager?.subscribeToAvatarMetadata(entry.jid);
      }
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

  bool _shouldSubscribePep(String bareJid) {
    final normalized = _bareJid(bareJid);
    final contact = _contacts.firstWhere(
      (entry) => entry.jid == normalized,
      orElse: () => ContactEntry(jid: ''),
    );
    if (contact.jid.isEmpty) {
      return true;
    }
    return contact.subscriptionType != 'both';
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
    }
    _presenceByBareJid.clear();
    _roomMessages.clear();
    _rooms.clear();
    _roomOccupants.clear();
    _lastSeenAt.clear();
    _serverNotFound.clear();
    _chatStates.clear();
    _lastDisplayedMarkerIdByChat.clear();
    _lastPingLatency = null;
    _lastPingAt = null;
    _carbonsEnabled = false;
    _carbonsRequestId = null;
    _mamBackfillAt.clear();
    _mamPageRequestAt.clear();
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
    final presenceManager = PresenceManager.getInstance(connection);
    presenceManager.sendPresence(presence);
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

  void _scheduleReconnect() {
    if (!_backgroundMode || !_networkOnline) {
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
    final backoffSeconds = (5 * (1 << _reconnectAttempt)).clamp(5, 300);
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 10);
    _reconnectTimer = Timer(Duration(seconds: backoffSeconds), () {
      _attemptReconnect(config);
    });
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

  void _sendPing() {
    final connection = _connection;
    if (connection == null || _currentUserBareJid == null) {
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
  }

  void _sendSmAckRequest({bool force = false}) {
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
      _expireSmAck();
      if (_pendingSmAckAt != null) {
        return;
      }
    }
    _pendingSmAckAt = DateTime.now();
    _lastSmAckRequestAt = _pendingSmAckAt;
    connection.streamManagementModule?.sendAckRequest();
  }

  void _expireSmAck() {
    final startedAt = _pendingSmAckAt;
    if (startedAt == null) {
      return;
    }
    if (DateTime.now().difference(startedAt).inSeconds > 10) {
      _pendingSmAckAt = null;
      _lastPingLatency = null;
      _lastPingAt = DateTime.now();
      notifyListeners();
    }
  }

  bool _isStreamManagementEnabled() {
    return _connection?.streamManagementModule?.streamState.streamManagementEnabled == true;
  }

  void _expireOldPing() {
    final now = DateTime.now();
    final expired = _pendingPings.entries
        .where((entry) => now.difference(entry.value).inSeconds > 10)
        .map((entry) => entry.key)
        .toList();
    for (final id in expired) {
      _pendingPings.remove(id);
    }
    if (expired.isNotEmpty) {
      _lastPingLatency = null;
      _lastPingAt = now;
      notifyListeners();
    }
  }
}
