import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:xmpp_stone/xmpp_stone.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import '../models/chat_message.dart';
import '../models/contact_entry.dart';
import '../models/room_entry.dart';
import '../bookmarks/bookmarks_manager.dart';
import '../pep/pep_manager.dart';
import '../pep/pep_caps_manager.dart';
import '../storage/storage_service.dart';
import '../av/call_session.dart';
import '../av/call_quality.dart';
import '../av/media_session.dart';
import '../av/muji_session.dart';
import '../av/sdp_mapper.dart';
import 'extdisco.dart';
import 'jmi.dart';
import 'blocking.dart';
import 'http_upload.dart';
import 'muc_invite.dart';
import 'muc_self_ping.dart';
import 'muc_config.dart';
import 'vcard_utils.dart';
import 'ws_endpoint.dart';
import 'srv_lookup.dart';
import 'alt_connection.dart';

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
  StreamSubscription<AbstractStanza?>? _mucPresenceSubscription;
  Timer? _pingTimer;
  Timer? _smAckTimeoutTimer;
  Timer? _csiIdleTimer;
  Timer? _mucSelfPingTimer;
  final Map<String, String> _pendingMucSelfPings = {};
  final Map<String, Timer> _mucSelfPingTimeouts = {};
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
  static const Duration _mucSelfPingIdle = Duration(minutes: 10);
  static const Duration _mucSelfPingCheckInterval = Duration(minutes: 1);
  static const Duration _mucSelfPingTimeout = Duration(seconds: 30);
  static const Duration _keepaliveMaxTimeout = Duration(seconds: 30);
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
  final Map<String, MujiSessionState> _mujiSessions = {};
  final Map<String, StreamSubscription> _roomSubscriptions = {};
  final Map<String, PresenceData> _presenceByBareJid = {};
  final Map<String, PresenceData> _presenceByFullJid = {};
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
  static const String _jingleNamespace = 'urn:xmpp:jingle:1';
  static const String _jingleRtpNamespace = 'urn:xmpp:jingle:apps:rtp:1';
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
  final Map<String, DateTime> _roomLastTrafficAt = {};
  final Map<String, DateTime> _roomLastPingAt = {};
  final Set<String> _mucDefaultConfigSent = {};
  PepManager? _pepManager;
  PepCapsManager? _pepCapsManager;
  BookmarksManager? _bookmarksManager;
  PrivacyListsManager? _privacyListsManager;
  JingleManager? _jingleManager;
  IbbManager? _ibbManager;
  String? _httpUploadServiceJid;
  bool _pepVcardConversionSupported = false;
  String _lastSelfAvatarHash = '';
  bool _blockingSupported = false;
  bool _blockingHandlerRegistered = false;
  final Set<String> _blockedJids = {};
  static const String _blockListName = 'wimsy-blocked';
  MucManager? _mucManager;
  final Map<String, Uint8List> _vcardAvatarBytes = {};
  final Map<String, String> _vcardAvatarState = {};
  final Set<String> _vcardRequests = {};
  final Set<String> _vcardUnavailable = {};
  static const _vcardNoAvatar = 'none';
  String _selfVcardPhotoHash = '';
  bool _selfVcardPhotoKnown = false;
  final Map<String, _FileTransferSession> _fileTransfers = {};
  final Map<String, CallSession> _callSessions = {};
  final Map<String, String> _callSessionByPeerKey = {};
  final Map<String, Map<String, JingleRtpDescription>> _callLocalDescriptionsBySid = {};
  final Map<String, Map<String, JingleRtpDescription>> _callRemoteDescriptionsBySid = {};
  final WebRtcMediaSession _mediaSession = WebRtcMediaSession();
  final Map<String, RTCPeerConnection> _callPeerConnections = {};
  final Map<String, CallMediaKind> _callMediaKindBySid = {};
  final Map<String, MediaStream> _callLocalStreamBySid = {};
  final Map<String, MediaStream> _callRemoteStreamBySid = {};
  final Map<String, Map<String, JingleIceTransport>> _callLocalTransportsBySid = {};
  final Map<String, Map<String, JingleIceTransport>> _callRemoteTransportsBySid = {};
  final Map<String, List<String>> _callContentNamesBySid = {};
  final Map<String, bool> _callMutedBySid = {};
  final Map<String, bool> _callVideoEnabledBySid = {};
  final Map<String, bool> _callLocalSpeakingBySid = {};
  final Map<String, bool> _callRemoteSpeakingBySid = {};
  final Set<String> _callAcceptedBySid = {};
  final Set<String> _callLoggedIceQueueBySid = {};
  final Map<String, String> _callSelectedCandidateSummaryBySid = {};
  final Map<String, String> _callPeerFullJidBySid = {};
  ISentrySpan? _connectTransaction;
  ISentrySpan? _connectAwaitSpan;
  ISentrySpan? _rosterSpan;
  ISentrySpan? _bookmarksSpan;
  ISentrySpan? _mamSyncTransaction;
  final Map<String, ISentrySpan> _mucJoinTransactions = {};
  final Map<String, ISentrySpan> _jingleSetupTransactions = {};
  final Map<String, ISentrySpan> _fileTransferTransactions = {};
  final Map<String, String> _fileTransferStateBySid = {};
  final Map<String, Timer> _callTimeoutTimers = {};
  final Map<String, Timer> _callStatsTimers = {};
  final Map<String, CallQualitySample> _callQualityBySid = {};
  final Map<String, _CallStatsTracker> _callStatsBySid = {};
  final CallQualityController _callQualityController = const CallQualityController();
  final Map<String, Timer> _jmiFallbackTimers = {};
  final Map<String, Jid> _jmiProceedTargetBySid = {};
  final Set<String> _jmiIncomingPending = {};
  final Set<String> _jmiAutoAcceptBySid = {};
  final Map<String, Set<String>> _jmiProposedMediaBySid = {};
  final Map<String, List<RTCIceCandidate>> _pendingIceCandidatesBySid = {};
  final Map<String, String> _jingleInitiatedTargets = {};
  List<Map<String, dynamic>> _iceServers = const [];
  bool _speakerphoneOn = false;
  String? _preferredAudioInputId;
  String? _preferredVideoInputId;
  StreamSubscription<JingleSessionEvent>? _jingleSubscription;
  StreamSubscription<IbbOpen>? _ibbOpenSubscription;
  StreamSubscription<IbbData>? _ibbDataSubscription;
  StreamSubscription<IbbClose>? _ibbCloseSubscription;

  static const int _ibbDefaultBlockSize = 4096;
  static const Duration _outgoingCallTimeout = Duration(seconds: 45);
  static const Duration _incomingCallTimeout = Duration(seconds: 60);
  static const Duration _callStatsInterval = Duration(seconds: 5);
  static const String _fileTransferStateOffered = 'offered';
  static const String _fileTransferStateAccepted = 'accepted';
  static const String _fileTransferStateInProgress = 'in_progress';
  static const String _fileTransferStateCompleted = 'completed';
  static const String _fileTransferStateFailed = 'failed';
  static const String _fileTransferStateDeclined = 'declined';

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
  CallSession? callSessionFor(String bareJid) {
    final key = _callSessionByPeerKey[_callPeerKeyForJid(bareJid)];
    if (key == null) {
      return null;
    }
    return _callSessions[key];
  }

  MediaStream? callLocalStreamFor(String bareJid) {
    final key = _callSessionByPeerKey[_callPeerKeyForJid(bareJid)];
    if (key == null) {
      return null;
    }
    return _callLocalStreamBySid[key];
  }

  MediaStream? callRemoteStreamFor(String bareJid) {
    final key = _callSessionByPeerKey[_callPeerKeyForJid(bareJid)];
    if (key == null) {
      return null;
    }
    return _callRemoteStreamBySid[key];
  }

  CallQualitySample? callQualityFor(String bareJid) {
    final key = _callSessionByPeerKey[_callPeerKeyForJid(bareJid)];
    if (key == null) {
      return null;
    }
    return _callQualityBySid[key];
  }

  bool isCallMuted(String bareJid) {
    final key = _callSessionByPeerKey[_callPeerKeyForJid(bareJid)];
    if (key == null) {
      return false;
    }
    return _callMutedBySid[key] ?? false;
  }

  bool isCallVideoEnabled(String bareJid) {
    final key = _callSessionByPeerKey[_callPeerKeyForJid(bareJid)];
    if (key == null) {
      return true;
    }
    return _callVideoEnabledBySid[key] ?? true;
  }

  bool isCallLocalSpeaking(String bareJid) {
    final key = _callSessionByPeerKey[_callPeerKeyForJid(bareJid)];
    if (key == null) {
      return false;
    }
    return _callLocalSpeakingBySid[key] ?? false;
  }

  bool isCallRemoteSpeaking(String bareJid) {
    final key = _callSessionByPeerKey[_callPeerKeyForJid(bareJid)];
    if (key == null) {
      return false;
    }
    return _callRemoteSpeakingBySid[key] ?? false;
  }

  bool get isSpeakerphoneOn => _speakerphoneOn;

  MujiSessionState? mujiSessionFor(String roomJid) {
    return _mujiSessions[_bareJid(roomJid)];
  }

  Future<List<MediaDeviceInfo>> listAudioOutputs() async {
    return Helper.audiooutputs;
  }

  Future<List<MediaDeviceInfo>> listAudioInputs() async {
    final devices = await navigator.mediaDevices.enumerateDevices();
    return devices
        .where((device) => device.kind == 'audioinput' || device.kind == 'audio')
        .toList();
  }

  Future<List<MediaDeviceInfo>> listVideoInputs() async {
    final devices = await navigator.mediaDevices.enumerateDevices();
    return devices
        .where((device) => device.kind == 'videoinput' || device.kind == 'video')
        .toList();
  }

  Future<void> selectAudioOutput(String deviceId) async {
    if (deviceId.isEmpty) {
      return;
    }
    await Helper.selectAudioOutput(deviceId);
  }

  void selectAudioInput(String deviceId) {
    final trimmed = deviceId.trim();
    _preferredAudioInputId = trimmed.isEmpty ? null : trimmed;
  }

  void selectVideoInput(String deviceId) {
    final trimmed = deviceId.trim();
    _preferredVideoInputId = trimmed.isEmpty ? null : trimmed;
  }

  String? get preferredAudioInputId => _preferredAudioInputId;
  String? get preferredVideoInputId => _preferredVideoInputId;

  Future<void> toggleSpeakerphone() async {
    _speakerphoneOn = !_speakerphoneOn;
    await Helper.setSpeakerphoneOn(_speakerphoneOn);
    notifyListeners();
  }

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

  bool contactSupportsJingle(String bareJid) {
    final features = _pepCapsManager?.featuresForBareJid(_bareJid(bareJid));
    if (features == null || features.isEmpty) {
      return true;
    }
    return features.contains(_jingleNamespace) ||
        features.contains(jmiNamespace) ||
        features.contains(_jingleRtpNamespace);
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

    _finishSpan(_connectTransaction);
    _connectTransaction = _startTransaction(
      name: 'xmpp.connect',
      operation: 'xmpp.connect',
      tags: {
        'xmpp.domain': _domainFromBareJid(bareJid),
        'xmpp.transport': shouldUseWebSocket ? 'websocket' : 'tcp',
        'xmpp.direct_tls': resolvedDirectTls.toString(),
      },
    );

    if (!kIsWeb && resolvedHost.isEmpty) {
      final domain = _domainFromBareJid(bareJid);
      final srvSpan = _startSpan(
        _connectTransaction,
        'xmpp.srv_lookup',
        description: domain,
      );
      final srvTarget = await resolveXmppSrv(domain);
      _finishSpan(srvSpan);
      if (srvTarget != null) {
        resolvedHost = srvTarget.host;
        resolvedPort = srvTarget.port;
        resolvedDirectTls = srvTarget.directTls;
      } else if (resolvedPort == 0 || resolvedPort == 5222) {
        resolvedPort = directTls ? 5223 : 5222;
      }
    }

    if (shouldUseWebSocket && wsConfig == null) {
      final domain = _domainFromBareJid(bareJid);
      final wsSpan = _startSpan(
        _connectTransaction,
        'xmpp.ws_discovery',
        description: domain,
      );
      final discovered = await discoverWebSocketEndpoint(domain);
      _finishSpan(wsSpan);
      if (discovered != null) {
        wsConfig = parseWsEndpoint(discovered.toString());
      }
      if (wsConfig == null) {
        _setError('Enter a WebSocket endpoint like wss://host/path.');
        return;
      }
    }

    await _safeClose(preserveCache: true);

    _status = XmppStatus.connecting;
    _errorMessage = null;
    _currentUserBareJid = bareJid;
    _primeSelfVcardHash();
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
          _setupJingle();
          _setupIbb();
          return;
        }
        if (state == XmppConnectionState.Ready) {
          _reconnectAttempt = 0;
          _reconnectTimer?.cancel();
          if (!completer.isCompleted) {
            completer.complete();
          }
          _finishSpan(_connectAwaitSpan);
          _connectAwaitSpan = null;
          _finishSpan(_connectTransaction);
          _connectTransaction = null;
          _status = XmppStatus.connected;
          _errorMessage = null;
          notifyListeners();
          _pepVcardConversionSupported = connection.getSupportedFeatures().any(
            (feature) => feature.xmppVar == 'urn:xmpp:pep-vcard-conversion:0',
          );
          _blockingSupported = connection.getSupportedFeatures().any(
            (feature) => feature.xmppVar == blockingNamespace,
          );
          _setupRoster();
          _setupChatManager();
          _setupMuc();
          _setupMessageSignals();
          _setupJingle();
          _setupIbb();
          _setupPresence();
          _setupKeepalive();
          _setupDeliveryTracking();
          _setupPep();
          _setupBookmarks();
          _setupBlocking();
          _setupDisplayedSync();
          _refreshExternalServices();
          _primeMamSync();
          _requestVcardDetails(_currentUserBareJid!, preferName: true);
          _sendInitialPresence();
          _applyClientState();
        } else if (_isTerminalError(state)) {
          final message = _connectionErrorMessage(state);
          debugPrint('XMPP error: $message');
          if (!completer.isCompleted) {
            completer.completeError(message);
          }
          _finishSpan(_connectAwaitSpan, status: const SpanStatus.internalError());
          _connectAwaitSpan = null;
          _finishSpan(_connectTransaction, status: const SpanStatus.internalError());
          _connectTransaction = null;
          _setError(message);
          _scheduleReconnect();
        } else if (_status == XmppStatus.connecting) {
          notifyListeners();
        }
      });

      _connectAwaitSpan = _startSpan(
        _connectTransaction,
        'xmpp.connect.await_ready',
      );
      connection.connect();

      await completer.future.timeout(const Duration(seconds: 20));
    } catch (error) {
      _finishSpan(_connectAwaitSpan, status: const SpanStatus.deadlineExceeded());
      _connectAwaitSpan = null;
      _finishSpan(_connectTransaction, status: const SpanStatus.internalError());
      _connectTransaction = null;
      await _safeClose(preserveCache: true);
      if (_status != XmppStatus.error) {
        _setError('Connection failed: $error');
      }
      _scheduleReconnect();
    }
  }

  Future<void> disconnect() async {
    await _safeClose(preserveCache: true);
    _finishSpan(_connectAwaitSpan, status: const SpanStatus.cancelled());
    _connectAwaitSpan = null;
    _finishSpan(_connectTransaction, status: const SpanStatus.cancelled());
    _connectTransaction = null;
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
    _mucDefaultConfigSent.clear();
    _mujiSessions.clear();
    _mujiSessions.clear();
    _presenceByBareJid.clear();
    _presenceByFullJid.clear();
    _lastSeenAt.clear();
    _serverNotFound.clear();
    _chatStates.clear();
    _rosterVersion = null;
    _pepManager?.clearCache();
    _bookmarksManager?.clearCache();
    _vcardAvatarBytes.clear();
    _vcardAvatarState.clear();
    _vcardRequests.clear();
    _vcardUnavailable.clear();
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

  void editMessage({
    required String toBareJid,
    required String replaceId,
    required String text,
  }) {
    final connection = _connection;
    if (connection == null) {
      _setError('Not connected.');
      return;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty || replaceId.isEmpty) {
      return;
    }
    final stanza = MessageStanza(AbstractStanza.getRandomId(), MessageStanzaType.CHAT);
    stanza.toJid = Jid.fromFullJid(toBareJid);
    stanza.fromJid = connection.fullJid;
    stanza.body = trimmed;
    stanza.addChild(_buildReplaceElement(replaceId));
    final receiptRequest = XmppElement()..name = 'request';
    receiptRequest.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:receipts'));
    stanza.addChild(receiptRequest);
    final markable = XmppElement()..name = 'markable';
    markable.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:chat-markers:0'));
    stanza.addChild(markable);
    connection.writeStanza(stanza);
    final sender = _currentUserBareJid ?? connection.fullJid.userAtDomain;
    if (sender.isNotEmpty) {
      _applyMessageCorrection(
        bareJid: toBareJid,
        sender: sender,
        replaceId: replaceId,
        newBody: trimmed,
        oobUrl: null,
        rawXml: _serializeStanza(stanza),
        timestamp: DateTime.now(),
      );
    }
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
    _requestVcardDetails(normalized, preferName: name == null || name.trim().isEmpty);
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
    if (_blockingSupported) {
      final success = await _sendBlock(normalized);
      if (success) {
        _blockedJids.add(normalized);
        notifyListeners();
      }
      return success;
    }
    _blockedJids.add(normalized);
    return _applyBlockList();
  }

  Future<bool> unblockContact(String bareJid) async {
    final normalized = _bareJid(bareJid);
    if (normalized.isEmpty) {
      return false;
    }
    if (_blockingSupported) {
      final success = await _sendUnblock(normalized);
      if (success) {
        _blockedJids.remove(normalized);
        notifyListeners();
      }
      return success;
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
    final mucSpan =
        _startLinkedTransaction('xmpp.muc.join', 'xmpp.muc', _connectTransaction);
    if (mucSpan != null) {
      mucSpan.setTag('xmpp.room', normalized);
      _mucJoinTransactions[normalized] = mucSpan;
    }
    muc.joinRoom(Jid.fromFullJid(normalized), resolvedNick, password: resolvedPassword);
    final existing = _rooms[normalized] ?? RoomEntry(roomJid: normalized);
    _rooms[normalized] = existing.copyWith(joined: true, nick: resolvedNick);
    notifyListeners();
    _requestRoomMam(normalized, before: '');
    _roomLastTrafficAt[normalized] = DateTime.now();
    _roomLastPingAt.remove(normalized);
    _sendDirectedPresenceToRoom(normalized, resolvedNick);
  }

  void joinMujiRoom(String roomJid, {String? nick, String? password}) {
    joinRoom(roomJid, nick: nick, password: password);
    final normalized = _bareJid(roomJid);
    _mujiSessions.putIfAbsent(normalized, () => MujiSessionState());
    notifyListeners();
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

  void leaveMujiRoom(String roomJid) {
    leaveRoom(roomJid);
    _mujiSessions.remove(_bareJid(roomJid));
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

  void editRoomMessage({
    required String roomJid,
    required String replaceId,
    required String text,
  }) {
    final connection = _connection;
    if (connection == null) {
      _setError('Not connected.');
      return;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty || replaceId.isEmpty) {
      return;
    }
    final normalized = _bareJid(roomJid);
    final stanza = MessageStanza(AbstractStanza.getRandomId(), MessageStanzaType.GROUPCHAT);
    stanza.toJid = Jid.fromFullJid(normalized);
    stanza.body = trimmed;
    stanza.addChild(_buildReplaceElement(replaceId));
    connection.writeStanza(stanza);
    final rawXml = _serializeStanza(stanza);
    final nick = _roomNickFor(normalized);
    _applyRoomMessageCorrection(
      roomJid: normalized,
      sender: nick,
      replaceId: replaceId,
      newBody: trimmed,
      oobUrl: null,
      rawXml: rawXml,
      timestamp: DateTime.now(),
    );
  }

  Future<String?> inviteToRoom({
    required String roomJid,
    required String inviteeJid,
    String? reason,
  }) async {
    final connection = _connection;
    if (connection == null || _currentUserBareJid == null) {
      return 'Not connected.';
    }
    final normalizedRoom = _bareJid(roomJid);
    final normalizedInvitee = _bareJid(inviteeJid);
    if (normalizedRoom.isEmpty || normalizedInvitee.isEmpty) {
      return 'Invalid JID.';
    }
    final inviteReason = reason?.trim();
    final invitePassword = _roomPasswordFor(normalizedRoom);

    final directId = AbstractStanza.getRandomId();
    final directStanza = MessageStanza(directId, MessageStanzaType.NORMAL);
    directStanza.toJid = Jid.fromFullJid(normalizedInvitee);
    final direct = XmppElement()..name = 'x';
    direct.addAttribute(XmppAttribute('xmlns', mucDirectInviteNamespace));
    direct.addAttribute(XmppAttribute('jid', normalizedRoom));
    if (inviteReason != null && inviteReason.isNotEmpty) {
      direct.addAttribute(XmppAttribute('reason', inviteReason));
    }
    if (invitePassword != null && invitePassword.isNotEmpty) {
      direct.addAttribute(XmppAttribute('password', invitePassword));
    }
    directStanza.addChild(direct);
    connection.writeStanza(directStanza);

    final rawXml = _serializeStanza(directStanza);
    _addMessage(
      bareJid: normalizedInvitee,
      from: _currentUserBareJid ?? '',
      to: normalizedInvitee,
      body: '',
      rawXml: rawXml,
      outgoing: true,
      timestamp: DateTime.now(),
      messageId: directId,
      inviteRoomJid: normalizedRoom,
      inviteReason: inviteReason,
      invitePassword: invitePassword,
    );

    final roomEntry = _rooms[normalizedRoom];
    if (roomEntry != null && roomEntry.joined) {
      final mediatedId = AbstractStanza.getRandomId();
      final mediated = MessageStanza(mediatedId, MessageStanzaType.NORMAL);
      mediated.toJid = Jid.fromFullJid(normalizedRoom);
      final mucUser = XmppElement()..name = 'x';
      mucUser.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#user'));
      final invite = XmppElement()..name = 'invite';
      invite.addAttribute(XmppAttribute('to', normalizedInvitee));
      if (inviteReason != null && inviteReason.isNotEmpty) {
        final reasonElement = XmppElement()..name = 'reason';
        reasonElement.textValue = inviteReason;
        invite.addChild(reasonElement);
      }
      if (invitePassword != null && invitePassword.isNotEmpty) {
        final password = XmppElement()..name = 'password';
        password.textValue = invitePassword;
        invite.addChild(password);
      }
      mucUser.addChild(invite);
      mediated.addChild(mucUser);
      connection.writeStanza(mediated);
    }

    return null;
  }

  Future<String?> sendFile({
    required String toBareJid,
    required Uint8List bytes,
    required String fileName,
    String? contentType,
  }) async {
    return _sendFileInternal(
      targetJid: toBareJid,
      bytes: bytes,
      fileName: fileName,
      contentType: contentType,
      isRoom: false,
    );
  }

  Future<String?> sendRoomFile({
    required String roomJid,
    required Uint8List bytes,
    required String fileName,
    String? contentType,
  }) async {
    return _sendFileInternal(
      targetJid: roomJid,
      bytes: bytes,
      fileName: fileName,
      contentType: contentType,
      isRoom: true,
    );
  }

  Future<String?> _sendFileInternal({
    required String targetJid,
    required Uint8List bytes,
    required String fileName,
    required bool isRoom,
    String? contentType,
  }) async {
    if (bytes.isEmpty) {
      return 'File is empty.';
    }
    final connection = _connection;
    if (connection == null || _currentUserBareJid == null) {
      return 'Not connected.';
    }
    if (!isRoom && isBookmark(targetJid)) {
      return 'Not connected to the room.';
    }
    if (!isRoom) {
      final result = await _sendJingleFile(
        toBareJid: targetJid,
        bytes: bytes,
        fileName: fileName,
        contentType: contentType,
      );
      if (result.status == _JingleFileSendStatus.ok) {
        return null;
      }
      if (result.status == _JingleFileSendStatus.unsupported) {
        return _sendHttpUploadMessage(
          targetJid: targetJid,
          bytes: bytes,
          fileName: fileName,
          contentType: contentType,
          isRoom: false,
        );
      }
      return result.error ?? 'File transfer failed.';
    }
    return _sendHttpUploadMessage(
      targetJid: targetJid,
      bytes: bytes,
      fileName: fileName,
      contentType: contentType,
      isRoom: true,
    );
  }

  Future<String?> _sendHttpUploadMessage({
    required String targetJid,
    required Uint8List bytes,
    required String fileName,
    required bool isRoom,
    String? contentType,
  }) async {
    if (bytes.isEmpty) {
      return 'File is empty.';
    }
    final connection = _connection;
    if (connection == null || _currentUserBareJid == null) {
      return 'Not connected.';
    }
    if (!isRoom && isBookmark(targetJid)) {
      return 'Not connected to the room.';
    }
    final uploadService = await _resolveHttpUploadServiceJid();
    if (uploadService == null) {
      return 'Server does not advertise HTTP upload.';
    }
    final slot = await _requestHttpUploadSlot(
      uploadService: uploadService,
      fileName: fileName,
      size: bytes.length,
      contentType: contentType,
    );
    if (slot == null) {
      return 'Unable to request an upload slot.';
    }
    final uploaded = await _uploadToSlot(
      slot: slot,
      bytes: bytes,
      contentType: contentType,
    );
    if (!uploaded) {
      return 'Upload failed.';
    }
    final normalized = _bareJid(targetJid);
    final messageId = AbstractStanza.getRandomId();
    final url = slot.getUrl.toString();
    final description = fileName.trim();
    final stanza = _buildOobMessageStanza(
      targetJid: normalized,
      messageId: messageId,
      url: url,
      description: description.isEmpty ? null : description,
      isRoom: isRoom,
    );
    connection.writeStanza(stanza);
    final rawXml = _serializeStanza(stanza);
    final now = DateTime.now();
    if (isRoom) {
      final nick = _roomNickFor(normalized);
      _addRoomMessage(
        roomJid: normalized,
        from: nick,
        body: url,
        rawXml: rawXml,
        outgoing: true,
        timestamp: now,
        messageId: messageId,
        oobUrl: url,
        oobDescription: description.isEmpty ? null : description,
      );
      return null;
    }

    final chatManager = _chatManager;
    if (chatManager == null) {
      return 'Not connected.';
    }
    final chat = chatManager.getChat(Jid.fromFullJid(normalized));
    _ensureChatSubscription(chat);
    _addMessage(
      bareJid: normalized,
      from: _currentUserBareJid ?? '',
      to: normalized,
      body: url,
      rawXml: rawXml,
      oobUrl: url,
      oobDescription: description.isEmpty ? null : description,
      outgoing: true,
      timestamp: now,
      messageId: messageId,
    );
    chat.myState = ChatState.ACTIVE;
    return null;
  }

  Future<String?> fallbackFileTransferToHttpUpload({
    required String transferId,
  }) async {
    final session = _fileTransfers[transferId];
    if (session == null || session.incoming) {
      return 'File transfer not available.';
    }
    final bytes = session.bytes;
    if (bytes == null || bytes.isEmpty) {
      return 'Original file bytes are no longer available.';
    }
    final result = await _sendHttpUploadMessage(
      targetJid: session.peerBareJid,
      bytes: bytes,
      fileName: session.fileName,
      contentType: session.fileMime,
      isRoom: false,
    );
    return result;
  }

  Future<_JingleFileSendResult> _sendJingleFile({
    required String toBareJid,
    required Uint8List bytes,
    required String fileName,
    String? contentType,
  }) async {
    final connection = _connection;
    final jingle = _jingleManager;
    if (connection == null || jingle == null || _currentUserBareJid == null) {
      return const _JingleFileSendResult(
        _JingleFileSendStatus.failed,
        'Not connected.',
      );
    }
    final normalized = _bareJid(toBareJid);
    if (normalized.isEmpty) {
      return const _JingleFileSendResult(
        _JingleFileSendStatus.failed,
        'Invalid JID.',
      );
    }
    final sid = AbstractStanza.getRandomId();
    final ibbSid = AbstractStanza.getRandomId();
    final offer = JingleFileTransferOffer(
      fileName: fileName,
      fileSize: bytes.length,
      mediaType: contentType,
    );
    final content = JingleContent(
      name: 'file',
      creator: 'initiator',
      fileOffer: offer,
      ibbTransport: JingleIbbTransport(
        sid: ibbSid,
        blockSize: _ibbDefaultBlockSize,
        stanza: 'iq',
      ),
    );
    final iq = jingle.buildSessionInitiate(
      to: Jid.fromFullJid(normalized),
      sid: sid,
      content: content,
      ibbSid: ibbSid,
      blockSize: _ibbDefaultBlockSize,
    );
    final session = _FileTransferSession.outgoing(
      sid: sid,
      peerBareJid: normalized,
      ibbSid: ibbSid,
      blockSize: _ibbDefaultBlockSize,
      fileName: fileName,
      fileSize: bytes.length,
      fileMime: contentType,
      bytes: bytes,
    );
    _fileTransfers[sid] = session;
    final transferSpan =
        _startLinkedTransaction('xmpp.file_transfer', 'xmpp.file', _connectTransaction);
    if (transferSpan != null) {
      transferSpan.setTag('xmpp.direction', 'outgoing');
      _fileTransferTransactions[sid] = transferSpan;
    }
    _addFileTransferMessage(
      bareJid: normalized,
      session: session,
      outgoing: true,
      rawXml: _serializeStanza(iq),
      state: _fileTransferStateOffered,
    );
    final result = await _sendIqAndAwait(iq);
    if (result == null || result.type != IqStanzaType.RESULT) {
      _updateFileTransferMessage(
        bareJid: normalized,
        transferId: sid,
        state: _fileTransferStateFailed,
      );
      if (result != null && result.type == IqStanzaType.ERROR) {
        final condition = _iqErrorCondition(result);
        if (_isJingleUnsupportedError(condition)) {
          return const _JingleFileSendResult(_JingleFileSendStatus.unsupported);
        }
      }
      return const _JingleFileSendResult(
        _JingleFileSendStatus.failed,
        'Jingle session-initiate failed.',
      );
    }
    return const _JingleFileSendResult(_JingleFileSendStatus.ok);
  }

  Future<void> acceptFileTransfer({
    required String transferId,
    required String savePath,
  }) async {
    final session = _fileTransfers[transferId];
    if (session == null || !session.incoming) {
      return;
    }
    if (savePath.isEmpty) {
      await declineFileTransfer(transferId: transferId);
      return;
    }
    try {
      session.savePath = savePath;
      session.sink = File(savePath).openWrite();
    } catch (_) {
      _updateFileTransferMessage(
        bareJid: session.peerBareJid,
        transferId: transferId,
        state: _fileTransferStateFailed,
      );
      return;
    }
    final jingle = _jingleManager;
    if (jingle == null) {
      return;
    }
    final content = JingleContent(
      name: 'file',
      creator: 'initiator',
      fileOffer: JingleFileTransferOffer(
        fileName: session.fileName,
        fileSize: session.fileSize,
        mediaType: session.fileMime,
      ),
      ibbTransport: JingleIbbTransport(
        sid: session.ibbSid,
        blockSize: session.blockSize,
        stanza: 'iq',
      ),
    );
    final iq = jingle.buildSessionAccept(
      to: Jid.fromFullJid(session.peerBareJid),
      sid: session.sid,
      content: content,
      ibbSid: session.ibbSid,
      blockSize: session.blockSize,
    );
    final result = await _sendIqAndAwait(iq);
    if (result == null || result.type != IqStanzaType.RESULT) {
      _updateFileTransferMessage(
        bareJid: session.peerBareJid,
        transferId: transferId,
        state: _fileTransferStateFailed,
      );
      return;
    }
    _updateFileTransferMessage(
      bareJid: session.peerBareJid,
      transferId: transferId,
      state: _fileTransferStateAccepted,
    );
  }

  Future<void> declineFileTransfer({
    required String transferId,
  }) async {
    final session = _fileTransfers[transferId];
    if (session == null) {
      return;
    }
    _updateFileTransferMessage(
      bareJid: session.peerBareJid,
      transferId: transferId,
      state: _fileTransferStateDeclined,
    );
    await _sendJingleTerminate(
      Jid.fromFullJid(session.peerBareJid),
      session.sid,
      'decline',
    );
    _finalizeTransfer(session);
  }

  void sendReaction({
    required String bareJid,
    required ChatMessage message,
    required String emoji,
    required bool isRoom,
  }) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final trimmed = emoji.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final targetId = message.stanzaId ?? message.messageId;
    if (targetId == null || targetId.isEmpty) {
      return;
    }
    final stanza = MessageStanza(
      AbstractStanza.getRandomId(),
      isRoom ? MessageStanzaType.GROUPCHAT : MessageStanzaType.CHAT,
    );
    stanza.toJid = Jid.fromFullJid(_bareJid(bareJid));
    final reactions = XmppElement()..name = 'reactions';
    reactions.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:reactions:0'));
    reactions.addAttribute(XmppAttribute('id', targetId));
    final reaction = XmppElement()..name = 'reaction';
    reaction.textValue = trimmed;
    reactions.addChild(reaction);
    stanza.addChild(reactions);
    connection.writeStanza(stanza);

    final sender = isRoom
        ? _roomNickFor(_bareJid(bareJid))
        : (_currentUserBareJid ?? '');
    if (sender.isEmpty) {
      return;
    }
    if (isRoom) {
      _applyRoomReactionUpdate(_bareJid(bareJid), sender, targetId, [trimmed]);
    } else {
      _applyReactionUpdate(_bareJid(bareJid), sender, ReactionUpdate(targetId, [trimmed]));
    }
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
      if (_rosterSpan != null) {
        _finishSpan(_rosterSpan);
        _rosterSpan = null;
      }
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
          _requestVcardDetails(jid, preferName: buddy.name == null || buddy.name!.trim().isEmpty);
        }
      }
      final nextVersion = rosterManager.rosterVersion;
      if (nextVersion != null && nextVersion != _rosterVersion) {
        _rosterVersion = nextVersion;
        _storage?.storeRosterVersion(nextVersion);
      }
    });

    _rosterSpan = _startSpan(_connectTransaction, 'xmpp.roster.fetch');
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
      final mediatedInvite = parseMucMediatedInvite(stanza);
      if (mediatedInvite != null) {
        _handleMediatedInvite(stanza, mediatedInvite);
        return;
      }
      _handleMessageStanza(stanza);
    });
  }

  void _setupJingle() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    _jingleManager = JingleManager.getInstance(connection);
    _jingleSubscription?.cancel();
    _jingleSubscription = _jingleManager!.sessionStream.listen(_handleJingleEvent);
  }

  void _setupIbb() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    _ibbManager = IbbManager.getInstance(connection);
    _ibbOpenSubscription?.cancel();
    _ibbDataSubscription?.cancel();
    _ibbCloseSubscription?.cancel();
    _ibbOpenSubscription = _ibbManager!.openStream.listen(_handleIbbOpen);
    _ibbDataSubscription = _ibbManager!.dataStream.listen(_handleIbbData);
    _ibbCloseSubscription = _ibbManager!.closeStream.listen(_handleIbbClose);
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
    _mucPresenceSubscription?.cancel();
    _mucPresenceSubscription = connection.inStanzasStream.listen((stanza) {
      if (stanza is! PresenceStanza) {
        return;
      }
      _handleMucRoomCreatedPresence(stanza);
    });
    _roomSubscriptions['message']?.cancel();
    _roomSubscriptions['message'] =
        _mucManager!.roomMessageStream.listen((message) {
      _noteRoomTraffic(message.roomJid);
      final mujiSession = _mujiSessions[_bareJid(message.roomJid)];
      if (mujiSession != null && message.nick.isNotEmpty) {
        mujiSession.setActiveSpeaker(message.nick);
      }
      if (message.replaceId != null && message.replaceId!.isNotEmpty) {
        final applied = _applyRoomMessageCorrection(
          roomJid: message.roomJid,
          sender: message.nick,
          replaceId: message.replaceId!,
          newBody: message.body,
          oobUrl: message.oobUrl,
          rawXml: message.rawXml ?? _buildIncomingGroupFallbackXml(message),
          timestamp: message.timestamp,
        );
        if (applied) {
          return;
        }
      }
      if (message.reactionTargetId != null) {
        _applyRoomReactionUpdate(
          message.roomJid,
          message.nick,
          message.reactionTargetId!,
          message.reactions,
        );
        return;
      }
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
      _noteRoomTraffic(presence.roomJid);
      final roomJid = _bareJid(presence.roomJid);
      if (presence.isSelf &&
          presence.statusCodes.contains('201') &&
          !_mucDefaultConfigSent.contains(roomJid)) {
        _mucDefaultConfigSent.add(roomJid);
        _sendMucDefaultConfig(roomJid);
      }
      final occupants = _roomOccupants.putIfAbsent(roomJid, () => <String>{});
      if (presence.unavailable) {
        occupants.remove(presence.nick);
      } else {
        occupants.add(presence.nick);
      }
      if (presence.isSelf && !presence.unavailable) {
        final joinSpan = _mucJoinTransactions.remove(roomJid);
        _finishSpan(joinSpan);
      }
      final mujiSession = _mujiSessions[roomJid];
      if (mujiSession != null && presence.nick.isNotEmpty) {
        final participantJid = Jid.fromFullJid('$roomJid/${presence.nick}');
        if (presence.unavailable) {
          mujiSession.removeParticipant(participantJid);
        } else {
          mujiSession.addParticipant(
            MujiParticipant(jid: participantJid, nick: presence.nick),
          );
        }
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
      _noteRoomTraffic(subject.roomJid);
      final roomJid = _bareJid(subject.roomJid);
      final existing = _rooms[roomJid] ?? RoomEntry(roomJid: roomJid);
      _rooms[roomJid] = existing.copyWith(subject: subject.subject);
      notifyListeners();
    });
    _startMucSelfPingTimer();
  }

  void _handleJingleEvent(JingleSessionEvent event) {
    switch (event.action) {
      case JingleAction.sessionInitiate:
        _handleJingleSessionInitiate(event);
        return;
      case JingleAction.sessionAccept:
        _handleJingleSessionAccept(event);
        return;
      case JingleAction.sessionTerminate:
        _handleJingleSessionTerminate(event);
        return;
      case JingleAction.transportInfo:
        _handleJingleTransportInfo(event);
        return;
      case JingleAction.unknown:
        return;
    }
  }

  void _handleJingleSessionInitiate(JingleSessionEvent event) {
    final rtpContents = event.contents
        .where((content) => content.rtpDescription != null)
        .toList(growable: false);
    if (rtpContents.isNotEmpty) {
      if (_callSessions.containsKey(event.sid)) {
        _storeRemoteCallContents(event.sid, rtpContents);
        _updateIncomingCallMedia(event.sid, rtpContents);
        if (_jmiAutoAcceptBySid.remove(event.sid)) {
          final session = _callSessions[event.sid];
          if (session != null) {
            _jmiIncomingPending.remove(event.sid);
            unawaited(acceptCall(session));
          }
        }
        return;
      }
      _handleIncomingCall(event, rtpContents);
      return;
    }
    final offer = event.content?.fileOffer;
    final transport = event.content?.ibbTransport;
    if (offer == null || transport == null) {
      _sendJingleTerminate(event.from, event.sid, 'unsupported-applications');
      return;
    }
    final peerBare = event.from.userAtDomain;
    if (peerBare.isEmpty) {
      return;
    }
    if (_fileTransfers.containsKey(event.sid)) {
      return;
    }
    final session = _FileTransferSession.incoming(
      sid: event.sid,
      peerBareJid: peerBare,
      ibbSid: transport.sid,
      blockSize: transport.blockSize,
      fileName: offer.fileName,
      fileSize: offer.fileSize,
      fileMime: offer.mediaType,
    );
    _fileTransfers[event.sid] = session;
    final transferSpan =
        _startLinkedTransaction('xmpp.file_transfer', 'xmpp.file', _connectTransaction);
    if (transferSpan != null) {
      transferSpan.setTag('xmpp.direction', 'incoming');
      _fileTransferTransactions[event.sid] = transferSpan;
    }
    _addFileTransferMessage(
      bareJid: peerBare,
      session: session,
      outgoing: false,
      rawXml: _serializeStanza(event.stanza),
      state: _fileTransferStateOffered,
    );
  }

  void _handleJingleSessionAccept(JingleSessionEvent event) {
    final callSession = _callSessions[event.sid];
    if (callSession != null && callSession.direction == CallDirection.outgoing) {
      _callAcceptedBySid.add(event.sid);
      _flushPendingIceCandidates(event.sid);
      callSession.state = CallState.active;
      _cancelCallTimeout(callSession.sid);
      _startCallStatsTimer(callSession.sid);
      _finishSpan(_jingleSetupTransactions.remove(event.sid));
      final rtpContents = event.contents
          .where((content) => content.rtpDescription != null)
          .toList(growable: false);
      unawaited(_applyRemoteDescriptionsForCall(
        sid: callSession.sid,
        contents: rtpContents,
        direction: callSession.direction,
        sdpType: 'answer',
      ));
      notifyListeners();
      return;
    }
    final session = _fileTransfers[event.sid];
    if (session == null || session.incoming) {
      return;
    }
    _updateFileTransferMessage(
      bareJid: session.peerBareJid,
      transferId: session.sid,
      state: _fileTransferStateAccepted,
    );
    unawaited(_sendIbbData(session));
  }

  void _handleJingleSessionTerminate(JingleSessionEvent event) {
    final callSession = _callSessions[event.sid];
    if (callSession != null) {
      final reason = event.reason ?? '';
      if (reason == 'decline') {
        callSession.state = CallState.declined;
      } else if (reason.isNotEmpty && reason != 'success') {
        callSession.state = CallState.failed;
      } else {
        callSession.state = CallState.ended;
      }
      _removeCallSession(callSession);
      return;
    }
    final session = _fileTransfers[event.sid];
    if (session == null) {
      return;
    }
    final reason = event.reason ?? '';
    final nextState = reason == 'success'
        ? _fileTransferStateCompleted
        : (reason == 'decline' ? _fileTransferStateDeclined : _fileTransferStateFailed);
    _updateFileTransferMessage(
      bareJid: session.peerBareJid,
      transferId: session.sid,
      state: nextState,
    );
    _finalizeTransfer(session);
  }

  void _handleIncomingCall(JingleSessionEvent event, List<JingleContent> contents) {
    final peerJid = event.from.fullJid ?? event.from.userAtDomain;
    if (peerJid.isEmpty) {
      return;
    }
    _storeCallPeerFullJid(event.sid, event.from);
    if (_callSessions.containsKey(event.sid)) {
      return;
    }
    _storeRemoteCallContents(event.sid, contents);
    final hasVideo = contents.any((content) =>
        (content.rtpDescription?.media.toLowerCase() ?? '') == 'video');
    _callMediaKindBySid[event.sid] = hasVideo ? CallMediaKind.video : CallMediaKind.audio;
    final session = CallSession(
      sid: event.sid,
      peerBareJid: peerJid,
      direction: CallDirection.incoming,
      video: hasVideo,
      state: CallState.ringing,
    );
    _callSessions[event.sid] = session;
    _callSessionByPeerKey[_callPeerKeyForJid(peerJid)] = event.sid;
    _callContentNamesBySid[event.sid] = _contentNamesFor(contents);
    _callMutedBySid[event.sid] = false;
    _callVideoEnabledBySid[event.sid] = session.video;
    _startCallTimeout(
      sid: event.sid,
      duration: _incomingCallTimeout,
      incoming: true,
    );
    notifyListeners();
  }

  void _updateIncomingCallMedia(String sid, List<JingleContent> contents) {
    final session = _callSessions[sid];
    if (session == null || session.direction != CallDirection.incoming) {
      return;
    }
    final hasVideo = contents.any((content) =>
        (content.rtpDescription?.media.toLowerCase() ?? '') == 'video');
    final nextVideo = hasVideo;
    if (session.video != nextVideo) {
      _callSessions[sid] = CallSession(
        sid: session.sid,
        peerBareJid: session.peerBareJid,
        direction: session.direction,
        video: nextVideo,
        state: session.state,
      );
    }
    _callMediaKindBySid[sid] = nextVideo ? CallMediaKind.video : CallMediaKind.audio;
    _callVideoEnabledBySid[sid] = nextVideo;
    _callContentNamesBySid[sid] = _contentNamesFor(contents);
    notifyListeners();
  }

  List<String> _contentNamesFor(List<JingleContent> contents) {
    final names = <String>[];
    for (final content in contents) {
      final description = content.rtpDescription;
      if (description == null) {
        continue;
      }
      final name = content.name.isEmpty ? description.media : content.name;
      if (name.isNotEmpty && !names.contains(name)) {
        names.add(name);
      }
    }
    return names;
  }

  void _storeRemoteCallContents(String sid, List<JingleContent> contents) {
    final descriptions = <String, JingleRtpDescription>{};
    final transports = <String, JingleIceTransport>{};
    for (final content in contents) {
      final description = content.rtpDescription;
      if (description == null) {
        continue;
      }
      final name = content.name.isEmpty ? description.media : content.name;
      descriptions[name] = description;
      final transport = content.iceTransport;
      if (transport != null) {
        transports[name] = transport;
      }
    }
    if (descriptions.isNotEmpty) {
      _callRemoteDescriptionsBySid[sid] = descriptions;
      _callContentNamesBySid[sid] = _contentNamesFor(contents);
    }
    if (transports.isNotEmpty) {
      _callRemoteTransportsBySid[sid] = transports;
    }
  }

  List<JingleContent> _buildCallContents(
    Map<String, JingleRtpDescription> descriptions,
    Map<String, JingleIceTransport> transports,
  ) {
    final contents = <JingleContent>[];
    for (final entry in descriptions.entries) {
      contents.add(JingleContent(
        name: entry.key,
        creator: 'initiator',
        rtpDescription: entry.value,
        iceTransport: transports[entry.key],
      ));
    }
    return contents;
  }

  Future<String?> startCall({
    required String bareJid,
    bool video = false,
  }) async {
    final peerKey = _callPeerKeyForJid(bareJid);
    if (peerKey.isEmpty) {
      return 'Invalid JID.';
    }
    if (_callSessionByPeerKey.containsKey(peerKey)) {
      return 'Call already in progress.';
    }
    final jingle = _jingleManager;
    if (jingle == null) {
      return 'Not connected.';
    }
    final sid = AbstractStanza.getRandomId();
    final kind = video ? CallMediaKind.video : CallMediaKind.audio;
    _callMediaKindBySid[sid] = kind;
    final pc = await _createPeerConnection(
      sid: sid,
      peerBareJid: bareJid,
      kind: kind,
    );
    if (pc == null) {
      return 'Unable to initialize WebRTC.';
    }
    final offer = await pc.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': video,
    });
    await pc.setLocalDescription(offer);
    var mappings = mapSdpToJingleContents(sdp: offer.sdp ?? '');
    if (!video) {
      mappings = mappings
          .where((mapping) => mapping.description.media == 'audio')
          .toList(growable: false);
    }
    if (mappings.isEmpty) {
      return 'Unable to parse local SDP.';
    }
    final localDescriptions = <String, JingleRtpDescription>{};
    final localTransports = <String, JingleIceTransport>{};
    for (final mapping in mappings) {
      localDescriptions[mapping.contentName] = mapping.description;
      localTransports[mapping.contentName] = mapping.transport;
    }
    _callLocalDescriptionsBySid[sid] = localDescriptions;
    _callLocalTransportsBySid[sid] = localTransports;
    _callContentNamesBySid[sid] =
        mappings.map((mapping) => mapping.contentName).toList(growable: false);
    _flushPendingIceCandidates(sid);
    final session = CallSession(
      sid: sid,
      peerBareJid: bareJid,
      direction: CallDirection.outgoing,
      video: video,
      state: CallState.ringing,
    );
    _callSessions[sid] = session;
    _callSessionByPeerKey[peerKey] = sid;
    _callMutedBySid[sid] = false;
    _callVideoEnabledBySid[sid] = video;
    _startCallTimeout(
      sid: sid,
      duration: _outgoingCallTimeout,
      incoming: false,
    );
    notifyListeners();
    final jingleSpan =
        _startLinkedTransaction('xmpp.jingle.setup', 'xmpp.jingle', _connectTransaction);
    if (jingleSpan != null) {
      jingleSpan.setTag('xmpp.call.direction', 'outgoing');
      _jingleSetupTransactions[sid] = jingleSpan;
    }
    if (_isMujiParticipantJid(bareJid)) {
      unawaited(_sendPendingJingleInitiate(sid, Jid.fromFullJid(bareJid)));
    } else {
      final target = _bareJid(bareJid);
      final descriptions = _buildJmiProposeDescriptions(mappings);
      if (descriptions.isNotEmpty) {
        _jmiProposedMediaBySid[sid] =
            descriptions.map((desc) => desc.media).toSet();
      }
      _sendJmiPropose(target, sid, descriptions);
      _startJmiFallbackTimer(sid, target);
    }
    return null;
  }

  Future<void> acceptCall(CallSession session) async {
    if (_jmiIncomingPending.contains(session.sid)) {
      final target = _jmiProceedTargetBySid[session.sid];
      if (target != null) {
        _sendJmiProceed(target, session.sid);
        _jmiAutoAcceptBySid.add(session.sid);
        return;
      }
    }
    if (!_jingleSetupTransactions.containsKey(session.sid)) {
      final jingleSpan =
          _startLinkedTransaction('xmpp.jingle.setup', 'xmpp.jingle', _connectTransaction);
      if (jingleSpan != null) {
        jingleSpan.setTag('xmpp.call.direction', 'incoming');
        _jingleSetupTransactions[session.sid] = jingleSpan;
      }
    }
    final jingle = _jingleManager;
    if (jingle == null) {
      return;
    }
    final kind = session.video ? CallMediaKind.video : CallMediaKind.audio;
    _callMediaKindBySid[session.sid] = kind;
    final pc = await _createPeerConnection(
      sid: session.sid,
      peerBareJid: session.peerBareJid,
      kind: kind,
    );
    if (pc == null) {
      session.state = CallState.failed;
      _removeCallSession(session);
      return;
    }
    final remoteDescriptions = _callRemoteDescriptionsBySid[session.sid] ?? {};
    final remoteTransports = _callRemoteTransportsBySid[session.sid] ?? {};
    if (remoteDescriptions.isNotEmpty && remoteTransports.isNotEmpty) {
      final sdp = buildMinimalSdpFromJingleContents(
        contents: _buildCallContents(remoteDescriptions, remoteTransports),
      );
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    }
    final answer = await pc.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': session.video,
    });
    await pc.setLocalDescription(answer);
    final mappings = mapSdpToJingleContents(sdp: answer.sdp ?? '');
    final localDescriptions = <String, JingleRtpDescription>{};
    final localTransports = <String, JingleIceTransport>{};
    for (final mapping in mappings) {
      localDescriptions[mapping.contentName] = mapping.description;
      localTransports[mapping.contentName] = mapping.transport;
    }
    _callLocalDescriptionsBySid[session.sid] = localDescriptions;
    _callLocalTransportsBySid[session.sid] = localTransports;
    _callContentNamesBySid[session.sid] =
        mappings.map((mapping) => mapping.contentName).toList(growable: false);
    _flushPendingIceCandidates(session.sid);
    final toJid = _callPeerJidForSid(session.sid, session.peerBareJid);
    if (toJid == null) {
      session.state = CallState.failed;
      _removeCallSession(session);
      return;
    }
    final iq = jingle.buildRtpSessionAcceptMulti(
      to: toJid,
      sid: session.sid,
      contents: _buildCallContents(localDescriptions, localTransports),
    );
    final result = await _sendIqAndAwait(iq);
    if (result == null || result.type != IqStanzaType.RESULT) {
      session.state = CallState.failed;
      _removeCallSession(session);
      return;
    }
    session.state = CallState.active;
    _cancelCallTimeout(session.sid);
    _startCallStatsTimer(session.sid);
    _finishSpan(_jingleSetupTransactions.remove(session.sid));
    notifyListeners();
    await _mediaSession.start(audio: true, video: session.video);
  }

  Future<void> declineCall(CallSession session) async {
    if (_jmiIncomingPending.contains(session.sid)) {
      final target = _jmiProceedTargetBySid[session.sid];
      if (target != null) {
        _sendJmiReject(target, session.sid);
      }
      session.state = CallState.declined;
      _removeCallSession(session);
      return;
    }
    final toJid = _callPeerJidForSid(session.sid, session.peerBareJid);
    if (toJid != null) {
      await _sendJingleTerminate(toJid, session.sid, 'decline');
    }
    session.state = CallState.declined;
    _removeCallSession(session);
  }

  Future<void> endCall(CallSession session) async {
    if (_jmiFallbackTimers.containsKey(session.sid)) {
      final target = Jid.fromFullJid(session.peerBareJid);
      _sendJmiRetract(target, session.sid);
      session.state = CallState.ended;
      _removeCallSession(session);
      return;
    }
    final toJid = _callPeerJidForSid(session.sid, session.peerBareJid);
    if (toJid != null) {
      await _sendJingleTerminate(toJid, session.sid, 'success');
    }
    session.state = CallState.ended;
    _removeCallSession(session);
  }

  void _startCallTimeout({
    required String sid,
    required Duration duration,
    required bool incoming,
  }) {
    _callTimeoutTimers.remove(sid)?.cancel();
    _callTimeoutTimers[sid] = Timer(duration, () {
      final session = _callSessions[sid];
      if (session == null || session.state != CallState.ringing) {
        return;
      }
      if (incoming) {
        if (_jmiIncomingPending.contains(sid)) {
          final target = _jmiProceedTargetBySid[sid];
          if (target != null) {
            _sendJmiReject(target, sid);
          }
        } else {
          final toJid = _callPeerJidForSid(session.sid, session.peerBareJid);
          if (toJid != null) {
            unawaited(_sendJingleTerminate(toJid, sid, 'timeout'));
          }
        }
        session.state = CallState.declined;
      } else {
        if (_jmiFallbackTimers.containsKey(sid)) {
          _sendJmiRetract(Jid.fromFullJid(session.peerBareJid), sid);
        } else {
          final toJid = _callPeerJidForSid(session.sid, session.peerBareJid);
          if (toJid != null) {
            unawaited(_sendJingleTerminate(toJid, sid, 'timeout'));
          }
        }
        session.state = CallState.failed;
      }
      _removeCallSession(session);
    });
  }

  void _cancelCallTimeout(String sid) {
    _callTimeoutTimers.remove(sid)?.cancel();
  }

  void _failCallSession(String sid, CallState state) {
    final session = _callSessions[sid];
    if (session == null) {
      return;
    }
    session.state = state;
    _removeCallSession(session);
  }

  void _startCallStatsTimer(String sid) {
    _callStatsTimers.remove(sid)?.cancel();
    _callStatsTimers[sid] = Timer.periodic(_callStatsInterval, (_) {
      unawaited(_collectCallStats(sid));
    });
  }

  Future<void> _collectCallStats(String sid) async {
    final pc = _callPeerConnections[sid];
    if (pc == null) {
      return;
    }
    final reports = await pc.getStats();
    final candidateReports = <String, Map<dynamic, dynamic>>{};
    Map<dynamic, dynamic>? selectedPairValues;
    String? selectedPairId;
    int? outboundBytes;
    int? inboundBytes;
    int? packetsLost;
    int? packetsReceived;
    double? jitterMs;
    double? rttMs;
    double? localAudioLevel;
    double? remoteAudioLevel;
    double? localAudioEnergy;
    double? localSamplesDuration;
    double? remoteAudioEnergy;
    double? remoteSamplesDuration;

    for (final report in reports) {
      final values = report.values;
      final type = report.type;
      if (type == 'local-candidate' || type == 'remote-candidate') {
        final reportId = report.id;
        candidateReports[reportId] = values;
        continue;
      }
      if (type == 'outbound-rtp') {
        if (_statString(values, 'kind') == 'video' ||
            _statString(values, 'mediaType') == 'video') {
          outboundBytes = (outboundBytes ?? 0) + (_statInt(values, 'bytesSent') ?? 0);
        }
        if (_statString(values, 'kind') == 'audio' ||
            _statString(values, 'mediaType') == 'audio') {
          final audioLevel = _statDouble(values, 'audioLevel');
          if (audioLevel != null) {
            final current = localAudioLevel;
            if (current == null || audioLevel > current) {
              localAudioLevel = audioLevel;
            }
          }
          localAudioEnergy =
              (localAudioEnergy ?? 0) + (_statDouble(values, 'totalAudioEnergy') ?? 0);
          localSamplesDuration =
              (localSamplesDuration ?? 0) + (_statDouble(values, 'totalSamplesDuration') ?? 0);
        }
      }
      if (type == 'inbound-rtp') {
        if (_statString(values, 'kind') == 'video' ||
            _statString(values, 'mediaType') == 'video') {
          inboundBytes = (inboundBytes ?? 0) + (_statInt(values, 'bytesReceived') ?? 0);
          packetsLost = (packetsLost ?? 0) + (_statInt(values, 'packetsLost') ?? 0);
          packetsReceived =
              (packetsReceived ?? 0) + (_statInt(values, 'packetsReceived') ?? 0);
          final jitter = _statDouble(values, 'jitter');
          if (jitter != null) {
            jitterMs = jitter * 1000;
          }
        }
        if (_statString(values, 'kind') == 'audio' ||
            _statString(values, 'mediaType') == 'audio') {
          final audioLevel = _statDouble(values, 'audioLevel');
          if (audioLevel != null) {
            final current = remoteAudioLevel;
            if (current == null || audioLevel > current) {
              remoteAudioLevel = audioLevel;
            }
          }
          remoteAudioEnergy =
              (remoteAudioEnergy ?? 0) + (_statDouble(values, 'totalAudioEnergy') ?? 0);
          remoteSamplesDuration =
              (remoteSamplesDuration ?? 0) + (_statDouble(values, 'totalSamplesDuration') ?? 0);
        }
      }
      if (type == 'candidate-pair') {
        final state = _statString(values, 'state');
        final nominated = values['nominated'] == true || values['selected'] == true;
        if (state == 'succeeded' && nominated) {
          selectedPairValues = values;
          selectedPairId = report.id;
          final rtt = _statDouble(values, 'currentRoundTripTime');
          if (rtt != null) {
            rttMs = rtt * 1000;
          }
        }
      }
    }

    _logSelectedCandidatePair(
      sid: sid,
      pairId: selectedPairId,
      values: selectedPairValues,
      candidateReports: candidateReports,
    );

    final tracker = _callStatsBySid[sid] ?? _CallStatsTracker();
    final now = DateTime.now();
    final lastAt = tracker.lastSampleAt;
    double? outboundKbps;
    double? inboundKbps;
    if (lastAt != null) {
      final deltaSeconds = now.difference(lastAt).inMilliseconds / 1000;
      if (deltaSeconds > 0) {
        if (outboundBytes != null && tracker.lastOutboundBytes != null) {
          final delta = outboundBytes - tracker.lastOutboundBytes!;
          outboundKbps = (delta * 8) / deltaSeconds / 1000;
        }
        if (inboundBytes != null && tracker.lastInboundBytes != null) {
          final delta = inboundBytes - tracker.lastInboundBytes!;
          inboundKbps = (delta * 8) / deltaSeconds / 1000;
        }
      }
    }
    double? lossRate;
    if (packetsLost != null && packetsReceived != null) {
      final total = packetsLost + packetsReceived;
      if (total > 0) {
        lossRate = packetsLost / total;
      }
    }

    final sample = CallQualitySample(
      timestamp: now,
      rttMs: rttMs,
      outboundKbps: outboundKbps,
      inboundKbps: inboundKbps,
      packetLoss: lossRate,
      jitterMs: jitterMs,
      targetVideoBitrateBps: tracker.videoBitrateTargetBps,
    );
    _callQualityBySid[sid] = sample;
    _callStatsBySid[sid] = tracker
      ..lastSampleAt = now
      ..lastOutboundBytes = outboundBytes
      ..lastInboundBytes = inboundBytes
      ..lastPacketsLost = packetsLost
      ..lastPacketsReceived = packetsReceived;
    _updateSpeakingState(
      sid: sid,
      tracker: tracker,
      localLevel: localAudioLevel,
      localEnergy: localAudioEnergy,
      localDuration: localSamplesDuration,
      remoteLevel: remoteAudioLevel,
      remoteEnergy: remoteAudioEnergy,
      remoteDuration: remoteSamplesDuration,
    );
    await _applyAdaptiveBitrate(sid, sample, tracker);
    notifyListeners();
  }

  Future<void> _applyAdaptiveBitrate(
    String sid,
    CallQualitySample sample,
    _CallStatsTracker tracker,
  ) async {
    final nextTarget = _callQualityController.nextTargetBitrate(
      currentBps: tracker.videoBitrateTargetBps,
      sample: sample,
    );
    if (nextTarget == null || nextTarget == tracker.videoBitrateTargetBps) {
      return;
    }
    final pc = _callPeerConnections[sid];
    if (pc == null) {
      return;
    }
    final senders = await pc.getSenders();
    for (final sender in senders) {
      final track = sender.track;
      if (track == null || track.kind != 'video') {
        continue;
      }
      final parameters = sender.parameters;
      final encodings = parameters.encodings ?? <RTCRtpEncoding>[];
      if (encodings.isEmpty) {
        encodings.add(RTCRtpEncoding());
      }
      encodings[0].maxBitrate = nextTarget;
      parameters.encodings = encodings;
      await sender.setParameters(parameters);
    }
    tracker.videoBitrateTargetBps = nextTarget;
    _callQualityBySid[sid] = CallQualitySample(
      timestamp: sample.timestamp,
      rttMs: sample.rttMs,
      outboundKbps: sample.outboundKbps,
      inboundKbps: sample.inboundKbps,
      packetLoss: sample.packetLoss,
      jitterMs: sample.jitterMs,
      targetVideoBitrateBps: nextTarget,
    );
  }

  int? _statInt(Map<dynamic, dynamic> values, String key) {
    final value = values[key];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  double? _statDouble(Map<dynamic, dynamic> values, String key) {
    final value = values[key];
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  String? _statString(Map<dynamic, dynamic> values, String key) {
    final value = values[key];
    if (value is String) {
      return value;
    }
    return null;
  }

  void _updateSpeakingState({
    required String sid,
    required _CallStatsTracker tracker,
    required double? localLevel,
    required double? localEnergy,
    required double? localDuration,
    required double? remoteLevel,
    required double? remoteEnergy,
    required double? remoteDuration,
  }) {
    const threshold = 0.02;
    final nextLocal =
        _resolveAudioLevel(tracker, localLevel, localEnergy, localDuration, true);
    final nextRemote =
        _resolveAudioLevel(tracker, remoteLevel, remoteEnergy, remoteDuration, false);

    bool didChange = false;
    if (nextLocal != null) {
      final speaking = nextLocal > threshold;
      if (_callLocalSpeakingBySid[sid] != speaking) {
        _callLocalSpeakingBySid[sid] = speaking;
        didChange = true;
      }
    }
    if (nextRemote != null) {
      final speaking = nextRemote > threshold;
      if (_callRemoteSpeakingBySid[sid] != speaking) {
        _callRemoteSpeakingBySid[sid] = speaking;
        didChange = true;
      }
    }
    if (didChange) {
      notifyListeners();
    }
  }

  void _logSelectedCandidatePair({
    required String sid,
    required String? pairId,
    required Map<dynamic, dynamic>? values,
    required Map<String, Map<dynamic, dynamic>> candidateReports,
  }) {
    if (values == null) {
      return;
    }
    final localId = _statString(values, 'localCandidateId');
    final remoteId = _statString(values, 'remoteCandidateId');
    final local = localId == null ? null : candidateReports[localId];
    final remote = remoteId == null ? null : candidateReports[remoteId];
    final localDesc = local == null ? 'unknown' : _describeIceCandidate(local);
    final remoteDesc = remote == null ? 'unknown' : _describeIceCandidate(remote);
    final rtt = _statDouble(values, 'currentRoundTripTime');
    final rttMs = rtt == null ? '' : ' rtt=${(rtt * 1000).toStringAsFixed(1)}ms';
    final summary = 'pair=${pairId ?? 'unknown'} local=[$localDesc] remote=[$remoteDesc]$rttMs';
    if (_callSelectedCandidateSummaryBySid[sid] == summary) {
      return;
    }
    _callSelectedCandidateSummaryBySid[sid] = summary;
    Log.d('XmppService', 'Call $sid selected ICE $summary');
  }

  String _describeIceCandidate(Map<dynamic, dynamic> values) {
    final type = _statString(values, 'candidateType') ?? 'unknown';
    final protocol = _statString(values, 'protocol') ?? 'unknown';
    final ip = _statString(values, 'ip') ?? _statString(values, 'address') ?? '?';
    final port = _statInt(values, 'port');
    final network = _statString(values, 'networkType');
    final relayProto = _statString(values, 'relayProtocol');
    final details = <String>[
      type,
      protocol,
      '$ip:${port ?? 0}',
      if (network != null && network.isNotEmpty) 'net=$network',
      if (relayProto != null && relayProto.isNotEmpty) 'relay=$relayProto',
    ];
    return details.join(' ');
  }

  double? _resolveAudioLevel(
    _CallStatsTracker tracker,
    double? level,
    double? totalEnergy,
    double? totalDuration,
    bool isLocal,
  ) {
    if (level != null) {
      return level;
    }
    if (totalEnergy == null || totalDuration == null) {
      return null;
    }
    final lastEnergy =
        isLocal ? tracker.lastLocalAudioEnergy : tracker.lastRemoteAudioEnergy;
    final lastDuration = isLocal
        ? tracker.lastLocalSamplesDuration
        : tracker.lastRemoteSamplesDuration;
    tracker
      ..lastLocalAudioEnergy = isLocal ? totalEnergy : tracker.lastLocalAudioEnergy
      ..lastRemoteAudioEnergy = isLocal ? tracker.lastRemoteAudioEnergy : totalEnergy
      ..lastLocalSamplesDuration =
          isLocal ? totalDuration : tracker.lastLocalSamplesDuration
      ..lastRemoteSamplesDuration =
          isLocal ? tracker.lastRemoteSamplesDuration : totalDuration;
    if (lastEnergy == null || lastDuration == null) {
      return null;
    }
    final deltaEnergy = totalEnergy - lastEnergy;
    final deltaDuration = totalDuration - lastDuration;
    if (deltaEnergy <= 0 || deltaDuration <= 0) {
      return null;
    }
    final rms = (deltaEnergy / deltaDuration).clamp(0.0, 1.0);
    return rms.toDouble();
  }

  void toggleCallMute(String bareJid) {
    final key = _callSessionByPeerKey[_callPeerKeyForJid(bareJid)];
    if (key == null) {
      return;
    }
    final muted = !(_callMutedBySid[key] ?? false);
    _callMutedBySid[key] = muted;
    final stream = _callLocalStreamBySid[key];
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = !muted;
      }
    }
    notifyListeners();
  }

  void toggleCallVideo(String bareJid) {
    final key = _callSessionByPeerKey[_callPeerKeyForJid(bareJid)];
    if (key == null) {
      return;
    }
    final enabled = !(_callVideoEnabledBySid[key] ?? true);
    _callVideoEnabledBySid[key] = enabled;
    final stream = _callLocalStreamBySid[key];
    if (stream != null) {
      for (final track in stream.getVideoTracks()) {
        track.enabled = enabled;
      }
    }
    notifyListeners();
  }

  void _removeCallSession(CallSession session) {
    _jmiFallbackTimers.remove(session.sid)?.cancel();
    _callTimeoutTimers.remove(session.sid)?.cancel();
    _callStatsTimers.remove(session.sid)?.cancel();
    _callStatsBySid.remove(session.sid);
    _callQualityBySid.remove(session.sid);
    _callPeerFullJidBySid.remove(session.sid);
    _callAcceptedBySid.remove(session.sid);
    _callLoggedIceQueueBySid.remove(session.sid);
    _callSelectedCandidateSummaryBySid.remove(session.sid);
    final jingleSpan = _jingleSetupTransactions.remove(session.sid);
    if (jingleSpan != null) {
      final status = switch (session.state) {
        CallState.failed => const SpanStatus.internalError(),
        CallState.declined => const SpanStatus.cancelled(),
        _ => const SpanStatus.ok(),
      };
      _finishSpan(jingleSpan, status: status);
    }
    _jmiProceedTargetBySid.remove(session.sid);
    _jmiIncomingPending.remove(session.sid);
    _jmiAutoAcceptBySid.remove(session.sid);
    _jmiProposedMediaBySid.remove(session.sid);
    _pendingIceCandidatesBySid.remove(session.sid);
    _jingleInitiatedTargets.remove(session.sid);
    final pc = _callPeerConnections.remove(session.sid);
    pc?.close();
    _callLocalStreamBySid.remove(session.sid);
    _callRemoteStreamBySid.remove(session.sid);
    _callMediaKindBySid.remove(session.sid);
    _callLocalDescriptionsBySid.remove(session.sid);
    _callRemoteDescriptionsBySid.remove(session.sid);
    _callLocalTransportsBySid.remove(session.sid);
    _callRemoteTransportsBySid.remove(session.sid);
    _callContentNamesBySid.remove(session.sid);
    _callMutedBySid.remove(session.sid);
    _callVideoEnabledBySid.remove(session.sid);
    _callLocalSpeakingBySid.remove(session.sid);
    _callRemoteSpeakingBySid.remove(session.sid);
    _callSessions.remove(session.sid);
    _callSessionByPeerKey.remove(_callPeerKeyForJid(session.peerBareJid));
    unawaited(_mediaSession.stop());
    notifyListeners();
  }

  void _handleJmiMessage(MessageStanza stanza, JmiAction action) {
    final fromJid = stanza.fromJid;
    final fromBare = fromJid?.userAtDomain ?? '';
    if (fromJid == null || fromBare.isEmpty) {
      return;
    }
    switch (action) {
      case JmiAction.propose:
        final propose = parseJmiPropose(stanza);
        if (propose == null) {
          return;
        }
        if (_currentUserBareJid != null &&
            _bareJid(fromBare) == _currentUserBareJid) {
          return;
        }
        if (_callSessions.containsKey(propose.sid)) {
          return;
        }
        _jmiProceedTargetBySid[propose.sid] = fromJid;
        _jmiIncomingPending.add(propose.sid);
        final contents = propose.descriptions
            .map(
              (description) => JingleContent(
                name: description.media,
                creator: 'initiator',
                rtpDescription: description,
              ),
            )
            .toList(growable: false);
        if (contents.isEmpty) {
          return;
        }
        final content = contents.first;
        _handleIncomingCall(
          JingleSessionEvent(
            action: JingleAction.sessionInitiate,
            sid: propose.sid,
            from: fromJid,
            to: _connection?.fullJid ?? fromJid,
            stanza: IqStanza(propose.sid, IqStanzaType.SET),
            content: content,
            contents: contents,
          ),
          contents,
        );
        _sendJmiRinging(fromJid, propose.sid);
        return;
      case JmiAction.proceed:
        final sid = parseJmiSid(stanza);
        if (sid == null) {
          return;
        }
        _storeCallPeerFullJid(sid, fromJid);
        _jmiFallbackTimers.remove(sid)?.cancel();
        unawaited(_sendPendingJingleInitiate(sid, fromJid));
        return;
      case JmiAction.reject:
      case JmiAction.retract:
        final sid = parseJmiSid(stanza);
        if (sid == null) {
          return;
        }
        final session = _callSessions[sid];
        if (session != null) {
          session.state =
              action == JmiAction.reject ? CallState.declined : CallState.ended;
          _removeCallSession(session);
        }
        return;
      case JmiAction.ringing:
        return;
    }
  }

  void _sendJmiMessage(Jid to, XmppElement child) {
    final message = MessageStanza(
      AbstractStanza.getRandomId(),
      MessageStanzaType.CHAT,
    );
    message.toJid = to;
    message.fromJid = _connection?.fullJid;
    message.addChild(child);
    _connection?.writeStanza(message);
  }

  void _sendJmiPropose(
    String bareJid,
    String sid,
    List<JingleRtpDescription> descriptions,
  ) {
    final to = Jid.fromFullJid(bareJid);
    if (descriptions.isEmpty) {
      return;
    }
    _sendJmiMessage(
      to,
      buildJmiProposeElement(sid: sid, descriptions: descriptions),
    );
  }

  void _sendJmiProceed(Jid to, String sid) {
    _sendJmiMessage(to, buildJmiProceedElement(sid: sid));
  }

  void _sendJmiReject(Jid to, String sid) {
    _sendJmiMessage(to, buildJmiRejectElement(sid: sid));
  }

  void _sendJmiRinging(Jid to, String sid) {
    _sendJmiMessage(to, buildJmiRingingElement(sid: sid));
  }

  void _sendJmiRetract(Jid to, String sid) {
    _sendJmiMessage(to, buildJmiRetractElement(sid: sid));
  }

  List<JingleRtpDescription> _buildJmiProposeDescriptions(
    List<JingleSdpMapping> mappings,
  ) {
    final byMedia = <String, JingleRtpDescription>{};
    for (final mapping in mappings) {
      final media = mapping.description.media;
      if (media.isEmpty || byMedia.containsKey(media)) {
        continue;
      }
      byMedia[media] = JingleRtpDescription(
        media: media,
        payloadTypes: const [],
        rtcpFeedback: const [],
        headerExtensions: const [],
        sources: const [],
        sourceGroups: const [],
      );
    }
    if (byMedia.isEmpty) {
      return const [];
    }
    final ordered = <JingleRtpDescription>[];
    if (byMedia.containsKey('audio')) {
      ordered.add(byMedia['audio']!);
    }
    if (byMedia.containsKey('video')) {
      ordered.add(byMedia['video']!);
    }
    for (final entry in byMedia.entries) {
      if (entry.key == 'audio' || entry.key == 'video') {
        continue;
      }
      ordered.add(entry.value);
    }
    return ordered;
  }

  void _startJmiFallbackTimer(String sid, String bareJid) {
    _jmiFallbackTimers[sid]?.cancel();
    _jmiFallbackTimers[sid] = Timer(const Duration(seconds: 5), () {
      unawaited(_sendPendingJingleInitiate(sid, Jid.fromFullJid(bareJid)));
    });
  }

  Future<void> _sendPendingJingleInitiate(String sid, Jid to) async {
    final jingle = _jingleManager;
    if (jingle == null) {
      return;
    }
    _storeCallPeerFullJid(sid, to);
    final targetKey = to.fullJid ?? to.userAtDomain;
    if (targetKey.isEmpty) {
      return;
    }
    final previousTarget = _jingleInitiatedTargets[sid];
    if (previousTarget == targetKey) {
      return;
    }
    final descriptions = _callLocalDescriptionsBySid[sid];
    final transports = _callLocalTransportsBySid[sid];
    if (descriptions == null || transports == null) {
      return;
    }
    final contents = _buildCallContents(descriptions, transports);
    final proposedMedia = _jmiProposedMediaBySid[sid];
    final filteredContents = proposedMedia == null
        ? contents
        : contents
            .where(
              (content) => proposedMedia.contains(
                content.rtpDescription?.media ?? '',
              ),
            )
            .toList(growable: false);
    if (proposedMedia != null && filteredContents.isEmpty) {
      Log.w(
        'XmppService',
        'No matching Jingle contents for proposed media "${proposedMedia.join(', ')}".',
      );
      _failCallSession(sid, CallState.failed);
      return;
    }
    if (filteredContents.isEmpty) {
      return;
    }
    final toJid = _callPeerJidForSid(sid, to.userAtDomain);
    if (toJid == null) {
      _failCallSession(sid, CallState.failed);
      return;
    }
    final iq = jingle.buildRtpSessionInitiateMulti(
      to: toJid,
      sid: sid,
      contents: filteredContents,
    );
    _jingleInitiatedTargets[sid] = toJid.fullJid ?? toJid.userAtDomain;
    _flushPendingIceCandidates(sid);
    final result = await _sendIqAndAwait(iq);
    if (result == null || result.type != IqStanzaType.RESULT) {
      _failCallSession(sid, CallState.failed);
    }
  }

  Future<void> _applyRemoteDescriptionsForCall({
    required String sid,
    required List<JingleContent> contents,
    required CallDirection direction,
    required String sdpType,
  }) async {
    if (contents.isEmpty) {
      return;
    }
    _storeRemoteCallContents(sid, contents);
    if (direction == CallDirection.incoming) {
      return;
    }
    final pc = _callPeerConnections[sid];
    if (pc == null) {
      return;
    }
    final remoteDescriptions = _callRemoteDescriptionsBySid[sid] ?? {};
    final remoteTransports = _callRemoteTransportsBySid[sid] ?? {};
    if (remoteDescriptions.isEmpty || remoteTransports.isEmpty) {
      return;
    }
    final sdp = buildMinimalSdpFromJingleContents(
      contents: _buildCallContents(remoteDescriptions, remoteTransports),
    );
    await pc.setRemoteDescription(RTCSessionDescription(sdp, sdpType));
  }

  void _handleJingleTransportInfo(JingleSessionEvent event) {
    final transport = event.content?.iceTransport;
    if (transport == null) {
      return;
    }
    final contentName = event.content?.name ?? '';
    if (contentName.isEmpty) {
      return;
    }
    final remoteTransports =
        _callRemoteTransportsBySid[event.sid] ?? <String, JingleIceTransport>{};
    final existing = remoteTransports[contentName];
    remoteTransports[contentName] =
        existing == null ? transport : mergeIceTransports(existing, transport);
    _callRemoteTransportsBySid[event.sid] = remoteTransports;
    final pc = _callPeerConnections[event.sid];
    if (pc == null) {
      return;
    }
    final mid = contentName;
    for (final candidate in transport.candidates) {
      Log.d(
        'XmppService',
        'Call ${event.sid} remote ICE candidate ${candidate.type} '
        '${candidate.protocol} ${candidate.ip}:${candidate.port} '
        'comp=${candidate.component} content=$contentName',
      );
      final candidateLine = _buildCandidateLine(candidate);
      pc.addCandidate(RTCIceCandidate(candidateLine, mid, null));
    }
  }

  @visibleForTesting
  static JingleIceTransport mergeIceTransports(
    JingleIceTransport existing,
    JingleIceTransport update,
  ) {
    final mergedCandidates = <JingleIceCandidate>[];
    final candidateKeys = <String>{};
    void addCandidate(JingleIceCandidate candidate) {
      final key = '${candidate.foundation}|${candidate.component}|'
          '${candidate.protocol}|${candidate.priority}|${candidate.ip}|'
          '${candidate.port}|${candidate.type}|${candidate.generation ?? ''}';
      if (candidateKeys.add(key)) {
        mergedCandidates.add(candidate);
      }
    }

    for (final candidate in update.candidates) {
      addCandidate(candidate);
    }
    for (final candidate in existing.candidates) {
      addCandidate(candidate);
    }

    final ufrag = update.ufrag.isNotEmpty ? update.ufrag : existing.ufrag;
    final password =
        update.password.isNotEmpty ? update.password : existing.password;
    final fingerprint = update.fingerprint ?? existing.fingerprint;

    return JingleIceTransport(
      ufrag: ufrag,
      password: password,
      candidates: mergedCandidates,
      fingerprint: fingerprint,
    );
  }

  String _buildCandidateLine(JingleIceCandidate candidate) {
    final buffer = StringBuffer();
    buffer.write('candidate:${candidate.foundation} ');
    buffer.write('${candidate.component} ');
    buffer.write('${candidate.protocol} ');
    buffer.write('${candidate.priority} ');
    buffer.write('${candidate.ip} ');
    buffer.write('${candidate.port} ');
    buffer.write('typ ${candidate.type}');
    return buffer.toString();
  }

  Future<RTCPeerConnection?> _createPeerConnection({
    required String sid,
    required String peerBareJid,
    required CallMediaKind kind,
  }) async {
    final config = <String, dynamic>{'iceServers': _iceServers};
    final pc = await createPeerConnection(config);
    _callPeerConnections[sid] = pc;
    MediaStreamHandle handle;
    try {
      handle = await _mediaSession.start(
        audio: true,
        video: kind == CallMediaKind.video,
        audioDeviceId: _preferredAudioInputId,
        videoDeviceId: _preferredVideoInputId,
      );
    } catch (error) {
      Log.w('XmppService', 'Unable to start media session: $error');
      await pc.close();
      _callPeerConnections.remove(sid);
      return null;
    }
    if (handle is WebRtcMediaStreamHandle) {
      _callLocalStreamBySid[sid] = handle.stream;
      for (final track in handle.stream.getTracks()) {
        await pc.addTrack(track, handle.stream);
      }
    }
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _callRemoteStreamBySid[sid] = event.streams.first;
        notifyListeners();
      }
    };
    pc.onSignalingState = (state) {
      Log.d('XmppService', 'Call $sid signaling state: $state');
    };
    pc.onIceGatheringState = (state) {
      Log.d('XmppService', 'Call $sid ICE gathering state: $state');
    };
    pc.onIceConnectionState = (state) {
      Log.d('XmppService', 'Call $sid ICE connection state: $state');
    };
    pc.onConnectionState = (state) {
      Log.d('XmppService', 'Call $sid connection state: $state');
    };
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) {
        return;
      }
      final parsed = _parseIceCandidate(candidate.candidate);
      if (parsed != null) {
        Log.d(
          'XmppService',
          'Call $sid local ICE candidate ${parsed.type} ${parsed.protocol} '
          '${parsed.ip}:${parsed.port} comp=${parsed.component}',
        );
      }
      final transports = _callLocalTransportsBySid[sid];
      if (transports == null || transports.isEmpty) {
        _queueIceCandidate(sid, candidate);
        return;
      }
      _sendIceCandidate(
        sid: sid,
        candidate: candidate,
        peerBareJid: peerBareJid,
        defaultKind: kind,
      );
    };
    return pc;
  }

  void _queueIceCandidate(String sid, RTCIceCandidate candidate) {
    final pending = _pendingIceCandidatesBySid.putIfAbsent(sid, () => []);
    pending.add(candidate);
  }

  void _flushPendingIceCandidates(String sid) {
    final pending = _pendingIceCandidatesBySid.remove(sid);
    if (pending == null || pending.isEmpty) {
      return;
    }
    final session = _callSessions[sid];
    final peerBare = session?.peerBareJid ?? '';
    if (peerBare.isEmpty) {
      return;
    }
    final defaultKind =
        session?.video == true ? CallMediaKind.video : CallMediaKind.audio;
    for (final candidate in pending) {
      _sendIceCandidate(
        sid: sid,
        candidate: candidate,
        peerBareJid: peerBare,
        defaultKind: defaultKind,
      );
    }
  }

  void _sendIceCandidate({
    required String sid,
    required RTCIceCandidate candidate,
    required String peerBareJid,
    required CallMediaKind defaultKind,
  }) {
    final session = _callSessions[sid];
    if (session != null &&
        session.direction == CallDirection.outgoing &&
        !_callAcceptedBySid.contains(sid)) {
      _queueIceCandidate(sid, candidate);
      if (_callLoggedIceQueueBySid.add(sid)) {
        Log.d(
          'XmppService',
          'Call $sid delaying ICE until session-accept.',
        );
      }
      return;
    }
    final transports = _callLocalTransportsBySid[sid];
    if (transports == null || transports.isEmpty) {
      return;
    }
    final parsed = _parseIceCandidate(candidate.candidate);
    if (parsed == null) {
      return;
    }
    final jingle = _jingleManager;
    if (jingle == null) {
      return;
    }
    final contentName =
        _candidateContentName(sid, candidate, defaultKind) ?? '';
    Log.d(
      'XmppService',
      'Call $sid send ICE candidate ${parsed.type} ${parsed.protocol} '
      '${parsed.ip}:${parsed.port} comp=${parsed.component} content=$contentName',
    );
    final transport = transports[contentName] ?? transports.values.first;
    final transportInfo = transportInfoTransport(transport, parsed);
    final toJid = _callPeerJidForSid(sid, peerBareJid);
    if (toJid == null) {
      _queueIceCandidate(sid, candidate);
      if (_callLoggedIceQueueBySid.add(sid)) {
        Log.d(
          'XmppService',
          'Call $sid delaying ICE until peer full JID is known.',
        );
      }
      return;
    }
    final info = jingle.buildTransportInfo(
      to: toJid,
      sid: sid,
      contentName:
          contentName.isNotEmpty ? contentName : transports.keys.first,
      creator: 'initiator',
      transport: transportInfo,
    );
    unawaited(_sendIqAndAwait(info));
  }

  String? _candidateContentName(
    String sid,
    RTCIceCandidate candidate,
    CallMediaKind defaultKind,
  ) {
    final byMid = candidate.sdpMid;
    if (byMid != null && byMid.isNotEmpty) {
      return byMid;
    }
    final index = candidate.sdpMLineIndex;
    final names = _callContentNamesBySid[sid];
    if (index != null && names != null && index >= 0 && index < names.length) {
      return names[index];
    }
    return _callContentNamesBySid[sid]?.first ??
        (defaultKind == CallMediaKind.video ? 'video' : 'audio');
  }

  JingleIceCandidate? _parseIceCandidate(String? candidateLine) {
    if (candidateLine == null || candidateLine.isEmpty) {
      return null;
    }
    final value = candidateLine.startsWith('candidate:')
        ? candidateLine.substring('candidate:'.length)
        : candidateLine;
    final parts = value.split(' ');
    if (parts.length < 8) {
      return null;
    }
    final foundation = parts[0];
    final component = int.tryParse(parts[1]);
    final protocol = parts[2];
    final priority = int.tryParse(parts[3]);
    final ip = parts[4];
    final port = int.tryParse(parts[5]);
    final typeIndex = parts.indexOf('typ');
    final type = typeIndex >= 0 && typeIndex + 1 < parts.length
        ? parts[typeIndex + 1]
        : '';
    if (component == null || priority == null || port == null || type.isEmpty) {
      return null;
    }
    return JingleIceCandidate(
      foundation: foundation,
      component: component,
      protocol: protocol,
      priority: priority,
      ip: ip,
      port: port,
      type: type,
    );
  }

  @visibleForTesting
  static JingleIceTransport transportInfoTransport(
    JingleIceTransport base,
    JingleIceCandidate candidate,
  ) {
    return JingleIceTransport(
      ufrag: base.ufrag,
      password: base.password,
      candidates: [candidate],
      // Fingerprints are exchanged during session-initiate/accept.
      // Some clients treat fingerprints in transport-info as a change.
      fingerprint: null,
    );
  }

  void _storeCallPeerFullJid(String sid, Jid jid) {
    final resource = jid.resource;
    if (resource == null || resource.isEmpty) {
      return;
    }
    final full = jid.fullJid;
    if (full == null || full.isEmpty) {
      return;
    }
    _callPeerFullJidBySid[sid] = full;
    _flushPendingIceCandidates(sid);
  }

  ISentrySpan? _startTransaction({
    required String name,
    required String operation,
    Map<String, String>? tags,
  }) {
    if (!Sentry.isEnabled) {
      return null;
    }
    final span = Sentry.startTransaction(
      name,
      operation,
      bindToScope: false,
      waitForChildren: true,
    );
    if (tags != null) {
      for (final entry in tags.entries) {
        span.setTag(entry.key, entry.value);
      }
    }
    return span;
  }

  ISentrySpan? _startLinkedTransaction(
    String name,
    String operation,
    ISentrySpan? parent,
  ) {
    if (!Sentry.isEnabled) {
      return null;
    }
    if (parent == null) {
      return _startTransaction(name: name, operation: operation);
    }
    final context = SentryTransactionContext.fromSentryTrace(
      name,
      operation,
      parent.toSentryTrace(),
    );
    return Sentry.startTransactionWithContext(
      context,
      bindToScope: false,
      waitForChildren: true,
    );
  }

  ISentrySpan? _startSpan(
    ISentrySpan? parent,
    String operation, {
    String? description,
  }) {
    if (parent == null) {
      return null;
    }
    return parent.startChild(operation, description: description);
  }

  void _finishSpan(ISentrySpan? span, {SpanStatus? status}) {
    if (span == null || span.finished) {
      return;
    }
    span.finish(status: status);
  }

  void _finishMamSyncIfIdle() {
    if (_mamSyncTransaction == null) {
      return;
    }
    if (_globalBackfillInProgress) {
      return;
    }
    _finishSpan(_mamSyncTransaction);
    _mamSyncTransaction = null;
  }

  List<String> _onlineFullJidsForBare(String bareJid) {
    final normalized = _bareJid(bareJid).toLowerCase();
    final candidates = <String>[];
    for (final entry in _presenceByFullJid.entries) {
      if (_bareJid(entry.key).toLowerCase() != normalized) {
        continue;
      }
      final status = entry.value.status?.toLowerCase();
      if (status == 'unavailable') {
        continue;
      }
      candidates.add(entry.key);
    }
    candidates.sort();
    return candidates;
  }

  bool _featuresSupportJingle(Set<String> features) {
    return features.contains(_jingleNamespace) ||
        features.contains(jmiNamespace) ||
        features.contains(_jingleRtpNamespace);
  }

  String? _selectJinglePeerFullJid(String bareJid) {
    final candidates = _onlineFullJidsForBare(bareJid);
    if (candidates.isEmpty) {
      return null;
    }
    for (final fullJid in candidates) {
      final features = _pepCapsManager?.featuresForFullJid(fullJid);
      if (features == null || features.isEmpty) {
        continue;
      }
      if (_featuresSupportJingle(features)) {
        return fullJid;
      }
    }
    // If no caps info is available, fall back to the first online resource.
    return candidates.first;
  }

  Jid? _callPeerJidForSid(String sid, String fallbackJid) {
    final full = _callPeerFullJidBySid[sid];
    if (full != null && full.isNotEmpty) {
      return Jid.fromFullJid(full);
    }
    final bare = _bareJid(fallbackJid);
    final selected = _selectJinglePeerFullJid(bare);
    if (selected == null || selected.isEmpty) {
      return null;
    }
    _callPeerFullJidBySid[sid] = selected;
    return Jid.fromFullJid(selected);
  }

  void _handleIbbOpen(IbbOpen open) {
    final session = _findTransferByIbbSid(open.sid);
    if (session == null) {
      return;
    }
    session.blockSize = open.blockSize;
    _updateFileTransferMessage(
      bareJid: session.peerBareJid,
      transferId: session.sid,
      state: _fileTransferStateInProgress,
      fileBytes: session.bytesTransferred,
    );
  }

  void _handleIbbData(IbbData data) {
    final session = _findTransferByIbbSid(data.sid);
    if (session == null) {
      return;
    }
    if (session.incoming && session.sink != null) {
      session.sink!.add(data.bytes);
    }
    session.bytesTransferred += data.bytes.length;
    _updateFileTransferMessage(
      bareJid: session.peerBareJid,
      transferId: session.sid,
      state: _fileTransferStateInProgress,
      fileBytes: session.bytesTransferred,
    );
  }

  void _handleIbbClose(IbbClose close) {
    final session = _findTransferByIbbSid(close.sid);
    if (session == null) {
      return;
    }
    _finalizeTransfer(session);
    _updateFileTransferMessage(
      bareJid: session.peerBareJid,
      transferId: session.sid,
      state: _fileTransferStateCompleted,
      fileBytes: session.bytesTransferred,
    );
  }

  void _handleMessageStanza(MessageStanza stanza) {
    if (stanza.type != MessageStanzaType.CHAT) {
      return;
    }
    final intents = _buildMessageIntents(stanza);
    _applyMessageIntents(stanza, intents);
  }

  List<MessageIntent> _buildMessageIntents(MessageStanza stanza) {
    final fromBare = stanza.fromJid?.userAtDomain ?? '';
    if (fromBare.isEmpty) {
      return const [
        UnhandledMessageIntent(reason: 'missing-from'),
      ];
    }
    final jmiAction = parseJmiAction(stanza);
    if (jmiAction != null) {
      return [
        HandleJmiIntent(action: jmiAction),
      ];
    }
    final receiptId = _extractReceiptsId(stanza);
    if (receiptId != null) {
      return [
        ApplyReceiptIntent(
          scopedId: MessageScopedId(scopeJid: fromBare, id: receiptId),
        ),
      ];
    }
    final displayedId = _extractMarkerId(stanza, 'displayed');
    if (displayedId != null) {
      return [
        ApplyDisplayedIntent(
          scopedId: MessageScopedId(scopeJid: fromBare, id: displayedId),
        ),
      ];
    }
    final reaction = _extractReactionUpdate(stanza);
    if (reaction != null) {
      final targetBare = _reactionChatTarget(
        fromBare,
        stanza.toJid?.userAtDomain ?? '',
      );
      if (targetBare.isEmpty) {
        return const [
          UnhandledMessageIntent(reason: 'reaction-target-empty'),
        ];
      }
      return [
        ApplyReactionIntent(
          targetBareJid: targetBare,
          senderBareJid: fromBare,
          update: reaction,
        ),
      ];
    }
    final body = stanza.body ?? '';
    final oobInfo = _extractOobInfoFromStanza(stanza);
    final oobUrl = oobInfo?.url;
    if (body.trim().isEmpty && (oobUrl == null || oobUrl.isEmpty)) {
      return const [
        UnhandledMessageIntent(reason: 'empty-body'),
      ];
    }
    if (_isArchivedStanza(stanza)) {
      return const [
        UnhandledMessageIntent(reason: 'archived'),
      ];
    }
    if (_currentUserBareJid != null && _bareJid(fromBare) == _currentUserBareJid) {
      return const [
        UnhandledMessageIntent(reason: 'self-message'),
      ];
    }
    final messageId = stanza.id;
    if (messageId == null || messageId.isEmpty) {
      return const [
        UnhandledMessageIntent(reason: 'missing-message-id'),
      ];
    }
    final intents = <MessageIntent>[];
    if (_hasReceiptRequest(stanza)) {
      intents.add(
        SendReceiptIntent(
          toBareJid: fromBare,
          scopedId: MessageScopedId(scopeJid: fromBare, id: messageId),
        ),
      );
    }
    if (_hasMarkable(stanza)) {
      intents.add(
        SendMarkerIntent(
          toBareJid: fromBare,
          scopedId: MessageScopedId(scopeJid: fromBare, id: messageId),
          name: 'received',
        ),
      );
      if (_activeChatBareJid != null &&
          _bareJid(_activeChatBareJid!) == _bareJid(fromBare)) {
        intents.add(
          SendMarkerIntent(
            toBareJid: fromBare,
            scopedId: MessageScopedId(scopeJid: fromBare, id: messageId),
            name: 'displayed',
          ),
        );
      }
    }
    intents.add(
      AddMessageIntent(
        bareJid: fromBare,
        from: fromBare,
        to: stanza.toJid?.userAtDomain ?? '',
        body: body,
        timestamp: DateTime.now(),
        messageId: messageId,
        rawXml: _serializeStanza(stanza),
        oobUrl: oobUrl,
        oobDescription: oobInfo?.description,
      ),
    );
    if (intents.isEmpty) {
      return const [
        UnhandledMessageIntent(reason: 'no-action'),
      ];
    }
    return intents;
  }

  @visibleForTesting
  List<MessageIntent> buildMessageIntentsForTesting(MessageStanza stanza) {
    return _buildMessageIntents(stanza);
  }

  void _applyMessageIntents(MessageStanza stanza, List<MessageIntent> intents) {
    for (final intent in intents) {
      if (intent is HandleJmiIntent) {
        _handleJmiMessage(stanza, intent.action);
      } else if (intent is ApplyReceiptIntent) {
        _applyReceipt(intent.scopedId.scopeJid, intent.scopedId.id);
      } else if (intent is ApplyDisplayedIntent) {
        _applyDisplayed(intent.scopedId.scopeJid, intent.scopedId.id);
      } else if (intent is ApplyReactionIntent) {
        _applyReactionUpdate(
          intent.targetBareJid,
          intent.senderBareJid,
          intent.update,
        );
      } else if (intent is SendReceiptIntent) {
        _sendReceipt(intent.toBareJid, intent.scopedId.id);
      } else if (intent is SendMarkerIntent) {
        _sendMarker(intent.toBareJid, intent.scopedId.id, intent.name);
      } else if (intent is AddMessageIntent) {
        _addMessage(
          bareJid: intent.bareJid,
          from: intent.from,
          to: intent.to,
          body: intent.body,
          rawXml: intent.rawXml,
          outgoing: false,
          timestamp: intent.timestamp,
          messageId: intent.messageId,
          oobUrl: intent.oobUrl,
          oobDescription: intent.oobDescription,
        );
      } else if (intent is UnhandledMessageIntent) {
        _logUnhandledMessage(stanza, intent);
      }
    }
  }

  void _logUnhandledMessage(
    MessageStanza stanza,
    UnhandledMessageIntent intent,
  ) {
    final from = stanza.fromJid?.fullJid ?? stanza.fromJid?.userAtDomain ?? '';
    final type = stanza.type.toString();
    final id = stanza.id ?? '';
    Log.w(
      'XmppService',
      'Unhandled message stanza: reason=${intent.reason} type=$type from=$from id=$id',
    );
  }

  void _handleMediatedInvite(MessageStanza stanza, MucMediatedInvite invite) {
    final inviter = invite.inviterJid ?? '';
    if (inviter.isEmpty) {
      return;
    }
    final current = _currentUserBareJid ?? '';
    final rawXml = _serializeStanza(stanza);
    _addMessage(
      bareJid: inviter,
      from: inviter,
      to: current,
      body: '',
      rawXml: rawXml,
      outgoing: false,
      timestamp: DateTime.now(),
      messageId: stanza.id,
      inviteRoomJid: invite.roomJid,
      inviteReason: invite.reason,
      invitePassword: invite.password,
    );
  }

  void _handleMucRoomCreatedPresence(PresenceStanza stanza) {
    final from = stanza.fromJid;
    if (from == null || from.resource == null || from.resource!.isEmpty) {
      return;
    }
    final statusCodes = _mucStatusCodesFromPresence(stanza);
    if (!statusCodes.contains('201') || !statusCodes.contains('110')) {
      return;
    }
    final roomJid = from.userAtDomain;
    if (roomJid.isEmpty || _mucDefaultConfigSent.contains(roomJid)) {
      return;
    }
    _mucDefaultConfigSent.add(roomJid);
    _sendMucDefaultConfig(roomJid);
  }

  Set<String> _mucStatusCodesFromPresence(PresenceStanza stanza) {
    for (final child in stanza.children) {
      if (child.name != 'x') {
        continue;
      }
      if (child.getAttribute('xmlns')?.value != 'http://jabber.org/protocol/muc#user') {
        continue;
      }
      return child.children
          .where((status) => status.name == 'status')
          .map((status) => status.getAttribute('code')?.value ?? '')
          .where((code) => code.isNotEmpty)
          .toSet();
    }
    return <String>{};
  }

  void _noteRoomTraffic(String roomJid) {
    final normalized = _bareJid(roomJid);
    if (normalized.isEmpty) {
      return;
    }
    _roomLastTrafficAt[normalized] = DateTime.now();
    _roomLastPingAt.remove(normalized);
  }

  Future<void> _refreshExternalServices() async {
    final connection = _connection;
    if (connection == null || _currentUserBareJid == null) {
      return;
    }
    final domain = Jid.fromFullJid(_currentUserBareJid!).domain;
    if (domain.isEmpty) {
      return;
    }
    final iq = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.GET);
    iq.toJid = Jid.fromFullJid(domain);
    final services = XmppElement()..name = 'services';
    services.addAttribute(XmppAttribute('xmlns', extDiscoNamespace));
    iq.addChild(services);
    final result = await _sendIqAndAwait(iq);
    if (result == null || result.type != IqStanzaType.RESULT) {
      return;
    }
    final servicesElement = result.getChild('services');
    final parsed = parseExternalServices(servicesElement);
    _iceServers = parsed.map(_toIceServer).toList(growable: false);
  }

  Map<String, dynamic> _toIceServer(ExternalService service) {
    final uri = service.toUriString();
    if (service.type.toLowerCase().startsWith('turn')) {
      return {
        'urls': [uri],
        'username': service.username ?? '',
        'credential': service.password ?? '',
      };
    }
    return {
      'urls': [uri],
    };
  }

  void _startMucSelfPingTimer() {
    _mucSelfPingTimer?.cancel();
    _mucSelfPingTimer = Timer.periodic(_mucSelfPingCheckInterval, (_) {
      _tickMucSelfPing();
    });
  }

  void _tickMucSelfPing() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final now = DateTime.now();
    for (final entry in _rooms.values) {
      if (!entry.joined || entry.nick == null || entry.nick!.isEmpty) {
        continue;
      }
      final roomJid = _bareJid(entry.roomJid);
      if (roomJid.isEmpty) {
        continue;
      }
      final lastTraffic = _roomLastTrafficAt[roomJid];
      if (lastTraffic == null) {
        _roomLastTrafficAt[roomJid] = now;
        continue;
      }
      if (now.difference(lastTraffic) < _mucSelfPingIdle) {
        continue;
      }
      final lastPing = _roomLastPingAt[roomJid];
      if (lastPing != null && !lastPing.isBefore(lastTraffic)) {
        continue;
      }
      if (_hasPendingMucSelfPing(roomJid)) {
        continue;
      }
      _sendMucSelfPing(roomJid, entry.nick!);
      _roomLastPingAt[roomJid] = now;
    }
  }

  bool _hasPendingMucSelfPing(String roomJid) {
    final normalized = _bareJid(roomJid);
    for (final pending in _pendingMucSelfPings.values) {
      if (pending == normalized) {
        return true;
      }
    }
    return false;
  }

  void _sendMucSelfPing(String roomJid, String nick) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final id = AbstractStanza.getRandomId();
    final stanza = buildMucSelfPing(
      id: id,
      fullJid: '${_bareJid(roomJid)}/$nick',
    );
    connection.writeStanza(stanza);
    _pendingMucSelfPings[id] = _bareJid(roomJid);
    _mucSelfPingTimeouts[id]?.cancel();
    _mucSelfPingTimeouts[id] =
        Timer(_mucSelfPingTimeout, () => _handleMucSelfPingTimeout(id));
  }

  void _handleMucSelfPingTimeout(String id) {
    final roomJid = _pendingMucSelfPings.remove(id);
    _mucSelfPingTimeouts.remove(id)?.cancel();
    if (roomJid == null) {
      return;
    }
    _roomLastPingAt[roomJid] = DateTime.now();
  }

  void _handleMucSelfPingResponse(String roomJid, IqStanza stanza) {
    final normalized = _bareJid(roomJid);
    final outcome = mucSelfPingOutcomeFromResponse(stanza);
    switch (outcome) {
      case MucSelfPingOutcome.joined:
        _roomLastTrafficAt[normalized] = DateTime.now();
        _roomLastPingAt[normalized] = DateTime.now();
        return;
      case MucSelfPingOutcome.inconclusive:
        _roomLastPingAt[normalized] = DateTime.now();
        return;
      case MucSelfPingOutcome.notJoined:
        _roomLastPingAt[normalized] = DateTime.now();
        _rejoinRoom(normalized);
        return;
    }
  }

  void _rejoinRoom(String roomJid) {
    final entry = _rooms[_bareJid(roomJid)];
    if (entry == null) {
      return;
    }
    joinRoom(entry.roomJid, nick: entry.nick);
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

  _OobInfo? _extractOobInfoFromStanza(XmppElement stanza) {
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
        if (url == null || url.isEmpty) {
          continue;
        }
        final description = child.getChild('desc')?.textValue?.trim();
        return _OobInfo(url: url, description: description);
      }
    }
    return null;
  }

  ReactionUpdate? _extractReactionUpdate(XmppElement stanza) {
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
        if (child.name != 'reactions' ||
            child.getAttribute('xmlns')?.value != 'urn:xmpp:reactions:0') {
          continue;
        }
        final targetId = child.getAttribute('id')?.value ?? '';
        if (targetId.isEmpty) {
          return null;
        }
        final reactions = child.children
            .where((reaction) => reaction.name == 'reaction')
            .map((reaction) => reaction.textValue?.trim() ?? '')
            .where((value) => value.isNotEmpty)
            .toList();
        return ReactionUpdate(targetId, reactions);
      }
    }
    return null;
  }

  String? _extractReplaceIdFromStanza(XmppElement stanza) {
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
        if (child.name != 'replace' ||
            child.getAttribute('xmlns')?.value != 'urn:xmpp:message-correct:0') {
          continue;
        }
        final id = child.getAttribute('id')?.value;
        if (id != null && id.isNotEmpty) {
          return id;
        }
      }
    }
    return null;
  }

  String _reactionChatTarget(String fromBare, String toBare) {
    final selfBare = _currentUserBareJid;
    if (selfBare != null && _bareJid(fromBare) == selfBare) {
      return _bareJid(toBare);
    }
    return _bareJid(fromBare);
  }

  void _applyReactionUpdate(String bareJid, String sender, ReactionUpdate update) {
    final normalized = _bareJid(bareJid);
    final list = _messages[normalized];
    if (list == null || list.isEmpty) {
      return;
    }
    final changed = _updateReactionsInList(list, sender, update);
    if (!changed) {
      return;
    }
    notifyListeners();
    _messagePersistor?.call(normalized, List.unmodifiable(list));
  }

  bool _applyMessageCorrection({
    required String bareJid,
    required String sender,
    required String replaceId,
    required String newBody,
    required String rawXml,
    required DateTime timestamp,
    String? oobUrl,
    String? oobDescription,
  }) {
    final normalized = _bareJid(bareJid);
    final list = _messages[normalized];
    if (list == null || list.isEmpty) {
      return false;
    }
    final applied = _applyCorrectionInList(
      list,
      sender: sender,
      replaceId: replaceId,
      newBody: newBody,
      oobUrl: oobUrl,
      oobDescription: oobDescription,
      rawXml: rawXml,
      timestamp: timestamp,
      matchSenderBare: true,
    );
    if (applied) {
      notifyListeners();
      _messagePersistor?.call(normalized, List.unmodifiable(list));
    }
    return applied;
  }

  bool _applyRoomMessageCorrection({
    required String roomJid,
    required String sender,
    required String replaceId,
    required String newBody,
    required String rawXml,
    required DateTime timestamp,
    String? oobUrl,
    String? oobDescription,
  }) {
    final normalized = _bareJid(roomJid);
    final list = _roomMessages[normalized];
    if (list == null || list.isEmpty) {
      return false;
    }
    final applied = _applyCorrectionInList(
      list,
      sender: sender,
      replaceId: replaceId,
      newBody: newBody,
      oobUrl: oobUrl,
      oobDescription: oobDescription,
      rawXml: rawXml,
      timestamp: timestamp,
      matchSenderBare: false,
    );
    if (applied) {
      notifyListeners();
      _roomMessagePersistor?.call(normalized, List.unmodifiable(list));
    }
    return applied;
  }

  bool _applyCorrectionInList(
    List<ChatMessage> list, {
    required String sender,
    required String replaceId,
    required String newBody,
    required String rawXml,
    required DateTime timestamp,
    required bool matchSenderBare,
    String? oobUrl,
    String? oobDescription,
  }) {
    for (var i = list.length - 1; i >= 0; i--) {
      final existing = list[i];
      if (existing.messageId != replaceId) {
        continue;
      }
      if (matchSenderBare) {
        if (_bareJid(existing.from) != _bareJid(sender)) {
          continue;
        }
      } else {
        if (existing.from != sender) {
          continue;
        }
      }
      final nextOobUrl = (oobUrl != null && oobUrl.isNotEmpty) ? oobUrl : existing.oobUrl;
      final nextRawXml = rawXml.isNotEmpty ? rawXml : existing.rawXml;
      final nextOobDescription = (oobDescription != null && oobDescription.isNotEmpty)
          ? oobDescription
          : existing.oobDescription;
      final nextEditedAt = timestamp;
      if (existing.body == newBody &&
          existing.oobUrl == nextOobUrl &&
          existing.oobDescription == nextOobDescription &&
          existing.rawXml == nextRawXml &&
          existing.edited &&
          existing.editedAt == nextEditedAt) {
        return true;
      }
      list[i] = ChatMessage(
        from: existing.from,
        to: existing.to,
        body: newBody,
        outgoing: existing.outgoing,
        timestamp: existing.timestamp,
        messageId: existing.messageId,
        mamId: existing.mamId,
        stanzaId: existing.stanzaId,
        oobUrl: nextOobUrl,
        oobDescription: nextOobDescription,
        rawXml: nextRawXml,
        inviteRoomJid: existing.inviteRoomJid,
        inviteReason: existing.inviteReason,
        invitePassword: existing.invitePassword,
        fileTransferId: existing.fileTransferId,
        fileName: existing.fileName,
        fileSize: existing.fileSize,
        fileMime: existing.fileMime,
        fileBytes: existing.fileBytes,
        fileState: existing.fileState,
        edited: true,
        editedAt: nextEditedAt,
        reactions: existing.reactions ?? const {},
        acked: existing.acked,
        receiptReceived: existing.receiptReceived,
        displayed: existing.displayed,
      );
      return true;
    }
    return false;
  }

  void _applyRoomReactionUpdate(
    String roomJid,
    String sender,
    String targetId,
    List<String> reactions,
  ) {
    final normalized = _bareJid(roomJid);
    final list = _roomMessages[normalized];
    if (list == null || list.isEmpty) {
      return;
    }
    final changed = _updateReactionsInList(
      list,
      sender,
      ReactionUpdate(targetId, reactions),
    );
    if (!changed) {
      return;
    }
    notifyListeners();
    _roomMessagePersistor?.call(normalized, List.unmodifiable(list));
  }

  bool _updateReactionsInList(
    List<ChatMessage> list,
    String sender,
    ReactionUpdate update,
  ) {
    if (sender.isEmpty || update.targetId.isEmpty) {
      return false;
    }
    for (var i = list.length - 1; i >= 0; i--) {
      final existing = list[i];
      if (existing.stanzaId != update.targetId &&
          existing.messageId != update.targetId) {
        continue;
      }
    final nextReactions =
        _nextReactions(existing.reactions ?? const {}, sender, update.reactions);
    if (_reactionsEqual(existing.reactions ?? const {}, nextReactions)) {
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
        oobDescription: existing.oobDescription,
        rawXml: existing.rawXml,
        fileTransferId: existing.fileTransferId,
        fileName: existing.fileName,
        fileSize: existing.fileSize,
        fileMime: existing.fileMime,
        fileBytes: existing.fileBytes,
        fileState: existing.fileState,
        edited: existing.edited,
        editedAt: existing.editedAt,
        reactions: nextReactions,
        acked: existing.acked,
        receiptReceived: existing.receiptReceived,
        displayed: existing.displayed,
      );
      return true;
    }
    return false;
  }

  Map<String, List<String>> _nextReactions(
    Map<String, List<String>> existing,
    String sender,
    List<String> reactions,
  ) {
    final next = <String, Set<String>>{};
    existing.forEach((emoji, senders) {
      final filtered = senders.where((value) => value.isNotEmpty && value != sender).toSet();
      if (filtered.isNotEmpty) {
        next[emoji] = filtered;
      }
    });
    for (final reaction in reactions) {
      if (reaction.isEmpty) {
        continue;
      }
      final set = next.putIfAbsent(reaction, () => <String>{});
      set.add(sender);
    }
    final result = <String, List<String>>{};
    for (final entry in next.entries) {
      final senders = entry.value.toList()..sort();
      if (senders.isNotEmpty) {
        result[entry.key] = senders;
      }
    }
    return result;
  }

  bool _reactionsEqual(
    Map<String, List<String>> a,
    Map<String, List<String>> b,
  ) {
    if (a.length != b.length) {
      return false;
    }
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || other.length != entry.value.length) {
        return false;
      }
      final sortedA = List<String>.from(entry.value)..sort();
      final sortedB = List<String>.from(other)..sort();
      for (var i = 0; i < sortedA.length; i += 1) {
        if (sortedA[i] != sortedB[i]) {
          return false;
        }
      }
    }
    return true;
  }

  String _serializeStanza(XmppElement stanza) {
    try {
      return stanza.buildXml().toXmlString(pretty: false);
    } catch (_) {
      return stanza.buildXmlString();
    }
  }

  Future<String?> _resolveHttpUploadServiceJid() async {
    final connection = _connection;
    if (connection == null) {
      return null;
    }
    if (_httpUploadServiceJid != null) {
      return _httpUploadServiceJid;
    }
    final features = connection.getSupportedFeatures();
    if (features.any((feature) => feature.xmppVar == httpUploadNamespace)) {
      _httpUploadServiceJid = connection.serverName.userAtDomain;
      return _httpUploadServiceJid;
    }
    final items = await _requestDiscoItems(connection.serverName.userAtDomain);
    for (final item in items) {
      final info = await _requestDiscoInfo(item);
      if (info != null && discoInfoSupportsHttpUpload(info)) {
        _httpUploadServiceJid = item;
        return _httpUploadServiceJid;
      }
    }
    return null;
  }

  Future<List<String>> _requestDiscoItems(String targetJid) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(targetJid);
    final query = XmppElement()..name = 'query';
    query.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'));
    iqStanza.addChild(query);
    final result = await _sendIqAndAwait(iqStanza);
    if (result == null || result.type != IqStanzaType.RESULT) {
      return const [];
    }
    final resultQuery = result.getChild('query');
    if (resultQuery == null ||
        resultQuery.getAttribute('xmlns')?.value != 'http://jabber.org/protocol/disco#items') {
      return const [];
    }
    final items = <String>[];
    for (final child in resultQuery.children) {
      if (child.name != 'item') {
        continue;
      }
      final jid = child.getAttribute('jid')?.value?.trim() ?? '';
      if (jid.isNotEmpty) {
        items.add(jid);
      }
    }
    return items;
  }

  Future<IqStanza?> _requestDiscoInfo(String targetJid) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(targetJid);
    final query = XmppElement()..name = 'query';
    query.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
    iqStanza.addChild(query);
    return _sendIqAndAwait(iqStanza);
  }

  Future<HttpUploadSlot?> _requestHttpUploadSlot({
    required String uploadService,
    required String fileName,
    required int size,
    String? contentType,
  }) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(uploadService);
    iqStanza.addChild(buildHttpUploadRequest(
      fileName: fileName,
      size: size,
      contentType: contentType,
    ));
    final result = await _sendIqAndAwait(iqStanza);
    if (result == null) {
      return null;
    }
    return HttpUploadSlot.fromIq(result);
  }

  Future<bool> _uploadToSlot({
    required HttpUploadSlot slot,
    required Uint8List bytes,
    String? contentType,
  }) async {
    final headers = Map<String, String>.from(slot.putHeaders);
    if (contentType != null &&
        contentType.isNotEmpty &&
        !_hasHeader(headers, 'content-type')) {
      headers['Content-Type'] = contentType;
    }
    try {
      final response = await http.put(slot.putUrl, headers: headers, body: bytes);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  bool _hasHeader(Map<String, String> headers, String name) {
    final target = name.toLowerCase();
    return headers.keys.any((key) => key.toLowerCase() == target);
  }

  MessageStanza _buildOobMessageStanza({
    required String targetJid,
    required String messageId,
    required String url,
    String? description,
    required bool isRoom,
  }) {
    final stanza = MessageStanza(
      messageId,
      isRoom ? MessageStanzaType.GROUPCHAT : MessageStanzaType.CHAT,
    );
    stanza.toJid = Jid.fromFullJid(targetJid);
    if (!isRoom) {
      stanza.fromJid = _connection?.fullJid;
    }
    stanza.body = url;
    final oob = XmppElement()..name = 'x';
    oob.addAttribute(XmppAttribute('xmlns', 'jabber:x:oob'));
    final urlElement = XmppElement()..name = 'url';
    urlElement.textValue = url;
    oob.addChild(urlElement);
    final trimmedDescription = description?.trim();
    if (trimmedDescription != null && trimmedDescription.isNotEmpty) {
      final descElement = XmppElement()..name = 'desc';
      descElement.textValue = trimmedDescription;
      oob.addChild(descElement);
    }
    stanza.addChild(oob);
    final fallback = XmppElement()..name = 'fallback';
    fallback.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:fallback:0'));
    final bodyFallback = XmppElement()..name = 'body';
    fallback.addChild(bodyFallback);
    stanza.addChild(fallback);
    if (!isRoom) {
      final receiptRequest = XmppElement()..name = 'request';
      receiptRequest.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:receipts'),
      );
      stanza.addChild(receiptRequest);
      final markable = XmppElement()..name = 'markable';
      markable.addAttribute(
        XmppAttribute('xmlns', 'urn:xmpp:chat-markers:0'),
      );
      stanza.addChild(markable);
    }
    return stanza;
  }

  Future<IqStanza?> _sendIqAndAwait(
    IqStanza stanza, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final connection = _connection;
    final id = stanza.id;
    if (connection == null || id == null || id.isEmpty) {
      return null;
    }
    final router = IqRouter.getInstance(connection);
    final completer = Completer<IqStanza?>();
    Timer? timer;
    timer = Timer(timeout, () {
      router.unregisterResponseHandler(id);
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });
    router.registerResponseHandler(id, (response) {
      timer?.cancel();
      if (!completer.isCompleted) {
        completer.complete(response);
      }
    });
    connection.writeStanza(stanza);
    return completer.future;
  }

  String _buildOutgoingGroupStanzaXml(String roomJid, String messageId, String body) {
    final stanza = MessageStanza(messageId, MessageStanzaType.GROUPCHAT);
    stanza.toJid = Jid.fromFullJid(roomJid);
    stanza.body = body;
    return _serializeStanza(stanza);
  }

  XmppElement _buildReplaceElement(String replaceId) {
    final replace = XmppElement()..name = 'replace';
    replace.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:message-correct:0'));
    replace.addAttribute(XmppAttribute('id', replaceId));
    return replace;
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
      final fullJid = presence.jid?.fullJid;
      final normalized = _bareJid(jid);
      _presenceByBareJid[normalized] = presence;
      final status = presence.status?.toLowerCase();
      if (fullJid != null && fullJid.isNotEmpty) {
        if (status == 'unavailable') {
          _presenceByFullJid.remove(fullJid);
        } else {
          _presenceByFullJid[fullJid] = presence;
        }
      }
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
      onUpdate: () {
        _handlePepAvatarUpdate();
        notifyListeners();
      },
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
        if (_bookmarksSpan != null) {
          _finishSpan(_bookmarksSpan);
          _bookmarksSpan = null;
        }
        _bookmarks
          ..clear()
          ..addAll(bookmarks);
        _bookmarkPersistor?.call(List.unmodifiable(_bookmarks));
        _autojoinRooms();
        notifyListeners();
      },
    );
    _bookmarksManager?.seedBookmarks(_bookmarks);
    _bookmarksSpan = _startSpan(_connectTransaction, 'xmpp.bookmarks.fetch');
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

  void _handlePepAvatarUpdate() {
    final selfBareJid = _currentUserBareJid;
    if (selfBareJid == null) {
      return;
    }
    final hash = _pepManager?.avatarHashFor(selfBareJid) ?? '';
    if (hash == _lastSelfAvatarHash) {
      return;
    }
    _lastSelfAvatarHash = hash;
    if (_pepVcardConversionSupported) {
      _sendDirectedPresenceToJoinedRooms();
    }
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

  void _setupBlocking() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    if (_blockingSupported) {
      _registerBlockingHandler(connection);
      _refreshBlockingList();
      return;
    }
    _setupPrivacyLists();
  }

  void _registerBlockingHandler(Connection connection) {
    if (_blockingHandlerRegistered) {
      return;
    }
    _blockingHandlerRegistered = true;
    final router = IqRouter.getInstance(connection);
    router.registerNamespaceHandler(blockingNamespace, _handleBlockingIq);
  }

  Future<IqStanza?> _handleBlockingIq(IqStanza request) async {
    if (request.type != IqStanzaType.GET && request.type != IqStanzaType.SET) {
      return null;
    }
    final response = IqStanza(request.id, IqStanzaType.RESULT);
    if (request.type == IqStanzaType.GET) {
      final blocklist = XmppElement()..name = 'blocklist';
      blocklist.addAttribute(XmppAttribute('xmlns', blockingNamespace));
      for (final jid in _blockedJids) {
        final item = XmppElement()..name = 'item';
        item.addAttribute(XmppAttribute('jid', jid));
        blocklist.addChild(item);
      }
      response.addChild(blocklist);
      return response;
    }
    final update = parseBlockingUpdate(request);
    if (update == null) {
      return response;
    }
    if (update.isBlock) {
      _blockedJids.addAll(update.items);
    } else {
      if (update.items.isEmpty) {
        _blockedJids.clear();
      } else {
        _blockedJids.removeAll(update.items);
      }
    }
    notifyListeners();
    return response;
  }

  Future<void> _refreshBlockingList() async {
    final list = await _requestBlocklist();
    if (list == null) {
      return;
    }
    _blockedJids
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  Future<List<String>?> _requestBlocklist() async {
    final connection = _connection;
    if (connection == null) {
      return null;
    }
    final id = AbstractStanza.getRandomId();
    final iq = IqStanza(id, IqStanzaType.GET);
    iq.toJid = Jid.fromFullJid(connection.serverName.userAtDomain);
    final blocklist = XmppElement()..name = 'blocklist';
    blocklist.addAttribute(XmppAttribute('xmlns', blockingNamespace));
    iq.addChild(blocklist);
    final result = await _sendIqAndAwait(iq);
    if (result == null) {
      return null;
    }
    return parseBlocklistIq(result);
  }

  Future<bool> _sendBlock(String bareJid) async {
    final connection = _connection;
    if (connection == null) {
      return false;
    }
    final id = AbstractStanza.getRandomId();
    final iq = IqStanza(id, IqStanzaType.SET);
    iq.toJid = Jid.fromFullJid(connection.serverName.userAtDomain);
    final block = XmppElement()..name = 'block';
    block.addAttribute(XmppAttribute('xmlns', blockingNamespace));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('jid', bareJid));
    block.addChild(item);
    iq.addChild(block);
    final result = await _sendIqAndAwait(iq);
    return result?.type == IqStanzaType.RESULT;
  }

  Future<bool> _sendUnblock(String bareJid) async {
    final connection = _connection;
    if (connection == null) {
      return false;
    }
    final id = AbstractStanza.getRandomId();
    final iq = IqStanza(id, IqStanzaType.SET);
    iq.toJid = Jid.fromFullJid(connection.serverName.userAtDomain);
    final unblock = XmppElement()..name = 'unblock';
    unblock.addAttribute(XmppAttribute('xmlns', blockingNamespace));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('jid', bareJid));
    unblock.addChild(item);
    iq.addChild(unblock);
    final result = await _sendIqAndAwait(iq);
    return result?.type == IqStanzaType.RESULT;
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
      if (nonza.name == 'enabled' && xmlns == 'urn:xmpp:sm:3') {
        _resetStreamManagementCounters();
        return;
      }
      if (nonza.name == 'error' &&
          xmlns == 'http://etherx.jabber.org/streams') {
        _handleStreamError(nonza);
        return;
      }
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
        final selfPingRoom = _pendingMucSelfPings.remove(stanza.id);
        if (selfPingRoom != null) {
          final timer = _mucSelfPingTimeouts.remove(stanza.id);
          timer?.cancel();
          _handleMucSelfPingResponse(selfPingRoom, stanza);
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

  void _resetStreamManagementCounters() {
    final streamManagement = _connection?.streamManagementModule;
    if (streamManagement == null) {
      return;
    }
    streamManagement.streamState.lastSentStanza = 0;
    streamManagement.streamState.lastReceivedStanza = 0;
    streamManagement.streamState.nonConfirmedSentStanzas.clear();
    streamManagement.streamState.tryingToResume = false;
    _pendingSmAckAt = null;
    _lastSmAckRequestAt = null;
    _smAckTimeoutTimer?.cancel();
    _smAckTimeoutTimer = null;
  }

  Future<void> _handleStreamError(Nonza nonza) async {
    Log.w('XmppService', 'Stream error received: ${nonza.name}');
    await _safeClose(preserveCache: true);
    _setError('Stream error');
    _scheduleReconnect(immediate: true, shortTimeout: true);
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
        final oobInfo = _extractOobInfoFromStanza(message.messageStanza);
        final oobUrl = oobInfo?.url;
        final oobDescription = oobInfo?.description;
        final rawXml = _serializeStanza(message.messageStanza);
        final replaceId = _extractReplaceIdFromStanza(message.messageStanza);
        final reaction = _extractReactionUpdate(message.messageStanza);
        if (reaction != null) {
          final targetBare = _reactionChatTarget(from, to);
          if (targetBare.isNotEmpty) {
            _applyReactionUpdate(targetBare, from, reaction);
          }
          continue;
        }
        if (body.trim().isEmpty && (oobUrl == null || oobUrl.isEmpty)) {
          continue;
        }
        final outgoing = from == (_currentUserBareJid ?? '');
        final targetBare = outgoing ? to : from;
        if (replaceId != null && replaceId.isNotEmpty && targetBare.isNotEmpty) {
          final applied = _applyMessageCorrection(
            bareJid: targetBare,
            sender: from,
            replaceId: replaceId,
            newBody: body,
            oobUrl: oobUrl,
            oobDescription: oobDescription,
            rawXml: rawXml,
            timestamp: message.time,
          );
          if (applied) {
            continue;
          }
        }
        _addMessage(
          bareJid: targetBare,
          from: from,
          to: to,
          body: body,
          rawXml: rawXml,
          oobUrl: oobUrl,
          oobDescription: oobDescription,
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
      final oobInfo = _extractOobInfoFromStanza(message.messageStanza);
      final oobUrl = oobInfo?.url;
      final oobDescription = oobInfo?.description;
      final rawXml = _serializeStanza(message.messageStanza);
      final replaceId = _extractReplaceIdFromStanza(message.messageStanza);
      final reaction = _extractReactionUpdate(message.messageStanza);
      final invite = parseMucDirectInvite(message.messageStanza);
      final outgoing = from == (_currentUserBareJid ?? '');
      final targetBare = outgoing ? to : from;
      if (replaceId != null && replaceId.isNotEmpty && targetBare.isNotEmpty) {
        final applied = _applyMessageCorrection(
          bareJid: targetBare,
          sender: from,
          replaceId: replaceId,
          newBody: body,
          oobUrl: oobUrl,
          oobDescription: oobDescription,
          rawXml: rawXml,
          timestamp: message.time,
        );
        if (applied) {
          return;
        }
      }
      if (reaction != null) {
        final targetBare = _reactionChatTarget(from, to);
        if (targetBare.isNotEmpty) {
          _applyReactionUpdate(targetBare, from, reaction);
        }
        return;
      }
      if (body.trim().isEmpty &&
          (oobUrl == null || oobUrl.isEmpty) &&
          invite == null) {
        return;
      }
      _addMessage(
        bareJid: targetBare,
        from: from,
        to: to,
        body: body,
        rawXml: rawXml,
        oobUrl: oobUrl,
        oobDescription: oobDescription,
        outgoing: outgoing,
        timestamp: message.time,
        messageId: message.messageId,
        mamId: message.mamResultId,
        stanzaId: message.stanzaId,
        inviteRoomJid: invite?.roomJid,
        inviteReason: invite?.reason,
        invitePassword: invite?.password,
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
    String? oobDescription,
    String? inviteRoomJid,
    String? inviteReason,
    String? invitePassword,
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
        final nextOobDescription = (oobDescription != null && oobDescription.isNotEmpty)
            ? oobDescription
            : existing.oobDescription;
        final nextInviteRoomJid =
            (inviteRoomJid != null && inviteRoomJid.isNotEmpty) ? inviteRoomJid : existing.inviteRoomJid;
        final nextInviteReason =
            (inviteReason != null && inviteReason.isNotEmpty) ? inviteReason : existing.inviteReason;
        final nextInvitePassword =
            (invitePassword != null && invitePassword.isNotEmpty) ? invitePassword : existing.invitePassword;
        if (nextMamId != existing.mamId ||
            nextStanzaId != existing.stanzaId ||
            nextOobUrl != existing.oobUrl ||
            nextRawXml != existing.rawXml ||
            nextOobDescription != existing.oobDescription ||
            nextInviteRoomJid != existing.inviteRoomJid ||
            nextInviteReason != existing.inviteReason ||
            nextInvitePassword != existing.invitePassword) {
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
            oobDescription: nextOobDescription,
            rawXml: nextRawXml,
            inviteRoomJid: nextInviteRoomJid,
            inviteReason: nextInviteReason,
            invitePassword: nextInvitePassword,
            fileTransferId: existing.fileTransferId,
            fileName: existing.fileName,
            fileSize: existing.fileSize,
            fileMime: existing.fileMime,
            fileBytes: existing.fileBytes,
            fileState: existing.fileState,
            edited: existing.edited,
            editedAt: existing.editedAt,
            reactions: existing.reactions ?? const {},
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
        oobDescription: oobDescription,
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
          oobDescription: oobDescription,
          rawXml: rawXml,
          reactions: const {},
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
      oobDescription: oobDescription,
      rawXml: rawXml,
      reactions: const {},
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
    String? oobDescription,
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
        final nextOobDescription = (oobDescription != null && oobDescription.isNotEmpty)
            ? oobDescription
            : existing.oobDescription;
        if (nextMamId != existing.mamId ||
            nextStanzaId != existing.stanzaId ||
            nextReceiptReceived != existing.receiptReceived ||
            nextTimestamp != existing.timestamp ||
            nextOobUrl != existing.oobUrl ||
            nextOobDescription != existing.oobDescription ||
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
            oobDescription: nextOobDescription,
            rawXml: nextRawXml,
            fileTransferId: existing.fileTransferId,
            fileName: existing.fileName,
            fileSize: existing.fileSize,
            fileMime: existing.fileMime,
            fileBytes: existing.fileBytes,
            fileState: existing.fileState,
            edited: existing.edited,
            editedAt: existing.editedAt,
            reactions: existing.reactions ?? const {},
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
          oobDescription: oobDescription,
          rawXml: rawXml,
          reactions: const {},
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
      oobDescription: oobDescription,
      rawXml: rawXml,
      reactions: const {},
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

  void _addFileTransferMessage({
    required String bareJid,
    required _FileTransferSession session,
    required bool outgoing,
    required String rawXml,
    required String state,
  }) {
    _fileTransferStateBySid[session.sid] = state;
    final normalized = _bareJid(bareJid);
    final list = _messages.putIfAbsent(normalized, () => <ChatMessage>[]);
    final message = ChatMessage(
      from: outgoing ? (_currentUserBareJid ?? normalized) : normalized,
      to: outgoing ? normalized : (_currentUserBareJid ?? normalized),
      body: '',
      outgoing: outgoing,
      timestamp: DateTime.now(),
      messageId: session.sid,
      rawXml: rawXml,
      fileTransferId: session.sid,
      fileName: session.fileName,
      fileSize: session.fileSize,
      fileMime: session.fileMime,
      fileBytes: session.bytesTransferred,
      fileState: state,
      reactions: const {},
    );
    _insertMessageOrdered(list, message);
    notifyListeners();
    _messagePersistor?.call(normalized, List.unmodifiable(list));
    if (!outgoing) {
      _incomingMessageHandler?.call(normalized, message);
    }
  }

  void _updateFileTransferMessage({
    required String bareJid,
    required String transferId,
    String? state,
    int? fileBytes,
  }) {
    if (state != null) {
      _fileTransferStateBySid[transferId] = state;
    }
    final normalized = _bareJid(bareJid);
    final list = _messages[normalized];
    if (list == null || list.isEmpty) {
      return;
    }
    for (var i = list.length - 1; i >= 0; i--) {
      final existing = list[i];
      if (existing.fileTransferId != transferId &&
          existing.messageId != transferId) {
        continue;
      }
      final nextState = state ?? existing.fileState;
      final nextBytes = fileBytes ?? existing.fileBytes;
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
        oobDescription: existing.oobDescription,
        rawXml: existing.rawXml,
        inviteRoomJid: existing.inviteRoomJid,
        inviteReason: existing.inviteReason,
        invitePassword: existing.invitePassword,
        fileTransferId: existing.fileTransferId,
        fileName: existing.fileName,
        fileSize: existing.fileSize,
        fileMime: existing.fileMime,
        fileBytes: nextBytes,
        fileState: nextState,
        edited: existing.edited,
        editedAt: existing.editedAt,
        reactions: existing.reactions ?? const {},
        acked: existing.acked,
        receiptReceived: existing.receiptReceived,
        displayed: existing.displayed,
      );
      notifyListeners();
      _messagePersistor?.call(normalized, List.unmodifiable(list));
      return;
    }
  }

  Future<void> _sendIbbData(_FileTransferSession session) async {
    final ibb = _ibbManager;
    if (ibb == null) {
      _updateFileTransferMessage(
        bareJid: session.peerBareJid,
        transferId: session.sid,
        state: _fileTransferStateFailed,
      );
      return;
    }
    final bytes = session.bytes;
    if (bytes == null || bytes.isEmpty) {
      return;
    }
    final target = Jid.fromFullJid(session.peerBareJid);
    final opened = await ibb.sendOpen(
      to: target,
      sid: session.ibbSid,
      blockSize: session.blockSize,
    );
    if (!opened) {
      _updateFileTransferMessage(
        bareJid: session.peerBareJid,
        transferId: session.sid,
        state: _fileTransferStateFailed,
      );
      await _sendJingleTerminate(target, session.sid, 'failed-application');
      return;
    }
    session.bytesTransferred = 0;
    _updateFileTransferMessage(
      bareJid: session.peerBareJid,
      transferId: session.sid,
      state: _fileTransferStateInProgress,
      fileBytes: session.bytesTransferred,
    );
    var seq = 0;
    for (var offset = 0; offset < bytes.length; offset += session.blockSize) {
      final end = (offset + session.blockSize).clamp(0, bytes.length);
      final chunk = bytes.sublist(offset, end);
      final sent = await ibb.sendData(
        to: target,
        sid: session.ibbSid,
        seq: seq,
        bytes: chunk,
      );
      if (!sent) {
        _updateFileTransferMessage(
          bareJid: session.peerBareJid,
          transferId: session.sid,
          state: _fileTransferStateFailed,
        );
        await _sendJingleTerminate(target, session.sid, 'failed-application');
        return;
      }
      seq += 1;
      session.bytesTransferred += chunk.length;
      _updateFileTransferMessage(
        bareJid: session.peerBareJid,
        transferId: session.sid,
        state: _fileTransferStateInProgress,
        fileBytes: session.bytesTransferred,
      );
    }
    await ibb.sendClose(to: target, sid: session.ibbSid);
    _updateFileTransferMessage(
      bareJid: session.peerBareJid,
      transferId: session.sid,
      state: _fileTransferStateCompleted,
      fileBytes: session.bytesTransferred,
    );
    await _sendJingleTerminate(target, session.sid, 'success');
    _finalizeTransfer(session);
  }

  Future<void> _sendJingleTerminate(Jid to, String sid, String reason) async {
    final jingle = _jingleManager;
    if (jingle == null) {
      return;
    }
    final iq = jingle.buildSessionTerminate(to: to, sid: sid, reason: reason);
    await _sendIqAndAwait(iq);
  }

  String? _iqErrorCondition(IqStanza stanza) {
    final error = stanza.getChild('error');
    if (error == null) {
      return null;
    }
    for (final child in error.children) {
      if (child.getAttribute('xmlns')?.value ==
          'urn:ietf:params:xml:ns:xmpp-stanzas') {
        return child.name;
      }
    }
    return null;
  }

  bool _isJingleUnsupportedError(String? condition) {
    switch (condition) {
      case 'feature-not-implemented':
      case 'service-unavailable':
      case 'item-not-found':
      case 'not-acceptable':
        return true;
    }
    return false;
  }

  _FileTransferSession? _findTransferByIbbSid(String ibbSid) {
    for (final session in _fileTransfers.values) {
      if (session.ibbSid == ibbSid) {
        return session;
      }
    }
    return null;
  }

  void _finalizeTransfer(_FileTransferSession session) {
    if (session.sink != null) {
      session.sink!.close();
      session.sink = null;
    }
    _fileTransfers.remove(session.sid);
    final span = _fileTransferTransactions.remove(session.sid);
    if (span != null) {
      final state = _fileTransferStateBySid.remove(session.sid) ?? '';
      final status = switch (state) {
        _fileTransferStateCompleted => const SpanStatus.ok(),
        _fileTransferStateDeclined => const SpanStatus.cancelled(),
        _fileTransferStateFailed => const SpanStatus.internalError(),
        _ => const SpanStatus.ok(),
      };
      _finishSpan(span, status: status);
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
        oobDescription: existing.oobDescription,
        rawXml: existing.rawXml,
        fileTransferId: existing.fileTransferId,
        fileName: existing.fileName,
        fileSize: existing.fileSize,
        fileMime: existing.fileMime,
        fileBytes: existing.fileBytes,
        fileState: existing.fileState,
        edited: existing.edited,
        editedAt: existing.editedAt,
        reactions: existing.reactions ?? const {},
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
        oobDescription: existing.oobDescription,
        rawXml: existing.rawXml,
        fileTransferId: existing.fileTransferId,
        fileName: existing.fileName,
        fileSize: existing.fileSize,
        fileMime: existing.fileMime,
        fileBytes: existing.fileBytes,
        fileState: existing.fileState,
        edited: existing.edited,
        editedAt: existing.editedAt,
        reactions: existing.reactions ?? const {},
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
    String? oobDescription,
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
        final nextOobDescription = (oobDescription != null && oobDescription.isNotEmpty)
            ? oobDescription
            : existing.oobDescription;
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
          oobDescription: nextOobDescription,
          rawXml: nextRawXml,
          fileTransferId: existing.fileTransferId,
          fileName: existing.fileName,
          fileSize: existing.fileSize,
          fileMime: existing.fileMime,
          fileBytes: existing.fileBytes,
          fileState: existing.fileState,
          edited: existing.edited,
          editedAt: existing.editedAt,
          reactions: existing.reactions ?? const {},
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
        oobDescription: existing.oobDescription,
        rawXml: existing.rawXml,
        fileTransferId: existing.fileTransferId,
        fileName: existing.fileName,
        fileSize: existing.fileSize,
        fileMime: existing.fileMime,
        fileBytes: existing.fileBytes,
        fileState: existing.fileState,
        edited: existing.edited,
        editedAt: existing.editedAt,
        reactions: existing.reactions ?? const {},
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
    _mucSelfPingTimer?.cancel();
    _mucSelfPingTimer = null;
    for (final timer in _mucSelfPingTimeouts.values) {
      timer.cancel();
    }
    _mucSelfPingTimeouts.clear();
    _pendingMucSelfPings.clear();
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
    _mucPresenceSubscription?.cancel();
    _mucPresenceSubscription = null;
    _jingleSubscription?.cancel();
    _jingleSubscription = null;
    _ibbOpenSubscription?.cancel();
    _ibbOpenSubscription = null;
    _ibbDataSubscription?.cancel();
    _ibbDataSubscription = null;
    _ibbCloseSubscription?.cancel();
    _ibbCloseSubscription = null;
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
    _roomLastTrafficAt.clear();
    _roomLastPingAt.clear();
    _mucDefaultConfigSent.clear();
    _blockingHandlerRegistered = false;
    _selfVcardPhotoHash = '';
    _selfVcardPhotoKnown = false;

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
    _presenceByFullJid.clear();
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
    _jingleManager = null;
    _ibbManager = null;
    for (final session in _fileTransfers.values) {
      session.sink?.close();
    }
    _blockedJids.clear();
    _vcardAvatarBytes.clear();
    _vcardRequests.clear();
    _vcardUnavailable.clear();
    _fileTransfers.clear();

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

  String _callPeerKeyForJid(String jid) {
    final parsed = Jid.fromFullJid(jid);
    final bare = _bareJid(parsed.userAtDomain);
    final resource = parsed.resource;
    if (resource != null &&
        resource.isNotEmpty &&
        _mujiSessions.containsKey(bare)) {
      return '$bare/$resource';
    }
    return bare;
  }

  bool _isMujiParticipantJid(String jid) {
    final parsed = Jid.fromFullJid(jid);
    final resource = parsed.resource;
    if (resource == null || resource.isEmpty) {
      return false;
    }
    final bare = _bareJid(parsed.userAtDomain);
    return _mujiSessions.containsKey(bare);
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

  void _primeSelfVcardHash() {
    final selfBareJid = _currentUserBareJid;
    if (selfBareJid == null || selfBareJid.isEmpty) {
      return;
    }
    final state = _vcardAvatarState[selfBareJid];
    if (state == _vcardNoAvatar) {
      _selfVcardPhotoHash = '';
      _selfVcardPhotoKnown = true;
      return;
    }
    if (state != null && state.isNotEmpty) {
      _selfVcardPhotoHash = state;
      _selfVcardPhotoKnown = true;
      return;
    }
    final bytes = _vcardAvatarBytes[selfBareJid];
    if (bytes != null && bytes.isNotEmpty) {
      vcardPhotoHash(bytes).then((hash) {
        _selfVcardPhotoHash = hash;
        _selfVcardPhotoKnown = true;
      });
    }
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
    stanza.addChild(_buildVcardUpdateElement());
    connection.writeStanza(stanza);
    _sendDirectedPresenceToJoinedRooms();
  }

  XmppElement _buildCapsElement() {
    final caps = XmppElement()..name = 'c';
    caps.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/caps'));
    caps.addAttribute(XmppAttribute('hash', _capsHash));
    caps.addAttribute(XmppAttribute('node', _capsNode));
    caps.addAttribute(XmppAttribute('ver', _capsVerValue()));
    return caps;
  }

  XmppElement _buildVcardUpdateElement() {
    final update = XmppElement()..name = 'x';
    update.addAttribute(XmppAttribute('xmlns', 'vcard-temp:x:update'));
    final hash = _selfVcardPhotoHash.trim();
    if (hash.isNotEmpty || _selfVcardPhotoKnown) {
      final photo = XmppElement()..name = 'photo';
      if (hash.isNotEmpty) {
        photo.textValue = hash;
      }
      update.addChild(photo);
    }
    return update;
  }

  void _sendDirectedPresenceToJoinedRooms() {
    final selfBareJid = _currentUserBareJid;
    if (selfBareJid == null) {
      return;
    }
    for (final entry in _rooms.values) {
      if (entry.joined && entry.nick != null && entry.nick!.isNotEmpty) {
        _sendDirectedPresenceToRoom(entry.roomJid, entry.nick!);
      }
    }
  }

  void _sendDirectedPresenceToRoom(String roomJid, String nick) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final stanza = PresenceStanza();
    stanza.toJid = Jid.fromFullJid('${_bareJid(roomJid)}/$nick');
    stanza.show = _selfPresence.showElement;
    stanza.status = _selfPresence.status;
    stanza.addChild(_buildCapsElement());
    stanza.addChild(_buildVcardUpdateElement());
    connection.writeStanza(stanza);
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
    _mamSyncTransaction ??= _startLinkedTransaction(
      'xmpp.mam.sync',
      'xmpp.mam',
      _connectTransaction,
    );
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
    _finishMamSyncIfIdle();
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
      _finishMamSyncIfIdle();
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
        _finishMamSyncIfIdle();
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
    _requestVcardDetails(bareJid, preferName: false);
  }

  void _requestVcardDetails(String bareJid, {required bool preferName}) {
    final connection = _connection;
    final storage = _storage;
    if (connection == null || storage == null) {
      return;
    }
    if (_vcardUnavailable.contains(bareJid)) {
      return;
    }
    if (_vcardRequests.contains(bareJid)) {
      return;
    }
    _vcardRequests.add(bareJid);
    final manager = VCardManager.getInstance(connection);
    manager.getVCardFor(Jid.fromFullJid(bareJid)).then((vcard) async {
      _vcardRequests.remove(bareJid);
      if (vcard is InvalidVCard) {
        _vcardUnavailable.add(bareJid);
        return;
      }
      _vcardUnavailable.remove(bareJid);
      _applyVcardToContact(bareJid, vcard, preferName: preferName);
      final bytes = vcard.imageData;
      if (bytes is List<int> && bytes.isNotEmpty) {
        final data = base64Encode(bytes);
        _vcardAvatarBytes[bareJid] = Uint8List.fromList(bytes);
        storage.storeVcardAvatar(bareJid, data);
        final hash = await vcardPhotoHash(Uint8List.fromList(bytes));
        _vcardAvatarState[bareJid] = hash;
        storage.storeVcardAvatarState(bareJid, hash);
        notifyListeners();
      } else {
        _vcardAvatarBytes.remove(bareJid);
        _vcardAvatarState[bareJid] = _vcardNoAvatar;
        storage.storeVcardAvatarState(bareJid, _vcardNoAvatar);
        storage.removeVcardAvatar(bareJid);
        notifyListeners();
      }
    }).catchError((_) {
      _vcardRequests.remove(bareJid);
    });
  }

  void _applyVcardToContact(String bareJid, VCard vcard, {required bool preferName}) {
    if (!preferName) {
      return;
    }
    final name = vcardDisplayName(vcard);
    if (name.isEmpty) {
      return;
    }
    final index = _contacts.indexWhere((entry) => entry.jid == bareJid);
    if (index == -1) {
      return;
    }
    final existing = _contacts[index];
    if (existing.name != null && existing.name!.trim().isNotEmpty) {
      return;
    }
    _contacts[index] = existing.copyWith(name: name);
    _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
    notifyListeners();
    _rosterPersistor?.call(List.unmodifiable(_contacts));
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
    _vcardUnavailable.remove(bareJid);
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

  Future<String?> updateSelfVcard({
    required String displayName,
    Uint8List? avatarBytes,
    String? avatarMimeType,
    bool clearAvatar = false,
  }) async {
    final connection = _connection;
    final storage = _storage;
    final selfBareJid = _currentUserBareJid;
    if (connection == null || storage == null || selfBareJid == null) {
      return 'Not connected.';
    }
    final name = displayName.trim();
    final bytes = clearAvatar ? null : avatarBytes;
    final vcard = buildVcardElement(
      displayName: name,
      avatarBytes: bytes,
      avatarMimeType: avatarMimeType,
    );
    final iq = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.SET);
    iq.toJid = Jid.fromFullJid(selfBareJid);
    iq.addChild(vcard);
    final result = await _sendIqAndAwait(iq);
    if (result?.type != IqStanzaType.RESULT) {
      return 'Failed to publish vCard.';
    }
    if (name.isNotEmpty) {
      _applySelfDisplayName(name);
    }
    if (bytes != null && bytes.isNotEmpty) {
      final hash = await vcardPhotoHash(bytes);
      _selfVcardPhotoHash = hash;
      _selfVcardPhotoKnown = true;
      _vcardAvatarBytes[selfBareJid] = bytes;
      storage.storeVcardAvatar(selfBareJid, base64Encode(bytes));
      _vcardAvatarState[selfBareJid] = hash;
      storage.storeVcardAvatarState(selfBareJid, hash);
    } else if (clearAvatar) {
      _selfVcardPhotoHash = '';
      _selfVcardPhotoKnown = true;
      _vcardAvatarBytes.remove(selfBareJid);
      _vcardAvatarState[selfBareJid] = _vcardNoAvatar;
      storage.storeVcardAvatarState(selfBareJid, _vcardNoAvatar);
      storage.removeVcardAvatar(selfBareJid);
    }
    _sendPresence(_selfPresence);
    notifyListeners();
    return null;
  }

  void _applySelfDisplayName(String name) {
    final selfBareJid = _currentUserBareJid;
    if (selfBareJid == null) {
      return;
    }
    final index = _contacts.indexWhere((entry) => entry.jid == selfBareJid);
    if (index == -1) {
      _contacts.add(ContactEntry(jid: selfBareJid, name: name));
    } else {
      final existing = _contacts[index];
      _contacts[index] = existing.copyWith(name: name);
    }
    _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
    _rosterPersistor?.call(List.unmodifiable(_contacts));
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

  void _sendMucDefaultConfig(String roomJid) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final iq = buildMucDefaultConfigIq(roomJid);
    connection.writeStanza(iq);
  }


  Duration _smAckTimeout({required bool shortTimeout}) {
    final base = _lastPingLatency ?? Duration.zero;
    final multiplier = shortTimeout ? 5 : 10;
    final scaled = base * multiplier;
    final floor = Duration(seconds: shortTimeout ? 5 : 10);
    final candidate = scaled > floor ? scaled : floor;
    return candidate > _keepaliveMaxTimeout ? _keepaliveMaxTimeout : candidate;
  }

  Duration _pingTimeout({required bool shortTimeout}) {
    final base = _lastPingLatency ?? Duration.zero;
    final multiplier = shortTimeout ? 5 : 10;
    final scaled = base * multiplier;
    final floor = Duration(seconds: shortTimeout ? 5 : 10);
    final candidate = scaled > floor ? scaled : floor;
    return candidate > _keepaliveMaxTimeout ? _keepaliveMaxTimeout : candidate;
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

class _FileTransferSession {
  _FileTransferSession({
    required this.sid,
    required this.peerBareJid,
    required this.ibbSid,
    required this.blockSize,
    required this.fileName,
    required this.fileSize,
    required this.incoming,
    this.fileMime,
    this.bytes,
  });

  factory _FileTransferSession.incoming({
    required String sid,
    required String peerBareJid,
    required String ibbSid,
    required int blockSize,
    required String fileName,
    required int fileSize,
    String? fileMime,
  }) {
    return _FileTransferSession(
      sid: sid,
      peerBareJid: peerBareJid,
      ibbSid: ibbSid,
      blockSize: blockSize,
      fileName: fileName,
      fileSize: fileSize,
      fileMime: fileMime,
      incoming: true,
    );
  }

  factory _FileTransferSession.outgoing({
    required String sid,
    required String peerBareJid,
    required String ibbSid,
    required int blockSize,
    required String fileName,
    required int fileSize,
    String? fileMime,
    required Uint8List bytes,
  }) {
    return _FileTransferSession(
      sid: sid,
      peerBareJid: peerBareJid,
      ibbSid: ibbSid,
      blockSize: blockSize,
      fileName: fileName,
      fileSize: fileSize,
      fileMime: fileMime,
      incoming: false,
      bytes: bytes,
    );
  }

  final String sid;
  final String peerBareJid;
  final String ibbSid;
  int blockSize;
  final String fileName;
  final int fileSize;
  final String? fileMime;
  final bool incoming;
  final Uint8List? bytes;
  int bytesTransferred = 0;
  String? savePath;
  IOSink? sink;
}

class ReactionUpdate {
  ReactionUpdate(this.targetId, this.reactions);

  final String targetId;
  final List<String> reactions;
}

class MessageScopedId {
  const MessageScopedId({required this.scopeJid, required this.id});

  final String scopeJid;
  final String id;
}

abstract class MessageIntent {
  const MessageIntent();
}

class HandleJmiIntent extends MessageIntent {
  const HandleJmiIntent({required this.action});

  final JmiAction action;
}

class ApplyReceiptIntent extends MessageIntent {
  const ApplyReceiptIntent({required this.scopedId});

  final MessageScopedId scopedId;
}

class ApplyDisplayedIntent extends MessageIntent {
  const ApplyDisplayedIntent({required this.scopedId});

  final MessageScopedId scopedId;
}

class ApplyReactionIntent extends MessageIntent {
  const ApplyReactionIntent({
    required this.targetBareJid,
    required this.senderBareJid,
    required this.update,
  });

  final String targetBareJid;
  final String senderBareJid;
  final ReactionUpdate update;
}

class SendReceiptIntent extends MessageIntent {
  const SendReceiptIntent({
    required this.toBareJid,
    required this.scopedId,
  });

  final String toBareJid;
  final MessageScopedId scopedId;
}

class SendMarkerIntent extends MessageIntent {
  const SendMarkerIntent({
    required this.toBareJid,
    required this.scopedId,
    required this.name,
  });

  final String toBareJid;
  final MessageScopedId scopedId;
  final String name;
}

class AddMessageIntent extends MessageIntent {
  const AddMessageIntent({
    required this.bareJid,
    required this.from,
    required this.to,
    required this.body,
    required this.timestamp,
    required this.messageId,
    required this.rawXml,
    this.oobUrl,
    this.oobDescription,
  });

  final String bareJid;
  final String from;
  final String to;
  final String body;
  final DateTime timestamp;
  final String messageId;
  final String rawXml;
  final String? oobUrl;
  final String? oobDescription;
}

class UnhandledMessageIntent extends MessageIntent {
  const UnhandledMessageIntent({required this.reason});

  final String reason;
}

class _OobInfo {
  _OobInfo({required this.url, this.description});

  final String url;
  final String? description;
}

class _CallStatsTracker {
  DateTime? lastSampleAt;
  int? lastOutboundBytes;
  int? lastInboundBytes;
  int? lastPacketsLost;
  int? lastPacketsReceived;
  int? videoBitrateTargetBps;
  double? lastLocalAudioEnergy;
  double? lastLocalSamplesDuration;
  double? lastRemoteAudioEnergy;
  double? lastRemoteSamplesDuration;
}

enum _JingleFileSendStatus { ok, unsupported, failed }

class _JingleFileSendResult {
  const _JingleFileSendResult(this.status, [this.error]);

  final _JingleFileSendStatus status;
  final String? error;
}
