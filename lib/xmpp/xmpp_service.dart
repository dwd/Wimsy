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
import 'call_ice.dart';
import 'extdisco.dart';
import 'jmi.dart';
import 'blocking.dart';
import 'http_upload.dart';
import 'jingle_grouping.dart';
import 'mam_cursor.dart';
import 'mam_coordinator.dart';
import 'mam_cursor_store.dart';
import 'mam_merge_engine.dart';
import 'mam_query_planner.dart';
import 'muc_invite.dart';
import 'muc_self_ping.dart';
import 'muc_config.dart';
import 'jid_discovery.dart';
import 'chat_message_mutations.dart';
import 'message_intent_builder.dart';
import 'message_stanza_parser.dart';
import 'startup_fetch_helpers.dart';
import 'vcard_utils.dart';
import 'ws_endpoint.dart';
import 'srv_lookup.dart';
import 'srv_target.dart';
import 'alt_connection.dart';
import 'quic_endpoint_plan.dart';
import 'quic_xmpp_socket.dart';
import 'tcp_endpoint_plan.dart';

class ReplyReference {
  const ReplyReference({
    required this.id,
    required this.toJid,
    required this.fallback,
  });

  final String id;
  final String toJid;
  final String fallback;
}

enum XmppStatus { disconnected, connecting, connected, error }

enum CsiOverrideMode { auto, active, inactive }

class XmppService extends ChangeNotifier {
  final MessageStanzaParser _messageStanzaParser = const MessageStanzaParser();

  XmppService() {
    _messageIntentBuilder = MessageIntentBuilder(
      currentUserBareJid: () => _currentUserBareJid,
      activeChatBareJid: () => _activeChatBareJid,
      parseJmiAction: parseJmiAction,
      extractReceiptsId: _messageStanzaParser.extractReceiptsId,
      extractMarkerId: _messageStanzaParser.extractMarkerId,
      extractReactionUpdate: _messageStanzaParser.extractReactionUpdate,
      reactionChatTarget: _reactionChatTarget,
      extractOobInfoFromStanza: _messageStanzaParser.extractOobInfo,
      extractReplyPayload: _messageStanzaParser.extractReplyPayload,
      isArchivedStanza: _isArchivedStanza,
      bareJid: _bareJid,
      hasReceiptRequest: _messageStanzaParser.hasReceiptRequest,
      hasMarkable: _messageStanzaParser.hasMarkable,
      serializeStanza: _serializeStanza,
      now: DateTime.now,
    );
    _mamCoordinator = MamCoordinator(
      cursorStore: _mamCursorStore,
      adapter: CallbackMamQueryAdapter(_dispatchMamPlan),
    );
  }

  late final MessageIntentBuilder _messageIntentBuilder;
  late final MamCoordinator _mamCoordinator;
  Connection? _connection;
  ChatManager? _chatManager;
  StreamSubscription<XmppConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<Buddy>>? _rosterSubscription;
  StreamSubscription<List<Chat>>? _chatListSubscription;
  StreamSubscription<PresenceData>? _presenceSubscription;
  StreamSubscription<PresenceErrorEvent>? _presenceErrorSubscription;
  StreamSubscription<Nonza>? _smNonzaSubscription;
  StreamSubscription<AbstractStanza?>? _pingSubscription;
  StreamSubscription<KeepaliveState>? _keepaliveStateSubscription;
  StreamSubscription<KeepaliveFailure>? _keepaliveFailureSubscription;
  StreamSubscription<ReconnectionState>? _reconnectStateSubscription;
  StreamSubscription<MessageStanza?>? _messageStanzaSubscription;
  StreamSubscription<AbstractStanza>? _smDeliveredSubscription;
  StreamSubscription<AbstractStanza?>? _pepSubscription;
  StreamSubscription<AbstractStanza?>? _mucPresenceSubscription;
  Timer? _csiIdleTimer;
  Timer? _mucSelfPingTimer;
  final Map<String, String> _pendingMucSelfPings = {};
  final Map<String, Timer> _mucSelfPingTimeouts = {};
  // ignore: unused_field
  // Hot-reload compatibility for pre-consolidation closures that still
  // reference this field name.
  final Map<String, DateTime> _pendingPings = {};
  String? _carbonsRequestId;
  static const Duration _mucSelfPingIdle = Duration(minutes: 10);
  static const Duration _mucSelfPingCheckInterval = Duration(minutes: 1);
  static const Duration _mucSelfPingTimeout = Duration(seconds: 30);
  final Map<String, StreamSubscription<Message>> _chatMessageSubscriptions = {};
  final Map<String, StreamSubscription<ChatState?>> _chatStateSubscriptions =
      {};

  XmppStatus _status = XmppStatus.disconnected;
  String? _errorMessage;
  String? _currentUserBareJid;
  XmppConnectionState? _lastConnectionState;
  bool _backgroundMode = false;
  bool _networkOnline = true;
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
  final List<int> _quicRttHistory = [];
  final List<int> _quicLossHistory = [];
  BigInt _lastQuicLostPackets = BigInt.zero;
  Timer? _quicStatsTimer;
  static const int _maxQuicHistory = 60;

  List<int> get quicRttHistory => _quicRttHistory;
  List<int> get quicLossHistory => _quicLossHistory;

  void Function(String bareJid, ChatMessage message)? _incomingMessageHandler;
  void Function(String roomJid, ChatMessage message)?
  _incomingRoomMessageHandler;
  void Function(CallSession session)? _incomingCallHandler;
  void Function(CallSession session)? _callSessionEndedHandler;
  void Function(List<ContactEntry> roster)? _rosterPersistor;
  void Function(List<ContactEntry> bookmarks)? _bookmarkPersistor;
  void Function(String bareJid, List<ChatMessage> messages)? _messagePersistor;
  void Function(String roomJid, List<ChatMessage> messages)?
  _roomMessagePersistor;
  PresenceData _selfPresence = PresenceData(
    PresenceShowElement.CHAT,
    'Online',
    null,
  );
  Duration? _lastPingLatency;
  DateTime? _lastPingAt;
  bool _carbonsEnabled = false;
  static const String _capsNode = 'https://wimsy.im/caps';
  static const String _capsHash = 'sha-1';
  static const String _replyNamespace = 'urn:xmpp:reply:0';
  static const String _featureFallbackNamespace = 'urn:xmpp:feature-fallback:0';
  static const String _jingleNamespace = 'urn:xmpp:jingle:1';
  static const String _jingleRtpNamespace = 'urn:xmpp:jingle:apps:rtp:1';
  static const String _jingleGroupingNamespace =
      'urn:xmpp:jingle:apps:grouping:0';
  static const String _jingleGroupingBundle = 'BUNDLE';
  String? _capsVer;
  bool _csiInactive = false;
  CsiOverrideMode _csiOverrideMode = CsiOverrideMode.auto;
  static const Duration _csiIdleDelay = Duration(minutes: 1);
  final MamCursorStore _mamCursorStore = MamCursorStore();
  final Map<String, Timer> _mamCatchUpTimers = {};
  DateTime? _lastGlobalMamSyncAt;
  StorageService? _storage;
  String? _rosterVersion;
  final Map<String, String> _displayedStanzaIdByChat = {};
  final Map<String, DateTime> _displayedAtByChat = {};
  // R1.3: pending displayed-sync markers we received from MDS but could
  // not yet match to any locally cached message. Resolved as messages
  // with the matching stanza-id are appended (live or via MAM). Persisted
  // through `StorageService.storeDisplayedSyncPending` so the resolution
  // survives restarts.
  final Map<String, String> _displayedSyncPending = {};
  // R2.1: globally newest MAM id we have ingested across all chats.
  // Persisted via `StorageService.storeLastMamIdSeen` so future sessions
  // can issue a single unified catch-up query (`afterId=` this anchor)
  // instead of fanning out per-chat. The unified-query wiring is a
  // follow-up; this commit lays the persistence foundation.
  String? _lastMamIdSeen;
  final Map<String, DateTime> _roomLastTrafficAt = {};
  final Map<String, DateTime> _roomLastPingAt = {};
  final Map<String, DateTime> _roomHistoryCutoffAt = {};
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
  final Map<String, String> _vcardDisplayNames = {};
  final Set<String> _vcardRequests = {};
  final Set<String> _vcardUnavailable = {};
  static const _vcardNoAvatar = vcardNoAvatarSentinel;
  String _selfVcardPhotoHash = '';
  bool _selfVcardPhotoKnown = false;
  final Map<String, _FileTransferSession> _fileTransfers = {};
  final Map<String, CallSession> _callSessions = {};
  final Map<String, String> _callSessionByPeerKey = {};
  final Map<String, Map<String, JingleRtpDescription>>
  _callLocalDescriptionsBySid = {};
  final Map<String, Map<String, JingleRtpDescription>>
  _callRemoteDescriptionsBySid = {};
  final WebRtcMediaSession _mediaSession = WebRtcMediaSession();
  final Map<String, RTCPeerConnection> _callPeerConnections = {};
  final Map<String, CallMediaKind> _callMediaKindBySid = {};
  final Map<String, MediaStream> _callLocalStreamBySid = {};
  final Map<String, MediaStream> _callRemoteStreamBySid = {};
  final Map<String, Map<String, JingleIceTransport>> _callLocalTransportsBySid =
      {};
  final Map<String, Map<String, JingleIceTransport>>
  _callRemoteTransportsBySid = {};
  final Map<String, List<String>> _callContentNamesBySid = {};
  final Map<String, bool> _callLocalBundleBySid = {};
  final Map<String, bool> _callRemoteBundleBySid = {};
  final Map<String, String> _callBundleTransportNameBySid = {};
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
  final Set<String> _pendingRecentReactionRequests = {};
  final List<String> _recentReactionEmojis = [];
  final Map<String, Timer> _callTimeoutTimers = {};
  final Map<String, Timer> _callStatsTimers = {};
  final Map<String, CallQualitySample> _callQualityBySid = {};
  final Map<String, _CallStatsTracker> _callStatsBySid = {};
  final CallQualityController _callQualityController =
      const CallQualityController();
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
  static const String _recentReactionsNode =
      'https://cridland.io/wimsy/reactions/recent/0';
  static const int _maxRecentReactionEmojis = 10;

  XmppStatus get status => _status;
  String? get errorMessage => _errorMessage;
  String? get currentUserBareJid => _currentUserBareJid;
  List<String> get recentReactionEmojis =>
      List.unmodifiable(_recentReactionEmojis);
  XmppConnectionState? get lastConnectionState => _lastConnectionState;
  List<ContactEntry> get contacts {
    final combined = <ContactEntry>[..._bookmarks, ..._contacts];
    combined.sort(_contactSort);
    return List.unmodifiable(combined);
  }

  String? get activeChatBareJid => _activeChatBareJid;
  String reactionSenderForChat(String bareJid, {required bool isRoom}) {
    final normalized = _bareJid(bareJid);
    return isRoom ? _roomNickFor(normalized) : (_currentUserBareJid ?? '');
  }

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
        .where(
          (device) => device.kind == 'audioinput' || device.kind == 'audio',
        )
        .toList();
  }

  Future<List<MediaDeviceInfo>> listVideoInputs() async {
    final devices = await navigator.mediaDevices.enumerateDevices();
    return devices
        .where(
          (device) => device.kind == 'videoinput' || device.kind == 'video',
        )
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
    // Seed the persisted displayed-at timestamps so that on a sync miss
    // (the stanzaId's message was evicted from the cache) we can still
    // set _displayedAtByChat correctly without treating all messages as new.
    _displayedAtByChat
      ..clear()
      ..addAll(storage.loadDisplayedSyncTimestamps());
    debugPrint(
      'DisplayedSync[seed]: loaded ${_displayedStanzaIdByChat.length} stanzaIds, '
      '${_displayedAtByChat.length} timestamps from disk. '
      'stanzaIds=${_displayedStanzaIdByChat.keys.toList()} '
      'timestamps=${_displayedAtByChat.map((k, v) => MapEntry(k, v.toIso8601String()))}',
    );
    // R1.3: seed pending displayed-sync markers from disk so we can keep
    // trying to resolve them as messages arrive in this session.
    _displayedSyncPending
      ..clear()
      ..addAll(storage.loadDisplayedSyncPending());
    // R2.1: seed the globally-newest MAM id anchor.
    _lastMamIdSeen = storage.loadLastMamIdSeen();
  }

  /// R2.1: returns the globally newest MAM id we have ingested across all
  /// chats, persisted across restarts. May be null on a fresh install.
  String? get lastMamIdSeen => _lastMamIdSeen;

  /// R2.1: update the global MAM-id anchor. We compare lexicographically
  /// because XEP-0359 stanza ids are unique, server-assigned strings; the
  /// MAM ids we get from a single archive are typically allocated in
  /// monotonic order, so a string-greater-than comparison is good enough
  /// to discard out-of-order updates without spurious disk writes.
  void _bumpLastMamIdSeen(String? mamId) {
    if (mamId == null || mamId.isEmpty) {
      return;
    }
    final current = _lastMamIdSeen;
    if (current != null && current.compareTo(mamId) >= 0) {
      return;
    }
    _lastMamIdSeen = mamId;
    _storage?.storeLastMamIdSeen(mamId);
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

  bool isMamCatchUpCompleteFor(String bareJid) {
    final normalized = _bareJid(bareJid);
    final isRoom =
        _roomMessages.containsKey(normalized) || isBookmark(normalized);
    return _isMamCatchUpComplete(normalized, isRoom: isRoom);
  }

  bool isMessageUnseen(String bareJid, ChatMessage message) {
    if (message.outgoing) {
      debugPrint(
        'NewMsg isMessageUnseen: chat=$bareJid messageId=${message.messageId} '
        '→ false (outgoing)',
      );
      return false;
    }
    // Primary check: per-message readByMe flag (set when user opens the chat).
    if (message.readByMe) {
      debugPrint(
        'NewMsg isMessageUnseen: chat=$bareJid messageId=${message.messageId} '
        '→ false (readByMe=true)',
      );
      return false;
    }
    // Fallback: timestamp-based check using the displayed-sync cutoff, used
    // for messages loaded from the archive before readByMe was persisted.
    final normalized = _bareJid(bareJid);
    final displayedAt = _displayedAtByChat[normalized];
    if (displayedAt == null) {
      debugPrint(
        'NewMsg isMessageUnseen: chat=$normalized messageId=${message.messageId} '
        'timestamp=${message.timestamp} displayedAt=null → true (no displayedAt)',
      );
      return true;
    }
    final result = message.timestamp.isAfter(displayedAt);
    debugPrint(
      'NewMsg isMessageUnseen: chat=$normalized messageId=${message.messageId} '
      'timestamp=${message.timestamp} displayedAt=$displayedAt → $result',
    );
    return result;
  }

  /// Marks all incoming messages in [bareJid]'s chat as read by the local
  /// user (sets [ChatMessage.readByMe] = true) and persists the updated list.
  /// Called whenever the user opens or views a chat.
  void markMessagesRead(String bareJid) {
    final normalized = _bareJid(bareJid);
    final isRoom = isBookmark(normalized);
    final list = isRoom ? _roomMessages[normalized] : _messages[normalized];
    if (list == null || list.isEmpty) {
      return;
    }
    var changed = false;
    for (var i = 0; i < list.length; i++) {
      final msg = list[i];
      if (!msg.outgoing && !msg.readByMe) {
        list[i] = msg.copyWith(readByMe: true);
        changed = true;
      }
    }
    if (changed) {
      if (isRoom) {
        _roomMessagePersistor?.call(normalized, List.unmodifiable(list));
      } else {
        _messagePersistor?.call(normalized, List.unmodifiable(list));
      }
    }
  }

  String displayNameFor(String bareJid) {
    final normalized = _bareJid(bareJid);
    final contact = _findContact(normalized);
    if (contact != null) {
      return contact.displayName;
    }
    final vcardName = _vcardDisplayNames[normalized]?.trim();
    if (vcardName != null && vcardName.isNotEmpty) {
      return vcardName;
    }
    return normalized;
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
    return oldestMamIdByTimestamp(messages);
  }

  String? _oldestRoomMamIdFor(String roomJid) {
    final messages = _roomMessages[_bareJid(roomJid)];
    if (messages == null || messages.isEmpty) {
      return null;
    }
    return oldestMamIdByTimestamp(messages);
  }

  String? latestMamIdFor(String bareJid) {
    final messages = _messages[_bareJid(bareJid)];
    if (messages == null || messages.isEmpty) {
      return null;
    }
    return latestMamIdByTimestamp(messages);
  }

  String? _latestRoomMamIdFor(String roomJid) {
    final messages = _roomMessages[_bareJid(roomJid)];
    if (messages == null || messages.isEmpty) {
      return null;
    }
    return latestMamIdByTimestamp(messages);
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

  Future<JidDiscoveryResult> discoverJidKind(
    String jid, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final connection = _connection;
    if (connection == null) {
      return const JidDiscoveryResult(kind: DiscoveredJidKind.unknown);
    }
    final normalized = _bareJid(jid);
    if (normalized.isEmpty) {
      return const JidDiscoveryResult(kind: DiscoveredJidKind.unknown);
    }
    if (!_hasValidBareJidStructure(normalized)) {
      return const JidDiscoveryResult(kind: DiscoveredJidKind.unknown);
    }
    try {
      final discoInfo = await _requestDiscoInfo(normalized).timeout(timeout);
      final result = classifyJidFromDiscoInfo(discoInfo);
      if (result.kind != DiscoveredJidKind.unknown) {
        return result;
      }
      final domain = _domainFromBareJid(normalized);
      if (domain.isNotEmpty && domain != normalized) {
        final domainInfo = await _requestDiscoInfo(domain).timeout(timeout);
        final domainResult = classifyJidFromDiscoInfo(domainInfo);
        if (domainResult.kind != DiscoveredJidKind.unknown) {
          return domainResult;
        }
      }
      if (discoInfo != null &&
          discoInfo.type == IqStanzaType.ERROR &&
          _iqErrorCondition(discoInfo) == 'service-unavailable') {
        _requestVcardAvatar(normalized);
        return const JidDiscoveryResult(kind: DiscoveredJidKind.person);
      }
      return result;
    } catch (_) {
      return const JidDiscoveryResult(kind: DiscoveredJidKind.unknown);
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
  bool get isCsiInactive => _csiInactive;
  CsiOverrideMode get csiOverrideMode => _csiOverrideMode;

  void setCsiOverrideMode(CsiOverrideMode mode) {
    if (_csiOverrideMode == mode) {
      return;
    }
    _csiOverrideMode = mode;
    _applyClientState();
    notifyListeners();
  }

  void setBackgroundMode(bool enabled) {
    if (_backgroundMode == enabled) {
      return;
    }
    _backgroundMode = enabled;
    Log.i('XmppService', 'Background mode changed to $enabled');
    _applyClientState();
    _connection?.setKeepaliveBackgroundMode(_backgroundMode);
    _connection?.setReconnectContext(
      networkOnline: _networkOnline,
      allowAutoReconnect: true,
    );
    Log.i('XmppService', 'Background mode change complete');
  }

  void handleConnectivityChange(bool online) {
    _networkOnline = online;
    _connection?.setReconnectContext(
      networkOnline: online,
      allowAutoReconnect: true,
    );
    if (!_networkOnline) {
      return;
    }
    // Attempt QUIC connection migration before falling back to a full reconnect.
    // If the active socket is QUIC-capable, rebind the UDP socket so Quinn can
    // send a PATH_CHALLENGE on the new network path (RFC 9000 §9).  Only on
    // migration failure (or non-QUIC transport) do we tear down the session.
    final socket = _connection?.socket;
    if (socket is QuicCapableXmppSocket) {
      debugPrint('QUIC migration: attempting migration after connectivity change');
      socket.attemptMigration().then((result) {
        if (result == MigrationResult.success) {
          debugPrint('QUIC migration: success — keeping XMPP session');
          _connection?.probeKeepalive(shortTimeout: true);
          // The XMPP session survived migration but messages may have arrived
          // while the network path was down.  Reset the debounce guard so
          // _primeMamSync() issues a fresh catch-up query immediately.
          _lastGlobalMamSyncAt = null;
          _primeMamSync();
        } else {
          debugPrint('QUIC migration: failed — falling back to full reconnect');
          _connection?.requestReconnect(
            reason: ReconnectionReason.networkChanged,
            immediate: true,
          );
        }
      });
    } else {
      _connection?.probeKeepalive(shortTimeout: true);
      _connection?.requestReconnect(
        reason: ReconnectionReason.networkChanged,
        immediate: true,
      );
    }
  }

  void noteUserActivity() {
    if (_csiOverrideMode != CsiOverrideMode.auto) {
      return;
    }
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
    String? connectionUrl,
    bool useQuic = true,
    bool useTcp = true,
  }) async {
    final quicTransportAvailable =
        !kIsWeb &&
        (Platform.isAndroid ||
            Platform.isIOS ||
            Platform.isLinux ||
            Platform.isMacOS ||
            Platform.isWindows);
    final shouldUseWebSocket = kIsWeb || useWebSocket;
    WsEndpointConfig? wsConfig;
    if (shouldUseWebSocket) {
      wsConfig = parseWsEndpoint(connectionUrl ?? '');
    }
    // Derive transport type from the URL scheme: https/http → WebTransport,
    // wss/ws → WebSocket.  This is re-evaluated after auto-discovery below.
    var useWebTransport = wsConfig?.isWebTransport ?? false;

    final normalized = jid.trim();
    if (!_looksLikeJid(normalized)) {
      _setError('Enter a full JID like user@domain.');
      return;
    }

    final bareJid = _bareJid(normalized);
    final fullJid = normalized.contains('/')
        ? normalized
        : '$bareJid/$resource';
    var resolvedHost = host?.trim().isNotEmpty == true ? host!.trim() : '';
    var resolvedPort = port;
    var resolvedDirectTls = directTls;
    List<XmppSrvTarget> quicSrvCandidates = const [];
    List<XmppSrvTarget> tcpSrvCandidates = const [];

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
      if (quicTransportAvailable && useQuic) {
        quicSrvCandidates = await resolveXmppQuicSrvCandidates(domain);
      }
      tcpSrvCandidates = await resolveXmppSrvCandidates(domain);
      // Filter SRV candidates by the user's transport allow-flags.
      // - When Direct TLS is off, drop _xmpps-client._tcp records.
      // - When Plain TCP is off, drop _xmpp-client._tcp records.
      // The two flags act as independent allow-lists; the user is only
      // allowed to actually connect via a transport they've enabled.
      final filteredTcpSrv = filterTcpSrvCandidatesByTransport(
        tcpSrvCandidates,
        allowDirectTls: directTls,
        allowPlainTcp: useTcp,
      );
      if (filteredTcpSrv.length != tcpSrvCandidates.length) {
        debugPrint(
          'XMPP SRV: filtered TCP candidates by user flags '
          '(directTls=$directTls useTcp=$useTcp): '
          '${tcpSrvCandidates.length} -> ${filteredTcpSrv.length}',
        );
      }
      tcpSrvCandidates = filteredTcpSrv;
      _finishSpan(srvSpan);
      if (quicTransportAvailable && quicSrvCandidates.isNotEmpty) {
        final first = quicSrvCandidates.first;
        resolvedHost = first.host;
        resolvedPort = first.port;
        resolvedDirectTls = false;
      } else if (tcpSrvCandidates.isNotEmpty) {
        final first = tcpSrvCandidates.first;
        resolvedHost = first.host;
        resolvedPort = first.port;
        resolvedDirectTls = first.directTls;
      } else if (resolvedPort == 0 || resolvedPort == 5222) {
        resolvedPort = directTls ? 5223 : 5222;
      }
      // If after filtering we have no usable transport at all (no QUIC,
      // no surviving TCP SRV records, and the user has disabled the
      // transport that the fallback port would use), bail out with a
      // clear error rather than silently falling through.
      final hasQuic = quicTransportAvailable && quicSrvCandidates.isNotEmpty;
      final hasTcp = tcpSrvCandidates.isNotEmpty;
      final fallbackAllowed = directTls || useTcp;
      if (!hasQuic && !hasTcp && !fallbackAllowed) {
        _setError(
          'No transport enabled: both Direct TLS and Plain TCP are '
          'disabled and no QUIC/WebSocket endpoint is available.',
        );
        return;
      }
    }

    if (shouldUseWebSocket && wsConfig == null) {
      final domain = _domainFromBareJid(bareJid);
      final wsSpan = _startSpan(
        _connectTransaction,
        'xmpp.ws_discovery',
        description: domain,
      );
      // Try WebTransport first; fall back to WebSocket if not advertised.
      final discoveredWt = await discoverWebTransportEndpoint(domain);
      _finishSpan(wsSpan);
      if (discoveredWt != null) {
        // WebTransport uses https:// URIs; store the URI directly and mark
        // the transport so Connection.dart routes through XmppWebTransportHtml.
        final wtUri = discoveredWt.scheme == 'wss'
            ? discoveredWt.replace(scheme: 'https')
            : discoveredWt;
        wsConfig = WsEndpointConfig(
          uri: wtUri,
          host: wtUri.host,
          port: wtUri.hasPort ? wtUri.port : 443,
          path: wtUri.path.isEmpty ? '/webtransport' : wtUri.path,
          scheme: wtUri.scheme,
        );
        useWebTransport = true;
      } else {
        final discoveredWs = await discoverWebSocketEndpoint(domain);
        if (discoveredWs != null) {
          wsConfig = parseWsEndpoint(discoveredWs.toString());
        }
      }
      if (wsConfig == null) {
        _setError('Enter a connection URL like wss://host/path or https://host/path.');
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
      debugPrint(
        'XMPP TLS: directTls=$resolvedDirectTls useWebSocket=$shouldUseWebSocket',
      );
      debugPrint(
        'XMPP connect: bareJid=$bareJid host=$normalizedHost port=$resolvedPort resource=$resource',
      );
      final account = XmppAccountSettings.fromJid(fullJid, password);
      account.host = resolvedHost.isNotEmpty ? resolvedHost : null;
      account.port = resolvedPort;
      account.resource = resource;
      account.useWebSocket = shouldUseWebSocket;
      account.useWebTransport = useWebTransport;
      account.directTls = resolvedDirectTls;
      account.sasl2Software = 'Wimsy';
      account.sasl2Device = resource;
      if (!shouldUseWebSocket) {
        account.quicEndpoints = (quicTransportAvailable && useQuic)
            ? buildQuicEndpointPlan(
                domain: account.domain,
                srvCandidates: quicSrvCandidates,
              )
            : const [];
        account.tcpEndpoints = buildTcpEndpointPlan(
          domain: account.domain,
          resolvedHost: resolvedHost,
          resolvedPort: resolvedPort,
          directTls: resolvedDirectTls,
          srvCandidates: tcpSrvCandidates,
        );
      }
      if (wsConfig != null) {
        account.wsUrl = wsConfig.uri.toString();
        account.wsHost = wsConfig.host;
        account.wsPort = wsConfig.port;
        account.wsPath = wsConfig.path;
      }

      final connection =
          quicTransportAvailable && (account.quicEndpoints?.isNotEmpty ?? false)
          ? Connection.getInstance(
              account,
              socketFactory: () => QuicCapableXmppSocket(),
            )
          : Connection.getInstance(account);
      _connection = connection;
      // Seed the ServiceDiscoveryNegotiator caps cache from persistent
      // storage so that if the server advertises a caps hash we already
      // verified in a previous session, we can skip the disco#info IQ
      // entirely on connect.
      final storage = _storage;
      if (storage != null) {
        ServiceDiscoveryNegotiator.seedCapsCache(storage.loadEntityCaps());
      }
      // Persist newly discovered server caps so future connects can elide
      // the disco#info IQ for the same server version.
      ServiceDiscoveryNegotiator.onCapsResult = (capsKey, features) {
        _storage?.storeEntityCaps(capsKey, features);
      };
      connection.setReconnectPolicy(
        const ReconnectionPolicy(
          baseDelay: Duration(seconds: 5),
          maxDelay: Duration(minutes: 10),
          jitterRatio: 0.25,
          unboundedRetries: true,
        ),
      );
      connection.setReconnectContext(
        networkOnline: _networkOnline,
        allowAutoReconnect: true,
      );
      _reconnectStateSubscription?.cancel();
      _reconnectStateSubscription = connection.reconnectStateStream.listen((
        state,
      ) {
        if (state.phase == ReconnectionPhase.scheduled ||
            state.phase == ReconnectionPhase.reconnecting) {
          if (_status != XmppStatus.disconnected) {
            _status = XmppStatus.connecting;
            _errorMessage = null;
            notifyListeners();
          }
          return;
        }
        if (state.phase == ReconnectionPhase.terminal) {
          _setError(state.message ?? 'Reconnection halted.');
        }
      });

      final completer = Completer<void>();
      _connectionStateSubscription = connection.connectionStateStream.listen((
        state,
      ) {
        debugPrint('XMPP state: $state');
        Log.i('XmppService', 'Connection state: $state');
        _lastConnectionState = state;
        if (state == XmppConnectionState.Reconnecting ||
            state == XmppConnectionState.ForcefullyClosed) {
          // Any in-flight carbons enable request is tied to the old stream.
          _carbonsRequestId = null;
          _carbonsEnabled = false;
          _status = XmppStatus.connecting;
          _errorMessage = null;
          notifyListeners();
          return;
        }
        if (state == XmppConnectionState.Resumed) {
          // Resumed stream may have lost prior client-state assumptions.
          _carbonsRequestId = null;
          _carbonsEnabled = false;
          _csiInactive = false;
          _status = XmppStatus.connected;
          _errorMessage = null;
          notifyListeners();
          _setupKeepalive();
          _setupQuicStats();
          _setupDeliveryTracking();
          _setupJingle();
          _setupIbb();
          _applyClientState();
          return;
        }
        if (state == XmppConnectionState.Ready) {
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
          // R6: Re-seed the vCard avatar caches from disk on every Ready
          // event, not just at startup. The disconnect handler clears these
          // maps so that stale in-memory state doesn't survive a resource
          // rebind, but without re-seeding the R4.1 cache-guard sees an
          // empty cache and re-fetches every vCard on reconnect.
          final storage = _storage;
          if (storage != null) {
            _seedVcardAvatars(storage.loadVcardAvatars());
            _seedVcardAvatarState(storage.loadVcardAvatarState());
          }
          _setupRoster();
          _setupChatManager();
          _setupMuc();
          _setupMessageSignals();
          _setupJingle();
          _setupIbb();
          _setupPresence();
          // If carbons were enabled inline during Bind2 (XEP-0280 + XEP-0386),
          // mark them as already enabled so _requestCarbons() skips the
          // redundant IQ round-trip.
          if (connection.carbons2EnabledInline) {
            _carbonsEnabled = true;
          }
          _setupKeepalive();
          _setupQuicStats();
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
          _finishSpan(
            _connectAwaitSpan,
            status: const SpanStatus.internalError(),
          );
          _connectAwaitSpan = null;
          _finishSpan(
            _connectTransaction,
            status: const SpanStatus.internalError(),
          );
          _connectTransaction = null;
          _setError(message);
          connection.setReconnectTerminal(message);
        } else if (_status == XmppStatus.connecting) {
          notifyListeners();
        }
      });

      _connectAwaitSpan = _startSpan(
        _connectTransaction,
        'xmpp.connect.await_ready',
      );
      connection.connect();

      // Allow enough time for the full XMPP negotiation sequence on high-latency
      // paths: QUIC handshake + stream open + features + SASL exchange + resource
      // bind can each take one RTT, so 20 s is too tight when latency is high.
      // 120 s gives a realistic budget while still bounding a truly stuck connect.
      await completer.future.timeout(const Duration(seconds: 120));
    } catch (error) {
      _finishSpan(
        _connectAwaitSpan,
        status: const SpanStatus.deadlineExceeded(),
      );
      _connectAwaitSpan = null;
      _finishSpan(
        _connectTransaction,
        status: const SpanStatus.internalError(),
      );
      _connectTransaction = null;
      if (_status != XmppStatus.error) {
        _setError('Connection failed: $error');
        _connection?.requestReconnect(
          reason: ReconnectionReason.manualRequest,
          immediate: true,
          shortTimeout: true,
        );
      }
    }
  }

  Future<void> disconnect() async {
    _connection?.setReconnectContext(allowAutoReconnect: false);
    await _safeClose(preserveCache: true);
    _finishSpan(_connectAwaitSpan, status: const SpanStatus.cancelled());
    _connectAwaitSpan = null;
    _finishSpan(_connectTransaction, status: const SpanStatus.cancelled());
    _connectTransaction = null;
    _status = XmppStatus.disconnected;
    _errorMessage = null;
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
    _roomHistoryCutoffAt.clear();
    _rosterVersion = null;
    _pepManager?.clearCache();
    _bookmarksManager?.clearCache();
    _vcardAvatarBytes.clear();
    _vcardAvatarState.clear();
    _vcardDisplayNames.clear();
    _vcardRequests.clear();
    _vcardUnavailable.clear();
    _mamCursorStore.clear();
    for (final timer in _mamCatchUpTimers.values) {
      timer.cancel();
    }
    _mamCatchUpTimers.clear();
    _messagePersistor?.call('', const []);
    _roomMessagePersistor?.call('', const []);
    _rosterPersistor?.call(const []);
    _bookmarkPersistor?.call(const []);
    _storage?.storeRosterVersion(null);
    _displayedStanzaIdByChat.clear();
    _displayedSyncPending.clear();
    _displayedAtByChat.clear();
    _storage?.clearDisplayedSync();
    notifyListeners();
  }

  void selectChat(String? bareJid) {
    _activeChatBareJid = bareJid;
    if (bareJid != null && !isBookmark(bareJid)) {
      setMyChatState(bareJid, ChatState.ACTIVE);
      _requestMamOnOpen(bareJid);
      _sendDisplayedForChat(bareJid);
      _publishDisplayedState(bareJid);
    }
    if (bareJid != null && isBookmark(bareJid)) {
      _ensureRoom(_bareJid(bareJid));
      _requestRoomMamOnOpen(bareJid);
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
    _mamCoordinator.requestOlder(
      bareJid: normalized,
      isRoom: isBookmark(normalized),
      seeded: isBookmark(normalized)
          ? _seededRoomMessageJids.contains(normalized)
          : _seededMessageJids.contains(normalized),
      oldestMamId: isBookmark(normalized)
          ? _oldestRoomMamIdFor(normalized)
          : oldestMamIdFor(normalized),
      onDmInitialFallback: () => _requestMamInitial(normalized),
    );
  }

  void setRosterPersistor(void Function(List<ContactEntry> roster)? persistor) {
    _rosterPersistor = persistor;
  }

  void setIncomingMessageHandler(
    void Function(String bareJid, ChatMessage message)? handler,
  ) {
    _incomingMessageHandler = handler;
  }

  void setIncomingRoomMessageHandler(
    void Function(String roomJid, ChatMessage message)? handler,
  ) {
    _incomingRoomMessageHandler = handler;
  }

  void setIncomingCallHandler(void Function(CallSession session)? handler) {
    _incomingCallHandler = handler;
  }

  void setCallSessionEndedHandler(void Function(CallSession session)? handler) {
    _callSessionEndedHandler = handler;
  }

  void setBookmarkPersistor(
    void Function(List<ContactEntry> bookmarks)? persistor,
  ) {
    _bookmarkPersistor = persistor;
  }

  void setMessagePersistor(
    void Function(String bareJid, List<ChatMessage> messages)? persistor,
  ) {
    _messagePersistor = persistor;
  }

  void setRoomMessagePersistor(
    void Function(String roomJid, List<ChatMessage> messages)? persistor,
  ) {
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
        bookmarks.map(
          (entry) =>
              entry.isBookmark ? entry : entry.copyWith(isBookmark: true),
        ),
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
    ReplyReference? reply,
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

    final connection = _connection;
    if (connection == null) {
      _setError('Not connected.');
      return;
    }
    final messageId = AbstractStanza.getRandomId();
    final stanza = _buildChatMessageStanza(
      toBareJid: toBareJid,
      messageId: messageId,
      body: trimmed,
      reply: reply,
    );
    connection.writeStanza(stanza);
    final sender = _currentUserBareJid ?? connection.fullJid.userAtDomain;
    if (sender.isNotEmpty) {
      _addMessage(
        bareJid: toBareJid,
        from: sender,
        to: toBareJid,
        body: trimmed,
        rawXml: _serializeStanza(stanza),
        outgoing: true,
        timestamp: DateTime.now(),
        messageId: messageId,
        replyToId: reply?.id,
        replyToJid: reply?.toJid,
        replyFallback: reply?.fallback,
      );
    }
    final jid = Jid.fromFullJid(toBareJid);
    final chat = chatManager.getChat(jid);
    _ensureChatSubscription(chat);
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
    final stanza = MessageStanza(
      AbstractStanza.getRandomId(),
      MessageStanzaType.CHAT,
    );
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

  Future<bool> upsertRosterContact(
    String bareJid, {
    String? name,
    List<String>? groups,
  }) async {
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
    final existingIndex = _contacts.indexWhere(
      (entry) => entry.jid == normalized,
    );
    if (existingIndex == -1) {
      _contacts.add(
        ContactEntry(
          jid: normalized,
          name: buddy.name,
          groups: buddy.groups,
          subscriptionType: null,
        ),
      );
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
    _requestVcardDetails(
      normalized,
      preferName: name == null || name.trim().isEmpty,
    );
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
    final mucSpan = _startLinkedTransaction(
      'xmpp.muc.join',
      'xmpp.muc',
      _connectTransaction,
    );
    if (mucSpan != null) {
      mucSpan.setTag('xmpp.room', normalized);
      _mucJoinTransactions[normalized] = mucSpan;
    }
    muc.joinRoom(
      Jid.fromFullJid(normalized),
      resolvedNick,
      password: resolvedPassword,
      // Suppress server-side MUC history on join; MAM is used for catch-up.
      suppressHistory: true,
    );
    final existing = _rooms[normalized] ?? RoomEntry(roomJid: normalized);
    _rooms[normalized] = existing.copyWith(joined: true, nick: resolvedNick);
    notifyListeners();
    final latestRoomTs = _latestRoomTimestamp(normalized);
    _roomHistoryCutoffAt[normalized] = latestRoomTs ?? DateTime.now();
    final latestRoomMamId = _latestRoomMamIdFor(normalized);
    if (latestRoomMamId != null && latestRoomMamId.isNotEmpty) {
      _startMamCatchUp(normalized, isRoom: true);
    } else {
      _requestRoomMam(normalized, max: 25, before: '');
    }
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

  void sendRoomMessage(String roomJid, String text, {ReplyReference? reply}) {
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
    final payloadBody = _buildReplyBody(reply, trimmed);
    final stanza = MessageStanza(messageId, MessageStanzaType.GROUPCHAT);
    stanza.toJid = Jid.fromFullJid(normalized);
    stanza.body = payloadBody;
    if (reply != null) {
      stanza.addChild(_buildReplyElement(reply));
      stanza.addChild(
        _buildFallbackElement(
          start: 0,
          end: reply.fallback.runes.length,
          forNamespace: _replyNamespace,
        ),
      );
    }
    _connection?.writeStanza(stanza);
    final rawXml = _serializeStanza(stanza);
    final nick = _roomNickFor(normalized);
    _addRoomMessage(
      roomJid: normalized,
      from: nick,
      body: trimmed,
      rawXml: rawXml,
      outgoing: true,
      timestamp: DateTime.now(),
      messageId: messageId,
      replyToId: reply?.id,
      replyToJid: reply?.toJid,
      replyFallback: reply?.fallback,
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
    final stanza = MessageStanza(
      AbstractStanza.getRandomId(),
      MessageStanzaType.GROUPCHAT,
    );
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
      mucUser.addAttribute(
        XmppAttribute('xmlns', 'http://jabber.org/protocol/muc#user'),
      );
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

  Future<String?> sendPhotoMessage({
    required String toBareJid,
    required Uint8List bytes,
    required String fileName,
    String? contentType,
    String? body,
  }) async {
    return _sendHttpUploadMessage(
      targetJid: toBareJid,
      bytes: bytes,
      fileName: fileName,
      contentType: contentType,
      isRoom: false,
      body: body,
    );
  }

  Future<String?> sendRoomPhotoMessage({
    required String roomJid,
    required Uint8List bytes,
    required String fileName,
    String? contentType,
    String? body,
  }) async {
    return _sendHttpUploadMessage(
      targetJid: roomJid,
      bytes: bytes,
      fileName: fileName,
      contentType: contentType,
      isRoom: true,
      body: body,
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
    String? body,
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
    final bodyText = (body != null && body.trim().isNotEmpty)
        ? body.trim()
        : url;
    final stanza = _buildOobMessageStanza(
      targetJid: normalized,
      messageId: messageId,
      url: url,
      description: description.isEmpty ? null : description,
      isRoom: isRoom,
      body: bodyText,
    );
    connection.writeStanza(stanza);
    final rawXml = _serializeStanza(stanza);
    final now = DateTime.now();
    if (isRoom) {
      final nick = _roomNickFor(normalized);
      _addRoomMessage(
        roomJid: normalized,
        from: nick,
        body: bodyText,
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
      body: bodyText,
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
    final transferSpan = _startLinkedTransaction(
      'xmpp.file_transfer',
      'xmpp.file',
      _connectTransaction,
    );
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

  Future<void> declineFileTransfer({required String transferId}) async {
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
    if (!_isLikelyEmoji(trimmed)) {
      return;
    }
    final targetId = message.stanzaId ?? message.messageId;
    if (targetId == null || targetId.isEmpty) {
      return;
    }
    final normalizedJid = _bareJid(bareJid);
    final sender = isRoom
        ? _roomNickFor(normalizedJid)
        : (_currentUserBareJid ?? '');
    if (sender.isEmpty) {
      return;
    }
    final currentOwn = _ownReactionsFor(message, sender);
    final nextOwn = <String>{...currentOwn};
    final added = !nextOwn.remove(trimmed);
    if (added) {
      nextOwn.add(trimmed);
      _rememberRecentReactionEmoji(trimmed);
    }
    final outgoingReactions = nextOwn.toList()..sort();

    final stanza = MessageStanza(
      AbstractStanza.getRandomId(),
      isRoom ? MessageStanzaType.GROUPCHAT : MessageStanzaType.CHAT,
    );
    stanza.toJid = Jid.fromFullJid(normalizedJid);
    final reactions = XmppElement()..name = 'reactions';
    reactions.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:reactions:0'));
    reactions.addAttribute(XmppAttribute('id', targetId));
    for (final value in outgoingReactions) {
      final reaction = XmppElement()..name = 'reaction';
      reaction.textValue = value;
      reactions.addChild(reaction);
    }
    stanza.addChild(reactions);
    connection.writeStanza(stanza);

    if (isRoom) {
      _applyRoomReactionUpdate(
        normalizedJid,
        sender,
        targetId,
        outgoingReactions,
      );
    } else {
      _applyReactionUpdate(
        normalizedJid,
        sender,
        ReactionUpdate(targetId, outgoingReactions),
      );
    }
  }

  ReplyReference? buildReplyReference({
    required String chatJid,
    required ChatMessage message,
    required bool isRoom,
  }) {
    final targetId = message.stanzaId ?? message.messageId;
    if (targetId == null || targetId.isEmpty) {
      return null;
    }
    final normalized = _bareJid(chatJid);
    final toJid = isRoom
        ? '$normalized/${message.from}'
        : (message.outgoing
              ? (_currentUserBareJid ?? normalized)
              : _bareJid(message.from));
    final fallbackQuote = _buildReplyFallbackQuote(message.body);
    return ReplyReference(
      id: targetId,
      toJid: toJid,
      fallback: '$fallbackQuote\n\n',
    );
  }

  String _buildReplyFallbackQuote(String body) {
    final normalized = body.trim().replaceAll('\r\n', '\n');
    if (normalized.isEmpty) {
      return '> …';
    }
    final maxLength = 280;
    final clipped = normalized.runes.length > maxLength
        ? '${String.fromCharCodes(normalized.runes.take(maxLength))}…'
        : normalized;
    final lines = clipped.split('\n');
    final firstLines = lines.take(3).toList();
    if (lines.length > 3) {
      firstLines.add('…');
    }
    return firstLines.map((line) => '> $line').join('\n');
  }

  Set<String> _ownReactionsFor(ChatMessage message, String sender) {
    final reactions = message.reactions ?? const {};
    final own = <String>{};
    reactions.forEach((emoji, senders) {
      if (emoji.isNotEmpty && senders.contains(sender)) {
        own.add(emoji);
      }
    });
    return own;
  }

  bool _isLikelyEmoji(String value) {
    if (value.isEmpty || value.contains(RegExp(r'\s'))) {
      return false;
    }
    return RegExp(
      r'[\u00A9\u00AE\u203C-\u3299\u{1F000}-\u{1FAFF}]',
      unicode: true,
    ).hasMatch(value);
  }

  void _rememberRecentReactionEmoji(String emoji) {
    if (!_isLikelyEmoji(emoji)) {
      return;
    }
    final existing = _recentReactionEmojis.indexOf(emoji);
    if (existing == 0) {
      return;
    }
    if (existing > 0) {
      _recentReactionEmojis.removeAt(existing);
    }
    _recentReactionEmojis.insert(0, emoji);
    if (_recentReactionEmojis.length > _maxRecentReactionEmojis) {
      _recentReactionEmojis.removeRange(
        _maxRecentReactionEmojis,
        _recentReactionEmojis.length,
      );
    }
    _publishRecentReactionEmojis();
    notifyListeners();
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
          final subscriptionType = buddy.subscriptionType
              ?.toString()
              .split('.')
              .last
              .toLowerCase();
          _ensureContact(
            jid,
            name: buddy.name,
            groups: buddy.groups,
            subscriptionType: subscriptionType,
          );
          _pepManager?.requestMetadataIfMissing(jid);
          _requestVcardDetails(
            jid,
            preferName: buddy.name == null || buddy.name!.trim().isEmpty,
          );
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
    _jingleSubscription = _jingleManager!.sessionStream.listen(
      _handleJingleEvent,
    );
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
    _smDeliveredSubscription = streamManagement.deliveredStanzasStream.listen((
      stanza,
    ) {
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
    _roomSubscriptions['message'] = _mucManager!.roomMessageStream.listen((
      message,
    ) {
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
      final isSelfReflection = _isRoomSelfReflection(
        message.roomJid,
        message.nick,
      );
      _addRoomMessage(
        roomJid: message.roomJid,
        from: message.nick,
        body: message.body,
        oobUrl: message.oobUrl,
        rawXml: message.rawXml ?? _buildIncomingGroupFallbackXml(message),
        outgoing: isSelfReflection,
        timestamp: message.timestamp,
        messageId: message.messageId ?? message.stanzaId,
        mamId: message.mamResultId,
        stanzaId: message.stanzaId,
        replyToId: message.replyToId,
        replyToJid: message.replyToJid,
        replyFallback: message.replyFallback,
      );
    });
    _roomSubscriptions['presence']?.cancel();
    _roomSubscriptions['presence'] = _mucManager!.roomPresenceStream.listen((
      presence,
    ) {
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
    _roomSubscriptions['subject'] = _mucManager!.roomSubjectStream.listen((
      subject,
    ) {
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
      final bundleGroup = extractBundleGroupNames(
        event.stanza,
        groupingNamespace: _jingleGroupingNamespace,
        groupingBundle: _jingleGroupingBundle,
      );
      if (bundleGroup.isNotEmpty) {
        _callRemoteBundleBySid[event.sid] = true;
        _callLocalBundleBySid[event.sid] = true;
        _callBundleTransportNameBySid[event.sid] = bundleGroup.first;
      } else {
        _callRemoteBundleBySid[event.sid] = false;
        _callLocalBundleBySid[event.sid] = false;
        _callBundleTransportNameBySid.remove(event.sid);
      }
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
    final transferSpan = _startLinkedTransaction(
      'xmpp.file_transfer',
      'xmpp.file',
      _connectTransaction,
    );
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
    if (callSession != null &&
        callSession.direction == CallDirection.outgoing) {
      final bundleGroup = extractBundleGroupNames(
        event.stanza,
        groupingNamespace: _jingleGroupingNamespace,
        groupingBundle: _jingleGroupingBundle,
      );
      if (bundleGroup.isNotEmpty) {
        _callRemoteBundleBySid[event.sid] = true;
        _callBundleTransportNameBySid.putIfAbsent(
          event.sid,
          () => bundleGroup.first,
        );
      } else {
        _callRemoteBundleBySid[event.sid] = false;
      }
      _callAcceptedBySid.add(event.sid);
      _flushPendingIceCandidates(event.sid);
      callSession.state = CallState.active;
      _cancelCallTimeout(callSession.sid);
      _startCallStatsTimer(callSession.sid);
      _finishSpan(_jingleSetupTransactions.remove(event.sid));
      final rtpContents = event.contents
          .where((content) => content.rtpDescription != null)
          .toList(growable: false);
      unawaited(
        _applyRemoteDescriptionsForCall(
          sid: callSession.sid,
          contents: rtpContents,
          direction: callSession.direction,
          sdpType: 'answer',
        ),
      );
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
        : (reason == 'decline'
              ? _fileTransferStateDeclined
              : _fileTransferStateFailed);
    _updateFileTransferMessage(
      bareJid: session.peerBareJid,
      transferId: session.sid,
      state: nextState,
    );
    _finalizeTransfer(session);
  }

  void _handleIncomingCall(
    JingleSessionEvent event,
    List<JingleContent> contents,
  ) {
    final peerJid = event.from.fullJid ?? event.from.userAtDomain;
    if (peerJid.isEmpty) {
      return;
    }
    _storeCallPeerFullJid(event.sid, event.from);
    if (_callSessions.containsKey(event.sid)) {
      return;
    }
    _storeRemoteCallContents(event.sid, contents);
    final hasVideo = contents.any(
      (content) =>
          (content.rtpDescription?.media.toLowerCase() ?? '') == 'video',
    );
    _callMediaKindBySid[event.sid] = hasVideo
        ? CallMediaKind.video
        : CallMediaKind.audio;
    final session = CallSession(
      sid: event.sid,
      peerBareJid: peerJid,
      direction: CallDirection.incoming,
      video: hasVideo,
      state: CallState.ringing,
    );
    _callSessions[event.sid] = session;
    _callSessionByPeerKey[_callPeerKeyForJid(peerJid)] = event.sid;
    _callContentNamesBySid[event.sid] = contentNamesFor(contents);
    _callMutedBySid[event.sid] = false;
    _callVideoEnabledBySid[event.sid] = session.video;
    _incomingCallHandler?.call(session);
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
    final hasVideo = contents.any(
      (content) =>
          (content.rtpDescription?.media.toLowerCase() ?? '') == 'video',
    );
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
    _callMediaKindBySid[sid] = nextVideo
        ? CallMediaKind.video
        : CallMediaKind.audio;
    _callVideoEnabledBySid[sid] = nextVideo;
    _callContentNamesBySid[sid] = contentNamesFor(contents);
    notifyListeners();
  }

  bool _shouldBundleForPeer(String bareJid) {
    final normalized = _bareJid(bareJid);
    if (normalized.isEmpty) {
      return true;
    }
    final full = _selectJinglePeerFullJid(normalized);
    if (full == null || full.isEmpty) {
      return true;
    }
    final features = _pepCapsManager?.featuresForFullJid(full);
    if (features == null || features.isEmpty) {
      return true;
    }
    return features.contains(_jingleGroupingNamespace);
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
      _callContentNamesBySid[sid] = contentNamesFor(contents);
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
      contents.add(
        JingleContent(
          name: entry.key,
          creator: 'initiator',
          rtpDescription: entry.value,
          iceTransport: transports[entry.key],
        ),
      );
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
    final bundle = _shouldBundleForPeer(bareJid);
    _callLocalBundleBySid[sid] = bundle;
    final pc = await _createPeerConnection(
      sid: sid,
      peerBareJid: bareJid,
      kind: kind,
      bundle: bundle,
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
    _callContentNamesBySid[sid] = mappings
        .map((mapping) => mapping.contentName)
        .toList(growable: false);
    if (bundle) {
      final bundleName = bundleTransportNameForMappings(mappings);
      if (bundleName != null && bundleName.isNotEmpty) {
        _callBundleTransportNameBySid[sid] = bundleName;
      }
    }
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
    final jingleSpan = _startLinkedTransaction(
      'xmpp.jingle.setup',
      'xmpp.jingle',
      _connectTransaction,
    );
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
        _jmiProposedMediaBySid[sid] = descriptions
            .map((desc) => desc.media)
            .toSet();
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
      final jingleSpan = _startLinkedTransaction(
        'xmpp.jingle.setup',
        'xmpp.jingle',
        _connectTransaction,
      );
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
    final bundle = _callRemoteBundleBySid[session.sid] ?? false;
    _callLocalBundleBySid[session.sid] = bundle;
    final pc = await _createPeerConnection(
      sid: session.sid,
      peerBareJid: session.peerBareJid,
      kind: kind,
      bundle: bundle,
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
        bundle: bundle,
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
    _callContentNamesBySid[session.sid] = mappings
        .map((mapping) => mapping.contentName)
        .toList(growable: false);
    if (bundle && !_callBundleTransportNameBySid.containsKey(session.sid)) {
      final bundleName = bundleTransportNameForMappings(mappings);
      if (bundleName != null && bundleName.isNotEmpty) {
        _callBundleTransportNameBySid[session.sid] = bundleName;
      }
    }
    _flushPendingIceCandidates(session.sid);
    final toJid = _callPeerJidForSid(session.sid, session.peerBareJid);
    if (toJid == null) {
      session.state = CallState.failed;
      _removeCallSession(session);
      return;
    }
    final localContents = _buildCallContents(
      localDescriptions,
      localTransports,
    );
    final iq = jingle.buildRtpSessionAcceptMulti(
      to: toJid,
      sid: session.sid,
      contents: localContents,
    );
    if (bundle) {
      attachBundleGroup(
        iq,
        bundleGroupNamesForContents(localContents),
        groupingNamespace: _jingleGroupingNamespace,
        groupingBundle: _jingleGroupingBundle,
      );
    }
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
          outboundBytes =
              (outboundBytes ?? 0) + (_statInt(values, 'bytesSent') ?? 0);
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
              (localAudioEnergy ?? 0) +
              (_statDouble(values, 'totalAudioEnergy') ?? 0);
          localSamplesDuration =
              (localSamplesDuration ?? 0) +
              (_statDouble(values, 'totalSamplesDuration') ?? 0);
        }
      }
      if (type == 'inbound-rtp') {
        if (_statString(values, 'kind') == 'video' ||
            _statString(values, 'mediaType') == 'video') {
          inboundBytes =
              (inboundBytes ?? 0) + (_statInt(values, 'bytesReceived') ?? 0);
          packetsLost =
              (packetsLost ?? 0) + (_statInt(values, 'packetsLost') ?? 0);
          packetsReceived =
              (packetsReceived ?? 0) +
              (_statInt(values, 'packetsReceived') ?? 0);
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
              (remoteAudioEnergy ?? 0) +
              (_statDouble(values, 'totalAudioEnergy') ?? 0);
          remoteSamplesDuration =
              (remoteSamplesDuration ?? 0) +
              (_statDouble(values, 'totalSamplesDuration') ?? 0);
        }
      }
      if (type == 'candidate-pair') {
        final state = _statString(values, 'state');
        final nominated =
            values['nominated'] == true || values['selected'] == true;
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
    final nextLocal = _resolveAudioLevel(
      tracker,
      localLevel,
      localEnergy,
      localDuration,
      true,
    );
    final nextRemote = _resolveAudioLevel(
      tracker,
      remoteLevel,
      remoteEnergy,
      remoteDuration,
      false,
    );

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
    final remoteDesc = remote == null
        ? 'unknown'
        : _describeIceCandidate(remote);
    final rtt = _statDouble(values, 'currentRoundTripTime');
    final rttMs = rtt == null
        ? ''
        : ' rtt=${(rtt * 1000).toStringAsFixed(1)}ms';
    final summary =
        'pair=${pairId ?? 'unknown'} local=[$localDesc] remote=[$remoteDesc]$rttMs';
    if (_callSelectedCandidateSummaryBySid[sid] == summary) {
      return;
    }
    _callSelectedCandidateSummaryBySid[sid] = summary;
    Log.d('XmppService', 'Call $sid selected ICE $summary');
  }

  String _describeIceCandidate(Map<dynamic, dynamic> values) {
    final type = _statString(values, 'candidateType') ?? 'unknown';
    final protocol = _statString(values, 'protocol') ?? 'unknown';
    final ip =
        _statString(values, 'ip') ?? _statString(values, 'address') ?? '?';
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
    final lastEnergy = isLocal
        ? tracker.lastLocalAudioEnergy
        : tracker.lastRemoteAudioEnergy;
    final lastDuration = isLocal
        ? tracker.lastLocalSamplesDuration
        : tracker.lastRemoteSamplesDuration;
    tracker
      ..lastLocalAudioEnergy = isLocal
          ? totalEnergy
          : tracker.lastLocalAudioEnergy
      ..lastRemoteAudioEnergy = isLocal
          ? tracker.lastRemoteAudioEnergy
          : totalEnergy
      ..lastLocalSamplesDuration = isLocal
          ? totalDuration
          : tracker.lastLocalSamplesDuration
      ..lastRemoteSamplesDuration = isLocal
          ? tracker.lastRemoteSamplesDuration
          : totalDuration;
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
    _callLocalBundleBySid.remove(session.sid);
    _callRemoteBundleBySid.remove(session.sid);
    _callBundleTransportNameBySid.remove(session.sid);
    _callMutedBySid.remove(session.sid);
    _callVideoEnabledBySid.remove(session.sid);
    _callLocalSpeakingBySid.remove(session.sid);
    _callRemoteSpeakingBySid.remove(session.sid);
    _callSessionEndedHandler?.call(session);
    _callSessions.remove(session.sid);
    _callSessionByPeerKey.remove(_callPeerKeyForJid(session.peerBareJid));
    unawaited(_mediaSession.stop());
    notifyListeners();
  }

  CallSession? callSessionBySid(String sid) {
    return _callSessions[sid];
  }

  Future<void> acceptCallBySid(String sid) async {
    final session = _callSessions[sid];
    if (session == null || session.direction != CallDirection.incoming) {
      return;
    }
    await acceptCall(session);
  }

  Future<void> declineCallBySid(String sid) async {
    final session = _callSessions[sid];
    if (session == null || session.direction != CallDirection.incoming) {
      return;
    }
    await declineCall(session);
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
          session.state = action == JmiAction.reject
              ? CallState.declined
              : CallState.ended;
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
                (content) =>
                    proposedMedia.contains(content.rtpDescription?.media ?? ''),
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
    if (_callLocalBundleBySid[sid] == true) {
      attachBundleGroup(
        iq,
        bundleGroupNamesForContents(filteredContents),
        groupingNamespace: _jingleGroupingNamespace,
        groupingBundle: _jingleGroupingBundle,
      );
    }
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
      bundle: _callRemoteBundleBySid[sid] ?? false,
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
    remoteTransports[contentName] = existing == null
        ? transport
        : mergeIceTransports(existing, transport);
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
      final candidateLine = buildCandidateLine(candidate);
      pc.addCandidate(RTCIceCandidate(candidateLine, mid, null));
    }
  }

  Future<RTCPeerConnection?> _createPeerConnection({
    required String sid,
    required String peerBareJid,
    required CallMediaKind kind,
    required bool bundle,
  }) async {
    final config = <String, dynamic>{
      'iceServers': _iceServers,
      'bundlePolicy': bundle ? 'max-bundle' : 'max-compat',
    };
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
      final parsed = parseIceCandidate(candidate.candidate);
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
    final defaultKind = session?.video == true
        ? CallMediaKind.video
        : CallMediaKind.audio;
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
        Log.d('XmppService', 'Call $sid delaying ICE until session-accept.');
      }
      return;
    }
    final transports = _callLocalTransportsBySid[sid];
    if (transports == null || transports.isEmpty) {
      return;
    }
    final parsed = parseIceCandidate(candidate.candidate);
    if (parsed == null) {
      return;
    }
    final jingle = _jingleManager;
    if (jingle == null) {
      return;
    }
    final bundleContent = _callLocalBundleBySid[sid] == true
        ? _callBundleTransportNameBySid[sid]
        : null;
    final contentName =
        bundleContent ??
        resolveCandidateContentName(
          candidate: candidate,
          contentNames: _callContentNamesBySid[sid],
          defaultKind: defaultKind,
        );
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
      contentName: contentName.isNotEmpty ? contentName : transports.keys.first,
      creator: 'initiator',
      transport: transportInfo,
    );
    unawaited(_sendIqAndAwait(info));
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
    if (_mamCatchUpTimers.isNotEmpty) {
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
    return _messageIntentBuilder.build(stanza);
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
          replyToId: intent.replyToId,
          replyToJid: intent.replyToJid,
          replyFallback: intent.replyFallback,
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
      if (child.getAttribute('xmlns')?.value !=
          'http://jabber.org/protocol/muc#user') {
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

  bool _isRoomSelfReflection(String roomJid, String senderNick) {
    final normalized = _bareJid(roomJid);
    final nick = _rooms[normalized]?.nick ?? _roomNickFor(normalized);
    final trimmedNick = nick.trim();
    final trimmedSender = senderNick.trim();
    if (trimmedNick.isEmpty || trimmedSender.isEmpty) {
      return false;
    }
    return trimmedNick == trimmedSender;
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
    _mucSelfPingTimeouts[id] = Timer(
      _mucSelfPingTimeout,
      () => _handleMucSelfPingTimeout(id),
    );
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

  String _reactionChatTarget(String fromBare, String toBare) {
    final selfBare = _currentUserBareJid;
    if (selfBare != null && _bareJid(fromBare) == selfBare) {
      return _bareJid(toBare);
    }
    return _bareJid(fromBare);
  }

  void _applyReactionUpdate(
    String bareJid,
    String sender,
    ReactionUpdate update,
  ) {
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
    return ChatMessageMutations.applyCorrectionInList(
      list,
      sender: sender,
      replaceId: replaceId,
      newBody: newBody,
      rawXml: rawXml,
      timestamp: timestamp,
      matchSenderBare: matchSenderBare,
      bareJid: _bareJid,
      oobUrl: oobUrl,
      oobDescription: oobDescription,
    );
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
    return ChatMessageMutations.updateReactionsInList(list, sender, update);
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
    query.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#items'),
    );
    iqStanza.addChild(query);
    final result = await _sendIqAndAwait(iqStanza);
    if (result == null || result.type != IqStanzaType.RESULT) {
      return const [];
    }
    final resultQuery = result.getChild('query');
    if (resultQuery == null ||
        resultQuery.getAttribute('xmlns')?.value !=
            'http://jabber.org/protocol/disco#items') {
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
    query.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'),
    );
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
    iqStanza.addChild(
      buildHttpUploadRequest(
        fileName: fileName,
        size: size,
        contentType: contentType,
      ),
    );
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
      final response = await http.put(
        slot.putUrl,
        headers: headers,
        body: bytes,
      );
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
    String? body,
  }) {
    final stanza = MessageStanza(
      messageId,
      isRoom ? MessageStanzaType.GROUPCHAT : MessageStanzaType.CHAT,
    );
    stanza.toJid = Jid.fromFullJid(targetJid);
    if (!isRoom) {
      stanza.fromJid = _connection?.fullJid;
    }
    stanza.body = (body != null && body.trim().isNotEmpty) ? body.trim() : url;
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
    stanza.addChild(
      _buildFallbackElement(start: 0, end: stanza.body!.runes.length),
    );
    if (!isRoom) {
      final receiptRequest = XmppElement()..name = 'request';
      receiptRequest.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:receipts'));
      stanza.addChild(receiptRequest);
      final markable = XmppElement()..name = 'markable';
      markable.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:chat-markers:0'));
      stanza.addChild(markable);
    }
    return stanza;
  }

  MessageStanza _buildChatMessageStanza({
    required String toBareJid,
    required String messageId,
    required String body,
    ReplyReference? reply,
  }) {
    final stanza = MessageStanza(messageId, MessageStanzaType.CHAT);
    stanza.toJid = Jid.fromFullJid(toBareJid);
    stanza.fromJid = _connection?.fullJid;
    final payloadBody = _buildReplyBody(reply, body);
    stanza.body = payloadBody;
    if (reply != null) {
      stanza.addChild(_buildReplyElement(reply));
      stanza.addChild(
        _buildFallbackElement(
          start: 0,
          end: reply.fallback.runes.length,
          forNamespace: _replyNamespace,
        ),
      );
    }
    final receiptRequest = XmppElement()..name = 'request';
    receiptRequest.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:receipts'));
    stanza.addChild(receiptRequest);
    final markable = XmppElement()..name = 'markable';
    markable.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:chat-markers:0'));
    stanza.addChild(markable);
    return stanza;
  }

  XmppElement _buildReplyElement(ReplyReference reply) {
    final element = XmppElement()..name = 'reply';
    element.addAttribute(XmppAttribute('xmlns', _replyNamespace));
    element.addAttribute(XmppAttribute('id', reply.id));
    if (reply.toJid.isNotEmpty) {
      element.addAttribute(XmppAttribute('to', reply.toJid));
    }
    return element;
  }

  XmppElement _buildFallbackElement({
    required int start,
    required int end,
    String? forNamespace,
  }) {
    final fallback = XmppElement()..name = 'fallback';
    fallback.addAttribute(XmppAttribute('xmlns', _featureFallbackNamespace));
    if (forNamespace != null && forNamespace.isNotEmpty) {
      fallback.addAttribute(XmppAttribute('for', forNamespace));
    }
    final bodyFallback = XmppElement()..name = 'body';
    bodyFallback.addAttribute(XmppAttribute('start', start.toString()));
    bodyFallback.addAttribute(XmppAttribute('end', end.toString()));
    fallback.addChild(bodyFallback);
    return fallback;
  }

  String _buildReplyBody(ReplyReference? reply, String body) {
    if (reply == null) {
      return body;
    }
    return '${reply.fallback}$body';
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

  XmppElement _buildReplaceElement(String replaceId) {
    final replace = XmppElement()..name = 'replace';
    replace.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:message-correct:0'));
    replace.addAttribute(XmppAttribute('id', replaceId));
    return replace;
  }

  String _buildIncomingGroupFallbackXml(MucMessage message) {
    final id =
        message.messageId ?? message.stanzaId ?? AbstractStanza.getRandomId();
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
      if (child.name == 'delay' &&
          child.getAttribute('xmlns')?.value == 'urn:xmpp:delay') {
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
    final stanza = MessageStanza(
      AbstractStanza.getRandomId(),
      MessageStanzaType.CHAT,
    );
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
    final stanza = MessageStanza(
      AbstractStanza.getRandomId(),
      MessageStanzaType.CHAT,
    );
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
      final hasServerNotFound =
          errorElement?.children.any(
            (child) =>
                child.name == 'remote-server-not-found' ||
                child.name == 'server-not-found',
          ) ??
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
      // R5: persist the XEP-0115 caps cache across restarts so MUC
      // presence storms don't trigger a `disco#info` fan-out for caps
      // we already verified in a previous session.
      storage: storage,
    );
    _requestRecentReactionEmojis();
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
      _handleRecentReactionsStanza(stanza);
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

  /// Send the bootstrap `urn:xmpp:mds:displayed:0` PubSub items GET.
  ///
  /// R1.1: Skip the IQ entirely when `_displayedStanzaIdByChat` was
  /// successfully restored from disk on startup. PEP +notify pushes (which
  /// we already handle in `_handleDisplayedSyncEvent`) keep the cache live
  /// after that, so the bootstrap fetch is only needed on a true cold
  /// start — i.e. when the in-memory map is still empty.
  ///
  /// We also expose [force] for tests and for hypothetical callers that
  /// want to refresh the entire MDS state regardless of the local cache.
  void _setupDisplayedSync({bool force = false}) {
    final connection = _connection;
    if (connection == null || _currentUserBareJid == null) {
      return;
    }
    if (!shouldFetchDisplayedSyncBootstrap(
      hasCachedDisplayedSync: _displayedStanzaIdByChat.isNotEmpty,
      force: force,
    )) {
      // Cache was seeded from disk; rely on +notify for live updates.
      return;
    }
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(_currentUserBareJid!);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', 'urn:xmpp:mds:displayed:0'));
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
  }

  void _requestRecentReactionEmojis() {
    final connection = _connection;
    final selfBareJid = _currentUserBareJid;
    if (connection == null || selfBareJid == null || selfBareJid.isEmpty) {
      return;
    }
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(selfBareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', _recentReactionsNode));
    items.addAttribute(XmppAttribute('max_items', '1'));
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    _pendingRecentReactionRequests.add(id);
    connection.writeStanza(iqStanza);
  }

  void _publishRecentReactionEmojis() {
    final connection = _connection;
    final selfBareJid = _currentUserBareJid;
    if (connection == null || selfBareJid == null || selfBareJid.isEmpty) {
      return;
    }
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    iqStanza.toJid = Jid.fromFullJid(selfBareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final publish = XmppElement()..name = 'publish';
    publish.addAttribute(XmppAttribute('node', _recentReactionsNode));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', 'recent'));
    final recent = XmppElement()..name = 'recent';
    recent.addAttribute(XmppAttribute('xmlns', _recentReactionsNode));
    for (final emoji in _recentReactionEmojis) {
      final element = XmppElement()..name = 'emoji';
      element.textValue = emoji;
      recent.addChild(element);
    }
    item.addChild(recent);
    publish.addChild(item);
    pubsub.addChild(publish);

    final options = XmppElement()..name = 'publish-options';
    final form = XmppElement()..name = 'x';
    form.addAttribute(XmppAttribute('xmlns', 'jabber:x:data'));
    form.addAttribute(XmppAttribute('type', 'submit'));
    final formType = XmppElement()..name = 'field';
    formType.addAttribute(XmppAttribute('var', 'FORM_TYPE'));
    formType.addAttribute(XmppAttribute('type', 'hidden'));
    final formTypeValue = XmppElement()..name = 'value';
    formTypeValue.textValue =
        'http://jabber.org/protocol/pubsub#publish-options';
    formType.addChild(formTypeValue);
    final accessModel = XmppElement()..name = 'field';
    accessModel.addAttribute(XmppAttribute('var', 'pubsub#access_model'));
    final accessValue = XmppElement()..name = 'value';
    accessValue.textValue = 'whitelist';
    accessModel.addChild(accessValue);
    form.addChild(formType);
    form.addChild(accessModel);
    options.addChild(form);
    pubsub.addChild(options);
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
  }

  void _handleRecentReactionsStanza(AbstractStanza stanza) {
    if (stanza is MessageStanza) {
      _handleRecentReactionsEvent(stanza);
      return;
    }
    if (stanza is IqStanza) {
      _handleRecentReactionsResult(stanza);
    }
  }

  void _handleRecentReactionsEvent(MessageStanza stanza) {
    final event = stanza.children.firstWhere(
      (child) =>
          child.name == 'event' &&
          child.getAttribute('xmlns')?.value ==
              'http://jabber.org/protocol/pubsub#event',
      orElse: () => XmppElement(),
    );
    if (event.name != 'event') {
      return;
    }
    final items = event.getChild('items');
    if (items == null ||
        items.getAttribute('node')?.value != _recentReactionsNode) {
      return;
    }
    _applyRecentReactionsItems(items);
  }

  void _handleRecentReactionsResult(IqStanza stanza) {
    final id = stanza.id;
    if (id == null || !_pendingRecentReactionRequests.remove(id)) {
      return;
    }
    if (stanza.type != IqStanzaType.RESULT) {
      return;
    }
    final pubsub = stanza.getChild('pubsub');
    if (pubsub == null ||
        pubsub.getAttribute('xmlns')?.value !=
            'http://jabber.org/protocol/pubsub') {
      return;
    }
    final items = pubsub.getChild('items');
    if (items == null ||
        items.getAttribute('node')?.value != _recentReactionsNode) {
      return;
    }
    _applyRecentReactionsItems(items);
  }

  void _applyRecentReactionsItems(XmppElement items) {
    for (final item in items.children.where((child) => child.name == 'item')) {
      final payload = item.children.firstWhere(
        (child) =>
            child.name == 'recent' &&
            child.getAttribute('xmlns')?.value == _recentReactionsNode,
        orElse: () => XmppElement(),
      );
      if (payload.name != 'recent') {
        continue;
      }
      final next = <String>[];
      for (final emojiNode in payload.children.where(
        (child) => child.name == 'emoji',
      )) {
        final emoji = emojiNode.textValue?.trim() ?? '';
        if (!_isLikelyEmoji(emoji) || next.contains(emoji)) {
          continue;
        }
        next.add(emoji);
        if (next.length == _maxRecentReactionEmojis) {
          break;
        }
      }
      if (_listEquals(next, _recentReactionEmojis)) {
        return;
      }
      _recentReactionEmojis
        ..clear()
        ..addAll(next);
      notifyListeners();
      return;
    }
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
      (child) =>
          child.name == 'event' &&
          child.getAttribute('xmlns')?.value ==
              'http://jabber.org/protocol/pubsub#event',
      orElse: () => XmppElement(),
    );
    if (event.name != 'event') {
      return;
    }
    final items = event.getChild('items');
    if (items == null ||
        items.getAttribute('node')?.value != 'urn:xmpp:mds:displayed:0') {
      return;
    }
    // Log the delay stamp if present — a delayed MDS event means the server
    // is replaying an old PEP notification from a previous session. The delay
    // stamp is the time the marker was originally published, which is a useful
    // fallback cutoff when the referenced stanzaId has been evicted from cache.
    final delay = stanza.children
        .where((c) =>
            c.name == 'delay' &&
            c.getAttribute('xmlns')?.value == 'urn:xmpp:delay')
        .firstOrNull;
    final delayStamp = delay?.getAttribute('stamp')?.value;
    debugPrint(
      'DisplayedSync[event]: from=${stanza.fromJid} '
      'itemCount=${items.children.where((c) => c.name == "item").length} '
      'delayStamp=$delayStamp '
      '(${delayStamp != null ? "REPLAYED offline event" : "live event"})',
    );
    _applyDisplayedSyncItems(items);
  }

  void _handleDisplayedSyncResult(IqStanza stanza) {
    if (stanza.type != IqStanzaType.RESULT) {
      return;
    }
    final pubsub = stanza.getChild('pubsub');
    if (pubsub == null ||
        pubsub.getAttribute('xmlns')?.value !=
            'http://jabber.org/protocol/pubsub') {
      return;
    }
    final items = pubsub.getChild('items');
    if (items == null ||
        items.getAttribute('node')?.value != 'urn:xmpp:mds:displayed:0') {
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
      final existingStanzaId = _displayedStanzaIdByChat[id];
      debugPrint(
        'DisplayedSync[apply]: id=$id incomingStanzaId=$stanzaId '
        'existingStanzaId=$existingStanzaId '
        'existingDisplayedAt=${_displayedAtByChat[id]} '
        '${existingStanzaId == stanzaId ? "SKIP (same)" : "APPLY (changed)"}',
      );
      if (existingStanzaId == stanzaId) {
        continue;
      }
      _displayedStanzaIdByChat[id] = stanzaId;
      if (_applyDisplayedStateForChat(id)) {
        updated = true;
      }
    }
    if (updated) {
      _storage?.storeDisplayedSync(
        Map<String, String>.from(_displayedStanzaIdByChat),
      );
      _storage?.storeDisplayedSyncTimestamps(
        Map<String, DateTime>.from(_displayedAtByChat),
      );
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
      // R1.3: persist the pending marker so we can resolve it later.
      _markDisplayedSyncPending(normalized, stanzaId);
      return false;
    }
    ChatMessage? matched;
    for (final message in list) {
      if (message.stanzaId == stanzaId) {
        matched = message;
      }
    }
    if (matched == null) {
      final knownStanzaIds = list
          .map((message) => message.stanzaId)
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .take(5)
          .toList(growable: false);
      Log.w(
        'XmppService',
        'Displayed sync miss for chat=$normalized stanzaId=$stanzaId '
            'messages=${list.length} knownStanzaIds=$knownStanzaIds',
      );
      // R1.3: persist the (chat, stanzaId) pair. We will retry resolution
      // every time a new message is appended (live or via MAM) for this
      // chat — see `_resolveDisplayedSyncPending`.
      final fallbackTs = _displayedAtByChat[normalized];
      debugPrint(
        'DisplayedSync[miss]: chat=$normalized stanzaId=$stanzaId '
        'messages=${list.length} fallbackTimestamp=$fallbackTs '
        '(${fallbackTs == null ? "NO FALLBACK — will treat all messages as unseen" : "fallback present — unread cutoff preserved"})',
      );
      _markDisplayedSyncPending(normalized, stanzaId);
      return false;
    }
    final existing = _displayedAtByChat[normalized];
    if (existing != null && !matched.timestamp.isAfter(existing)) {
      // Even if we don't update the timestamp, we *did* successfully match
      // the marker — so clear the pending entry.
      _clearDisplayedSyncPending(normalized);
      return false;
    }
    _displayedAtByChat[normalized] = matched.timestamp;
    final isRoom =
        _roomMessages.containsKey(normalized) || isBookmark(normalized);
    _markMamCatchUpCompleted(normalized, isRoom: isRoom);
    _clearDisplayedSyncPending(normalized);
    return true;
  }

  /// R1.3: record an unresolved (chat, stanza-id) pair and persist it so
  /// the next session (or the next MAM page in this session) can resolve
  /// it as messages arrive.
  void _markDisplayedSyncPending(String bareJid, String stanzaId) {
    if (bareJid.isEmpty || stanzaId.isEmpty) {
      return;
    }
    if (_displayedSyncPending[bareJid] == stanzaId) {
      return;
    }
    _displayedSyncPending[bareJid] = stanzaId;
    _storage?.storeDisplayedSyncPending(
      Map<String, String>.from(_displayedSyncPending),
    );
  }

  /// R1.3: clear a resolved pending marker and persist the smaller map.
  void _clearDisplayedSyncPending(String bareJid) {
    if (!_displayedSyncPending.containsKey(bareJid)) {
      return;
    }
    _displayedSyncPending.remove(bareJid);
    _storage?.storeDisplayedSyncPending(
      Map<String, String>.from(_displayedSyncPending),
    );
  }

  /// R1.3: called from the message-append code paths whenever we add a
  /// message with a known [stanzaId] to [bareJid]'s list. If the stanza-id
  /// matches the chat's pending displayed-sync marker, kick the marker
  /// resolution path. Cheap O(1) lookup; safe to call unconditionally.
  void _resolveDisplayedSyncPending(String bareJid, String? stanzaId) {
    if (stanzaId == null || stanzaId.isEmpty) {
      return;
    }
    final normalized = _bareJid(bareJid);
    final pending = _displayedSyncPending[normalized];
    if (pending == null || pending != stanzaId) {
      return;
    }
    // Re-run the matcher; on success it clears the pending entry, sets the
    // displayed timestamp, and marks MAM catch-up complete for this chat.
    if (_applyDisplayedStateForChat(normalized)) {
      _storage?.storeDisplayedSync(
        Map<String, String>.from(_displayedStanzaIdByChat),
      );
      _storage?.storeDisplayedSyncTimestamps(
        Map<String, DateTime>.from(_displayedAtByChat),
      );
      notifyListeners();
    }
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
        ..addAll(
          items
              .where(
                (item) =>
                    item.type == PrivacyType.JID &&
                    item.action == PrivacyAction.DENY,
              )
              .map((item) => item.value ?? '')
              .where((jid) => jid.isNotEmpty),
        );
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
        items.add(
          PrivacyListItem(
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
          ),
        );
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

  void _setupQuicStats() {
    _quicStatsTimer?.cancel();
    _quicRttHistory.clear();
    _quicLossHistory.clear();
    _lastQuicLostPackets = BigInt.zero;

    final socket = _connection?.socket;
    if (socket == null || !socket.isQuic) return;

    _quicStatsTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final stats = await socket.getQuicStats();
      if (stats == null) return;

      _quicRttHistory.add(stats.path.rttMillis.toInt());
      if (_quicRttHistory.length > _maxQuicHistory) {
        _quicRttHistory.removeAt(0);
      }

      final currentLoss = stats.path.lostPackets;
      final deltaLoss = currentLoss - _lastQuicLostPackets;
      _lastQuicLostPackets = currentLoss;
      _quicLossHistory.add(deltaLoss.toInt());
      if (_quicLossHistory.length > _maxQuicHistory) {
        _quicLossHistory.removeAt(0);
      }

      notifyListeners();
    });
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
        return;
      }
      if (nonza.name == 'error' &&
          xmlns == 'http://etherx.jabber.org/streams') {
        _handleStreamError(nonza);
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
      }
    });
    _keepaliveStateSubscription?.cancel();
    _keepaliveStateSubscription = connection.keepaliveStateStream.listen((
      state,
    ) {
      _lastPingLatency = state.lastLatency;
      if (state.lastSuccessAt != null) {
        _lastPingAt = state.lastSuccessAt;
      }
      notifyListeners();
    });
    _keepaliveFailureSubscription?.cancel();
    _keepaliveFailureSubscription = connection.keepaliveFailureStream.listen((
      failure,
    ) {
      _lastPingLatency = null;
      _lastPingAt = failure.occurredAt;
      notifyListeners();
    });
    connection.setKeepaliveBackgroundMode(_backgroundMode);
    connection.probeKeepalive(shortTimeout: false);
    _requestCarbons();
  }

  Future<void> _handleStreamError(Nonza nonza) async {
    Log.w('XmppService', 'Stream error received: ${nonza.name}');
    _connection?.requestReconnect(
      reason: ReconnectionReason.streamError,
      immediate: true,
      shortTimeout: true,
    );
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
        final parsedReply = _messageStanzaParser.extractReplyPayload(
          message.messageStanza,
          body: message.text,
        );
        final body = parsedReply?.cleanedBody ?? message.text ?? '';
        final oobInfo = _messageStanzaParser.extractOobInfo(
          message.messageStanza,
        );
        final oobUrl = oobInfo?.url;
        final oobDescription = oobInfo?.description;
        final rawXml = _serializeStanza(message.messageStanza);
        final replaceId = _messageStanzaParser.extractReplaceId(
          message.messageStanza,
        );
        final reaction = _messageStanzaParser.extractReactionUpdate(
          message.messageStanza,
        );
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
        if (replaceId != null &&
            replaceId.isNotEmpty &&
            targetBare.isNotEmpty) {
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
          replyToId: parsedReply?.replyToId,
          replyToJid: parsedReply?.replyToJid,
          replyFallback: parsedReply?.fallbackBody,
        );
      }
    }
    _chatMessageSubscriptions[buddyJid] = chat.newMessageStream.listen((
      message,
    ) {
      final from = message.from?.userAtDomain ?? 'unknown';
      final to = message.to?.userAtDomain ?? '';
      final parsedReply = _messageStanzaParser.extractReplyPayload(
        message.messageStanza,
        body: message.text,
      );
      final body = parsedReply?.cleanedBody ?? message.text ?? '';
      final oobInfo = _messageStanzaParser.extractOobInfo(
        message.messageStanza,
      );
      final oobUrl = oobInfo?.url;
      final oobDescription = oobInfo?.description;
      final rawXml = _serializeStanza(message.messageStanza);
      final replaceId = _messageStanzaParser.extractReplaceId(
        message.messageStanza,
      );
      final reaction = _messageStanzaParser.extractReactionUpdate(
        message.messageStanza,
      );
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
        replyToId: parsedReply?.replyToId,
        replyToJid: parsedReply?.replyToJid,
        replyFallback: parsedReply?.fallbackBody,
      );
    });

    _chatStateSubscriptions[buddyJid]?.cancel();
    _chatStateSubscriptions[buddyJid] = chat.remoteStateStream.listen((state) {
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
    String? replyToId,
    String? replyToJid,
    String? replyFallback,
  }) {
    final normalized = _bareJid(bareJid);
    _ensureContact(normalized);

    final list = _messages.putIfAbsent(normalized, () => <ChatMessage>[]);
    if (messageId != null && messageId.isNotEmpty) {
      final existingIndex = list.indexWhere(
        (message) =>
            message.messageId == messageId &&
            _bareJid(message.from) == _bareJid(from),
      );
      if (existingIndex != -1) {
        final existing = list[existingIndex];
        final nextMamId = (mamId != null && mamId.isNotEmpty)
            ? mamId
            : existing.mamId;
        final nextStanzaId = (stanzaId != null && stanzaId.isNotEmpty)
            ? stanzaId
            : existing.stanzaId;
        final nextOobUrl = (oobUrl != null && oobUrl.isNotEmpty)
            ? oobUrl
            : existing.oobUrl;
        final nextRawXml = rawXml.isNotEmpty ? rawXml : existing.rawXml;
        final nextOobDescription =
            (oobDescription != null && oobDescription.isNotEmpty)
            ? oobDescription
            : existing.oobDescription;
        final nextInviteRoomJid =
            (inviteRoomJid != null && inviteRoomJid.isNotEmpty)
            ? inviteRoomJid
            : existing.inviteRoomJid;
        final nextInviteReason =
            (inviteReason != null && inviteReason.isNotEmpty)
            ? inviteReason
            : existing.inviteReason;
        final nextInvitePassword =
            (invitePassword != null && invitePassword.isNotEmpty)
            ? invitePassword
            : existing.invitePassword;
        final nextReplyToId = (replyToId != null && replyToId.isNotEmpty)
            ? replyToId
            : existing.replyToId;
        final nextReplyToJid = (replyToJid != null && replyToJid.isNotEmpty)
            ? replyToJid
            : existing.replyToJid;
        final nextReplyFallback =
            (replyFallback != null && replyFallback.isNotEmpty)
            ? replyFallback
            : existing.replyFallback;
        if (nextMamId != existing.mamId ||
            nextStanzaId != existing.stanzaId ||
            nextOobUrl != existing.oobUrl ||
            nextRawXml != existing.rawXml ||
            nextOobDescription != existing.oobDescription ||
            nextInviteRoomJid != existing.inviteRoomJid ||
            nextInviteReason != existing.inviteReason ||
            nextInvitePassword != existing.invitePassword ||
            nextReplyToId != existing.replyToId ||
            nextReplyToJid != existing.replyToJid ||
            nextReplyFallback != existing.replyFallback) {
          list[existingIndex] = existing.copyWith(
            mamId: nextMamId,
            stanzaId: nextStanzaId,
            oobUrl: nextOobUrl,
            oobDescription: nextOobDescription,
            rawXml: nextRawXml,
            inviteRoomJid: nextInviteRoomJid,
            inviteReason: nextInviteReason,
            invitePassword: nextInvitePassword,
            replyToId: nextReplyToId,
            replyToJid: nextReplyToJid,
            replyFallback: nextReplyFallback,
          );
          notifyListeners();
          _messagePersistor?.call(normalized, List.unmodifiable(list));
        }
        debugPrint(
          'NewMsg[DM-dedup] chat=$normalized outgoing=$outgoing '
          'messageId=$messageId mamId=$mamId — merged existing, early return',
        );
        return;
      }
    }
    if (mamId != null &&
        mamId.isNotEmpty &&
        list.any((message) => message.mamId == mamId)) {
      debugPrint(
        'NewMsg[DM-dedup] chat=$normalized outgoing=$outgoing '
        'mamId=$mamId — duplicate mamId, early return',
      );
      return;
    }
    if (stanzaId != null &&
        stanzaId.isNotEmpty &&
        list.any(
          (message) =>
              message.stanzaId == stanzaId &&
              _bareJid(message.from) == _bareJid(from),
        )) {
      debugPrint(
        'NewMsg[DM-dedup] chat=$normalized outgoing=$outgoing '
        'stanzaId=$stanzaId — duplicate stanzaId, early return',
      );
      return;
    }
    final hasIncomingIds =
        (mamId != null && mamId.isNotEmpty) ||
        (stanzaId != null && stanzaId.isNotEmpty);
    if (hasIncomingIds) {
      final merged = mergeMamIdsIntoExisting(
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
        debugPrint(
          'NewMsg[DM-dedup] chat=$normalized outgoing=$outgoing '
          'mamId=$mamId stanzaId=$stanzaId — mergeMamIds matched, early return',
        );
        notifyListeners();
        _messagePersistor?.call(normalized, List.unmodifiable(list));
        return;
      }
    }
    final prependOffset = _mamCursorStore.prependOffsetFor(normalized);
    if (mamId != null && mamId.isNotEmpty && prependOffset != null) {
      final insertIndex = prependOffset.clamp(0, list.length);
      debugPrint(
        'NewMsg[DM-prepend] chat=$normalized outgoing=$outgoing '
        'mamId=$mamId stanzaId=$stanzaId timestamp=$timestamp '
        'insertIndex=$insertIndex — early return, no handler fired',
      );
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
          replyToId: replyToId,
          replyToJid: replyToJid,
          replyFallback: replyFallback,
        ),
      );
      _mamCursorStore.incrementPrependOffset(normalized);
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
      replyToId: replyToId,
      replyToJid: replyToJid,
      replyFallback: replyFallback,
    );
    _insertMessageOrdered(list, newMessage);
    if (!outgoing) {
      _lastSeenAt[normalized] ??= timestamp;
    }
    // R1.3: resolve pending displayed-sync marker BEFORE notifyListeners so
    // that _displayedAtByChat is populated before the UI reads unread counts.
    _resolveDisplayedSyncPending(normalized, stanzaId);
    notifyListeners();
    _messagePersistor?.call(normalized, List.unmodifiable(list));
    // R2.1: bump the global MAM-id anchor.
    _bumpLastMamIdSeen(mamId);
    final hasMamId = mamId != null && mamId.isNotEmpty;
    final catchUpComplete = _isMamCatchUpComplete(normalized, isRoom: false);
    debugPrint(
      'NewMsg[DM] chat=$normalized outgoing=$outgoing '
      'hasMamId=$hasMamId catchUpComplete=$catchUpComplete '
      'messageId=$messageId mamId=$mamId stanzaId=$stanzaId '
      'timestamp=$timestamp',
    );
    if (!outgoing && !hasMamId && catchUpComplete) {
      debugPrint(
        'NewMsg[DM] firing incomingMessageHandler for chat=$normalized '
        'messageId=$messageId',
      );
      _incomingMessageHandler?.call(normalized, newMessage);
    } else if (!outgoing) {
      debugPrint(
        'NewMsg[DM] suppressing incomingMessageHandler for chat=$normalized: '
        'outgoing=$outgoing hasMamId=$hasMamId catchUpComplete=$catchUpComplete',
      );
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
    String? replyToId,
    String? replyToJid,
    String? replyFallback,
  }) {
    final normalized = _bareJid(roomJid);
    final list = _roomMessages.putIfAbsent(normalized, () => <ChatMessage>[]);
    if (messageId != null && messageId.isNotEmpty) {
      final existingIndex = list.indexWhere(
        (message) =>
            message.messageId == messageId &&
            _bareJid(message.from) == _bareJid(from),
      );
      if (existingIndex != -1) {
        final existing = list[existingIndex];
        final nextMamId = (mamId != null && mamId.isNotEmpty)
            ? mamId
            : existing.mamId;
        final nextStanzaId = (stanzaId != null && stanzaId.isNotEmpty)
            ? stanzaId
            : existing.stanzaId;
        final nextReceiptReceived = (!outgoing && existing.outgoing)
            ? true
            : existing.receiptReceived;
        final nextTimestamp = (!outgoing && existing.outgoing)
            ? timestamp
            : existing.timestamp;
        final nextOobUrl = (oobUrl != null && oobUrl.isNotEmpty)
            ? oobUrl
            : existing.oobUrl;
        final nextRawXml = rawXml.isNotEmpty ? rawXml : existing.rawXml;
        final nextOobDescription =
            (oobDescription != null && oobDescription.isNotEmpty)
            ? oobDescription
            : existing.oobDescription;
        final nextReplyToId = (replyToId != null && replyToId.isNotEmpty)
            ? replyToId
            : existing.replyToId;
        final nextReplyToJid = (replyToJid != null && replyToJid.isNotEmpty)
            ? replyToJid
            : existing.replyToJid;
        final nextReplyFallback =
            (replyFallback != null && replyFallback.isNotEmpty)
            ? replyFallback
            : existing.replyFallback;
        if (nextMamId != existing.mamId ||
            nextStanzaId != existing.stanzaId ||
            nextReceiptReceived != existing.receiptReceived ||
            nextTimestamp != existing.timestamp ||
            nextOobUrl != existing.oobUrl ||
            nextOobDescription != existing.oobDescription ||
            nextRawXml != existing.rawXml ||
            nextReplyToId != existing.replyToId ||
            nextReplyToJid != existing.replyToJid ||
            nextReplyFallback != existing.replyFallback) {
          final updated = existing.copyWith(
            timestamp: nextTimestamp,
            mamId: nextMamId,
            stanzaId: nextStanzaId,
            oobUrl: nextOobUrl,
            oobDescription: nextOobDescription,
            rawXml: nextRawXml,
            replyToId: nextReplyToId,
            replyToJid: nextReplyToJid,
            replyFallback: nextReplyFallback,
            receiptReceived: nextReceiptReceived,
          );
          list.removeAt(existingIndex);
          _insertMessageOrdered(list, updated);
          notifyListeners();
          _roomMessagePersistor?.call(normalized, List.unmodifiable(list));
        }
        return;
      }
    }
    if (mamId != null &&
        mamId.isNotEmpty &&
        list.any((message) => message.mamId == mamId)) {
      return;
    }
    if (stanzaId != null &&
        stanzaId.isNotEmpty &&
        list.any((message) => message.stanzaId == stanzaId)) {
      return;
    }
    final prependOffset = _mamCursorStore.prependOffsetFor(normalized);
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
          replyToId: replyToId,
          replyToJid: replyToJid,
          replyFallback: replyFallback,
        ),
      );
      _mamCursorStore.incrementPrependOffset(normalized);
      // R1.3: resolve pending displayed-sync marker BEFORE notifyListeners so
      // that _displayedAtByChat is populated before the UI reads unread counts.
      _resolveDisplayedSyncPending(normalized, stanzaId);
      notifyListeners();
      _roomMessagePersistor?.call(normalized, List.unmodifiable(list));
      // R2.1: bump the global MAM-id anchor for prepended MAM messages.
      _bumpLastMamIdSeen(mamId);
      debugPrint(
        'NewMsg[MUC-prepend] chat=$normalized outgoing=$outgoing '
        'mamId=$mamId stanzaId=$stanzaId timestamp=$timestamp '
        'insertIndex=$insertIndex — will fire handler: ${!outgoing}',
      );
      if (!outgoing) {
        debugPrint(
          'NewMsg[MUC-prepend] firing incomingRoomMessageHandler for '
          'chat=$normalized mamId=$mamId (no catchup/cutoff check)',
        );
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
      replyToId: replyToId,
      replyToJid: replyToJid,
      replyFallback: replyFallback,
    );
    _insertMessageOrdered(list, newMessage);
    // R1.3: resolve pending displayed-sync marker BEFORE notifyListeners so
    // that _displayedAtByChat is populated before the UI reads unread counts.
    _resolveDisplayedSyncPending(normalized, stanzaId);
    notifyListeners();
    _roomMessagePersistor?.call(normalized, List.unmodifiable(list));
    // R2.1: bump the global MAM-id anchor.
    _bumpLastMamIdSeen(mamId);
    final hasMamIdRoom = mamId != null && mamId.isNotEmpty;
    final catchUpCompleteRoom = _isMamCatchUpComplete(normalized, isRoom: true);
    final shouldNotifyRoom = _shouldNotifyRoomMessage(normalized, timestamp);
    debugPrint(
      'NewMsg[MUC] chat=$normalized outgoing=$outgoing '
      'hasMamId=$hasMamIdRoom catchUpComplete=$catchUpCompleteRoom '
      'shouldNotifyRoom=$shouldNotifyRoom '
      'messageId=$messageId mamId=$mamId stanzaId=$stanzaId '
      'timestamp=$timestamp',
    );
    if (!outgoing && !hasMamIdRoom && catchUpCompleteRoom && shouldNotifyRoom) {
      debugPrint(
        'NewMsg[MUC] firing incomingRoomMessageHandler for chat=$normalized '
        'messageId=$messageId',
      );
      _incomingRoomMessageHandler?.call(normalized, newMessage);
    } else if (!outgoing) {
      debugPrint(
        'NewMsg[MUC] suppressing incomingRoomMessageHandler for chat=$normalized: '
        'outgoing=$outgoing hasMamId=$hasMamIdRoom '
        'catchUpComplete=$catchUpCompleteRoom shouldNotify=$shouldNotifyRoom',
      );
    }
  }

  bool _shouldNotifyRoomMessage(String roomJid, DateTime timestamp) {
    final cutoff = _roomHistoryCutoffAt[_bareJid(roomJid)];
    if (cutoff == null) {
      debugPrint(
        'NewMsg[MUC] _shouldNotifyRoomMessage: chat=$roomJid '
        'cutoff=null → true (no cutoff set)',
      );
      return true;
    }
    final result = timestamp.isAfter(cutoff);
    debugPrint(
      'NewMsg[MUC] _shouldNotifyRoomMessage: chat=$roomJid '
      'timestamp=$timestamp cutoff=$cutoff → $result',
    );
    return result;
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
    final insertIndex = list.indexWhere(
      (existing) => message.timestamp.isBefore(existing.timestamp),
    );
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
      list[i] = existing.copyWith(
        fileBytes: nextBytes,
        fileState: nextState,
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
      list[i] = existing.copyWith(
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
      list[i] = existing.copyWith(
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
      if (message.outgoing ||
          message.messageId == null ||
          message.messageId!.isEmpty) {
        continue;
      }
      final lastSent = _lastDisplayedMarkerIdByChat[normalized];
      if (lastSent == message.messageId) {
        return;
      }
      _lastDisplayedMarkerIdByChat[normalized] = message.messageId!;
      _sendMarker(normalized, message.messageId!, 'displayed');
      // Record that the XEP-0333 displayed marker has been sent for this message.
      if (!message.markerSent) {
        list[i] = message.copyWith(markerSent: true);
        _messagePersistor?.call(normalized, List.unmodifiable(list));
      }
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
      if (!message.outgoing &&
          message.stanzaId != null &&
          message.stanzaId!.isNotEmpty) {
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
    _storage?.storeDisplayedSync(
      Map<String, String>.from(_displayedStanzaIdByChat),
    );
    _storage?.storeDisplayedSyncTimestamps(
      Map<String, DateTime>.from(_displayedAtByChat),
    );
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    iqStanza.toJid = Jid.fromFullJid(_currentUserBareJid!);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final publish = XmppElement()..name = 'publish';
    publish.addAttribute(XmppAttribute('node', 'urn:xmpp:mds:displayed:0'));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', normalized));
    final displayed = XmppElement()..name = 'displayed';
    displayed.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:mds:displayed:0'));
    final stanzaIdElement = XmppElement()..name = 'stanza-id';
    stanzaIdElement.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sid:0'));
    stanzaIdElement.addAttribute(XmppAttribute('id', stanzaId));
    final byValue = isBookmark(normalized)
        ? normalized
        : (_currentUserBareJid ?? '');
    if (byValue.isNotEmpty) {
      stanzaIdElement.addAttribute(XmppAttribute('by', byValue));
    }
    displayed.addChild(stanzaIdElement);
    item.addChild(displayed);
    publish.addChild(item);
    pubsub.addChild(publish);
    // publish-options: set max_items=max so the server retains one item per
    // chat JID rather than overwriting a single global item (XEP-0490 §4).
    final publishOptions = XmppElement()..name = 'publish-options';
    final optForm = XmppElement()..name = 'x';
    optForm.addAttribute(XmppAttribute('xmlns', 'jabber:x:data'));
    optForm.addAttribute(XmppAttribute('type', 'submit'));
    XmppElement buildField(String varName, String value, {String? type}) {
      final f = XmppElement()..name = 'field';
      f.addAttribute(XmppAttribute('var', varName));
      if (type != null) f.addAttribute(XmppAttribute('type', type));
      final v = XmppElement()..name = 'value';
      v.textValue = value;
      f.addChild(v);
      return f;
    }
    optForm.addChild(buildField('FORM_TYPE',
        'http://jabber.org/protocol/pubsub#publish-options',
        type: 'hidden'));
    optForm.addChild(buildField('pubsub#persist_items', 'true'));
    optForm.addChild(buildField('pubsub#access_model', 'whitelist'));
    optForm.addChild(buildField('pubsub#send_last_published_item', 'never'));
    optForm.addChild(buildField('pubsub#max_items', 'max'));
    publishOptions.addChild(optForm);
    pubsub.addChild(publishOptions);
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
    notifyListeners();
  }

  void _ensureContact(
    String bareJid, {
    String? name,
    List<String>? groups,
    String? subscriptionType,
  }) {
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
    final nextName = (name != null && name.trim().isNotEmpty)
        ? name
        : existing.name;
    final nextGroups = (groups != null && groups.isNotEmpty)
        ? groups
        : existing.groups;
    final nextSubscription =
        (subscriptionType != null && subscriptionType.isNotEmpty)
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
    if (bookmark.jid.isNotEmpty &&
        bookmark.bookmarkPassword?.isNotEmpty == true) {
      return bookmark.bookmarkPassword;
    }
    return null;
  }

  void _requestRoomMam(
    String roomJid, {
    int max = 25,
    String? before,
    String? after,
    String? beforeId,
    String? afterId,
  }) {
    _dispatchMamPlan(
      isRoom: true,
      jid: roomJid,
      plan: MamQueryPlan(
        max: max,
        before: before,
        after: after,
        beforeId: beforeId,
        afterId: afterId,
      ),
    );
  }

  void _dispatchMamPlan({
    required bool isRoom,
    required String jid,
    required MamQueryPlan plan,
  }) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final mam = connection.getMamModule();
    if (!mam.enabled) {
      return;
    }
    final supportsMamExtended = _supportsMamExtendedQuery(
      connection,
      mam,
      isRoom: isRoom,
    );
    final beforeId = supportsMamExtended ? plan.beforeId : null;
    final afterId = supportsMamExtended ? plan.afterId : null;
    final before =
        !supportsMamExtended &&
            (plan.before == null || plan.before!.isEmpty) &&
            plan.beforeId != null &&
            plan.beforeId!.isNotEmpty
        ? plan.beforeId
        : plan.before;
    final after =
        !supportsMamExtended &&
            (plan.after == null || plan.after!.isEmpty) &&
            plan.afterId != null &&
            plan.afterId!.isNotEmpty
        ? plan.afterId
        : plan.after;
    final iqId = mam.queryById(
      jid: (!isRoom && plan.useWithJid) ? Jid.fromFullJid(jid) : null,
      toJid: isRoom ? Jid.fromFullJid(jid) : null,
      max: plan.max,
      before: before,
      after: after,
      beforeId: beforeId,
      afterId: afterId,
    );

    // For backwards page requests (before != null or beforeId != null), listen
    // for the fin result and mark the archive exhausted when complete=true.
    // This prevents the scroll handler from issuing further requests once the
    // server confirms there are no older messages.
    final isBackwardsPage =
        (before != null && before.isNotEmpty) ||
        (beforeId != null && beforeId.isNotEmpty) ||
        (plan.before != null && plan.before!.isEmpty); // initial page (before='')
    if (isBackwardsPage) {
      final router = IqRouter.getInstance(connection);
      router.registerResponseHandler(iqId, (response) {
        if (response.type != IqStanzaType.RESULT) {
          return;
        }
        final fin = response.children.firstWhere(
          (child) =>
              child.name == 'fin' &&
              child.getAttribute('xmlns')?.value == 'urn:xmpp:mam:2',
          orElse: () => XmppElement(),
        );
        if (fin.name != 'fin') {
          return;
        }
        final completeAttr = fin.getAttribute('complete')?.value;
        if (completeAttr == 'true' || completeAttr == '1') {
          _mamCoordinator.markArchiveExhausted(jid);
          Log.d(
            'XmppService',
            'MAM archive exhausted (complete=true) for $jid',
          );
        }
      });
    }
  }

  bool _supportsMamExtendedQuery(
    Connection connection,
    MessageArchiveManager mam, {
    required bool isRoom,
  }) {
    // Room archives are queried on room/service endpoints, but xmpp_stone's
    // negotiated MAM capabilities are connection-scoped. Until endpoint-scoped
    // disco is tracked for rooms, avoid using extended-only fields there.
    if (isRoom) {
      return false;
    }
    if (mam.hasExtended == true) {
      return true;
    }
    return connection.getSupportedFeatures().any(
      (feature) => feature.xmppVar == 'urn:xmpp:mam:2#extended',
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

  DateTime? _latestRoomTimestamp(String roomJid) {
    final messages = _roomMessages[_bareJid(roomJid)];
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
    _quicStatsTimer?.cancel();
    _quicStatsTimer = null;
    _quicRttHistory.clear();
    _quicLossHistory.clear();
    _lastQuicLostPackets = BigInt.zero;
    _csiIdleTimer?.cancel();
    _csiIdleTimer = null;
    _mucSelfPingTimer?.cancel();
    _mucSelfPingTimer = null;
    for (final timer in _mucSelfPingTimeouts.values) {
      timer.cancel();
    }
    _mucSelfPingTimeouts.clear();
    _pendingMucSelfPings.clear();
    _pendingPings.clear();
    _smNonzaSubscription?.cancel();
    _smNonzaSubscription = null;
    _pingSubscription?.cancel();
    _pingSubscription = null;
    _keepaliveStateSubscription?.cancel();
    _keepaliveStateSubscription = null;
    _keepaliveFailureSubscription?.cancel();
    _keepaliveFailureSubscription = null;
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
    _pendingRecentReactionRequests.clear();
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _reconnectStateSubscription?.cancel();
    _reconnectStateSubscription = null;
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
    _roomHistoryCutoffAt.clear();
    _lastDisplayedMarkerIdByChat.clear();
    _displayedStanzaIdByChat.clear();
    _displayedSyncPending.clear();
    _displayedAtByChat.clear();
    if (!preserveCache) {
      _recentReactionEmojis.clear();
    }
    _lastPingLatency = null;
    _lastPingAt = null;
    _carbonsEnabled = false;
    _csiInactive = false;
    _carbonsRequestId = null;
    _mamCursorStore.clear();
    for (final timer in _mamCatchUpTimers.values) {
      timer.cancel();
    }
    _mamCatchUpTimers.clear();
    _lastGlobalMamSyncAt = null;
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
    _vcardDisplayNames.clear();
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
    if (!parsed.isValid()) {
      return false;
    }
    return _hasValidBareJidStructure(parsed.userAtDomain);
  }

  bool _hasValidBareJidStructure(String bareJid) {
    final trimmed = bareJid.trim();
    if (trimmed.isEmpty || trimmed.contains(' ')) {
      return false;
    }
    final atIndex = trimmed.indexOf('@');
    if (atIndex <= 0 || atIndex != trimmed.lastIndexOf('@')) {
      return false;
    }
    final local = trimmed.substring(0, atIndex);
    final domain = trimmed.substring(atIndex + 1);
    if (local.isEmpty ||
        domain.isEmpty ||
        domain.startsWith('.') ||
        domain.endsWith('.') ||
        domain.contains('..')) {
      return false;
    }
    return true;
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

  String _mamScopeKey(String bareJid, {required bool isRoom}) {
    final normalized = _bareJid(bareJid);
    return isRoom ? 'room:$normalized' : normalized;
  }

  bool _isMamCatchUpComplete(String bareJid, {required bool isRoom}) {
    final scopeKey = _mamScopeKey(bareJid, isRoom: isRoom);
    return _mamCursorStore.isCatchUpComplete(scopeKey);
  }

  void _markMamCatchUpStarted(String bareJid, {required bool isRoom}) {
    final normalized = _bareJid(bareJid);
    final scopeKey = _mamScopeKey(normalized, isRoom: isRoom);
    final displayedId = _displayedStanzaIdByChat[normalized];
    if (displayedId == null || displayedId.isEmpty) {
      _mamCursorStore.clearCatchUpPending(scopeKey);
      return;
    }
    if (_displayedAtByChat.containsKey(normalized)) {
      _mamCursorStore.clearCatchUpPending(scopeKey);
      return;
    }
    _mamCursorStore.markCatchUpPending(scopeKey);
  }

  void _markMamCatchUpCompleted(String bareJid, {required bool isRoom}) {
    final scopeKey = _mamScopeKey(bareJid, isRoom: isRoom);
    if (_mamCursorStore.clearCatchUpPending(scopeKey)) {
      notifyListeners();
    }
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
        state == XmppConnectionState.StartTlsFailed;
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
      _selfVcardPhotoHash = normalizeVcardPhotoHash(state);
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
    debugPrint(
      'XMPP sending presence ${presence.showElement} ${presence.status ?? ''}',
    );
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
    caps.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/caps'),
    );
    caps.addAttribute(XmppAttribute('hash', _capsHash));
    caps.addAttribute(XmppAttribute('node', _capsNode));
    caps.addAttribute(XmppAttribute('ver', _capsVerValue()));
    return caps;
  }

  XmppElement _buildVcardUpdateElement() {
    final update = XmppElement()..name = 'x';
    update.addAttribute(XmppAttribute('xmlns', 'vcard-temp:x:update'));
    final hash = normalizeVcardPhotoHash(_selfVcardPhotoHash);
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
    final identities =
        SERVICE_DISCOVERY_IDENTITIES.map((identity) {
          return [
            identity['category'] ?? '',
            identity['type'] ?? '',
            identity['lang'] ?? '',
            identity['name'] ?? '',
          ];
        }).toList()..sort((a, b) {
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
    if (_csiOverrideMode == CsiOverrideMode.inactive) {
      _sendClientState(active: false);
      _csiIdleTimer?.cancel();
      _csiIdleTimer = null;
      return;
    }
    if (_csiOverrideMode == CsiOverrideMode.active) {
      _sendClientState(active: true);
      _csiIdleTimer?.cancel();
      _csiIdleTimer = null;
      return;
    }
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
    if (_csiOverrideMode != CsiOverrideMode.auto) {
      return;
    }
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
    if (connection == null || _carbonsRequestId != null || _carbonsEnabled) {
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

  void _requestMamOnOpen(String bareJid) {
    final normalized = _bareJid(bareJid);
    final existingMessages = _messages[normalized];
    if (existingMessages == null || existingMessages.isEmpty) {
      _requestMamInitial(normalized);
      return;
    }
    _startMamCatchUp(normalized, isRoom: false);
  }

  void _requestRoomMamOnOpen(String roomJid) {
    final normalized = _bareJid(roomJid);
    final existingMessages = _roomMessages[normalized];
    if (existingMessages == null || existingMessages.isEmpty) {
      _requestRoomMam(normalized, max: 25, before: '');
      return;
    }
    _startMamCatchUp(normalized, isRoom: true);
  }

  void _requestMamInitial(String bareJid) {
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
    _mamCoordinator.requestDmInitial(
      bareJid: normalized,
      hasMessages: existingMessages != null && existingMessages.isNotEmpty,
    );
  }

  void _startMamCatchUp(String bareJid, {required bool isRoom}) {
    _markMamCatchUpStarted(bareJid, isRoom: isRoom);
    _runMamCatchUpStep(bareJid, isRoom: isRoom);
  }

  void _runMamCatchUpStep(String bareJid, {required bool isRoom}) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final mam = connection.getMamModule();
    if (!mam.enabled) {
      return;
    }
    final normalized = _bareJid(bareJid);
    final latest = isRoom
        ? _latestRoomMamIdFor(normalized)
        : latestMamIdFor(normalized);
    final scopeKey = _mamScopeKey(normalized, isRoom: isRoom);
    final requestedLatest = _mamCoordinator.requestCatchUpStep(
      bareJid: normalized,
      isRoom: isRoom,
      seeded: isRoom
          ? _seededRoomMessageJids.contains(normalized)
          : _seededMessageJids.contains(normalized),
      latestMamId: latest,
      scopeKey: scopeKey,
      onFallback: () {
        if (isRoom) {
          _dispatchMamPlan(
            isRoom: true,
            jid: normalized,
            plan: MamQueryPlanner.initial(isRoom: true),
          );
        } else {
          _requestMamInitial(normalized);
        }
      },
    );
    if (requestedLatest == null || requestedLatest.isEmpty) {
      return;
    }
    _mamCatchUpTimers[scopeKey]?.cancel();
    _mamCatchUpTimers[scopeKey] = Timer(const Duration(seconds: 2), () {
      final nextLatest = isRoom
          ? _latestRoomMamIdFor(normalized)
          : latestMamIdFor(normalized);
      if (nextLatest != null &&
          nextLatest.isNotEmpty &&
          nextLatest != requestedLatest) {
        _runMamCatchUpStep(normalized, isRoom: isRoom);
      } else {
        _mamCatchUpTimers.remove(scopeKey);
        _finishMamSyncIfIdle();
      }
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

    // R2.1: When we have a global MAM anchor (_lastMamIdSeen), issue a single
    // unified catch-up query against the user's own server archive
    // (`afterId=_lastMamIdSeen`, no `to=` JID). The server returns all missed
    // DM messages across every contact in one paginated stream, which the
    // existing _addMessage routing dispatches to the correct chat by JID.
    // This replaces the O(N) per-chat fan-out with a single O(1) IQ.
    //
    // When _lastMamIdSeen is null (fresh install / first session) we fall back
    // to the per-chat fan-out so each chat still gets its initial tail.
    final anchor = _lastMamIdSeen;
    if (anchor != null && anchor.isNotEmpty) {
      _startUnifiedDmCatchUp(anchor);
    } else {
      // Fallback: no anchor yet — fan out per-chat as before.
      for (final entry in _messages.entries) {
        final bareJid = _bareJid(entry.key);
        if (isBookmark(bareJid)) {
          continue;
        }
        if (entry.value.isEmpty) {
          continue;
        }
        // R2.2: skip the catch-up query when MDS already proves we are
        // caught up to the displayed marker for this chat.
        if (!shouldFetchMamCatchUpForChat(
          displayedStanzaId: _displayedStanzaIdByChat[bareJid],
          latestLocalMamId: latestMamIdFor(bareJid),
          stanzaIdAtLatestMamId:
              _stanzaIdAtLatestMamId(bareJid, isRoom: false),
        )) {
          continue;
        }
        _startMamCatchUp(bareJid, isRoom: false);
      }
    }

    for (final bookmark in _bookmarks) {
      final roomJid = _bareJid(bookmark.jid);
      final roomMessages = _roomMessages[roomJid];
      if (roomMessages == null || roomMessages.isEmpty) {
        _requestRoomMam(roomJid, max: 25, before: '');
        continue;
      }
      // R2.2: same short-circuit for MUCs.
      if (!shouldFetchMamCatchUpForChat(
        displayedStanzaId: _displayedStanzaIdByChat[roomJid],
        latestLocalMamId: _latestRoomMamIdFor(roomJid),
        stanzaIdAtLatestMamId: _stanzaIdAtLatestMamId(roomJid, isRoom: true),
      )) {
        continue;
      }
      _startMamCatchUp(roomJid, isRoom: true);
    }
    _finishMamSyncIfIdle();
  }

  /// R2.1: Issue a single unified MAM catch-up query against the user's own
  /// server archive, starting after [anchor] (the globally newest MAM id we
  /// have seen). On completion the RSM `<last>` id is used to advance
  /// [_lastMamIdSeen] so the next session's anchor is up to date.
  ///
  /// The query is built manually so we can capture the IQ id and register an
  /// [IqRouter] response handler — [MessageArchiveManager.queryById] writes
  /// the stanza internally and does not expose the id.
  void _startUnifiedDmCatchUp(String anchor) {
    final connection = _connection;
    if (connection == null) {
      return;
    }

    // Build the MAM IQ: <iq type="set"><query xmlns="urn:xmpp:mam:2">
    //   <x type="submit"><field var="FORM_TYPE"…/><field var="after-id"…/>
    //   </x><set xmlns="…rsm"><max>50</max></set></query></iq>
    final id = AbstractStanza.getRandomId();
    final iq = IqStanza(id, IqStanzaType.SET);
    // No toJid — queries the user's own server archive.

    final query = XmppElement()..name = 'query';
    query.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:mam:2'));
    query.addAttribute(XmppAttribute('queryid', AbstractStanza.getRandomId()));

    final x = XmppElement()..name = 'x';
    x.addAttribute(
      XmppAttribute('xmlns', 'jabber:x:data'),
    );
    x.addAttribute(XmppAttribute('type', 'submit'));

    final formType = XmppElement()..name = 'field';
    formType.addAttribute(XmppAttribute('var', 'FORM_TYPE'));
    formType.addAttribute(XmppAttribute('type', 'hidden'));
    final formTypeValue = XmppElement()
      ..name = 'value'
      ..textValue = 'urn:xmpp:mam:2';
    formType.addChild(formTypeValue);
    x.addChild(formType);

    final afterIdField = XmppElement()..name = 'field';
    afterIdField.addAttribute(XmppAttribute('var', 'after-id'));
    final afterIdValue = XmppElement()
      ..name = 'value'
      ..textValue = anchor;
    afterIdField.addChild(afterIdValue);
    x.addChild(afterIdField);

    query.addChild(x);

    // RSM: request up to 50 messages per page.
    final set = XmppElement()..name = 'set';
    set.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/rsm'),
    );
    final max = XmppElement()
      ..name = 'max'
      ..textValue = '50';
    set.addChild(max);
    query.addChild(set);

    iq.addChild(query);

    // Register a response handler so we can advance _lastMamIdSeen once the
    // server returns the <fin> result.
    final router = IqRouter.getInstance(connection);
    router.registerResponseHandler(id, (response) {
      if (response.type != IqStanzaType.RESULT) {
        return;
      }
      // Parse <fin xmlns="urn:xmpp:mam:2"><set …><last>…</last></set></fin>
      final fin = response.children.firstWhere(
        (child) =>
            child.name == 'fin' &&
            child.getAttribute('xmlns')?.value == 'urn:xmpp:mam:2',
        orElse: () => XmppElement(),
      );
      if (fin.name != 'fin') {
        return;
      }
      final rsmSet = fin.children.firstWhere(
        (child) =>
            child.name == 'set' &&
            child.getAttribute('xmlns')?.value ==
                'http://jabber.org/protocol/rsm',
        orElse: () => XmppElement(),
      );
      if (rsmSet.name != 'set') {
        return;
      }
      final lastEl = rsmSet.children.firstWhere(
        (child) => child.name == 'last',
        orElse: () => XmppElement(),
      );
      final lastId = lastEl.name == 'last' ? lastEl.textValue?.trim() : null;
      if (lastId != null && lastId.isNotEmpty) {
        _bumpLastMamIdSeen(lastId);
      }
    });

    connection.writeStanza(iq);
  }

  /// Returns the stanza-id of the message in [bareJid]'s message list whose
  /// MAM id equals the chat's latest MAM id. Used by R2.2 to compare the
  /// displayed marker against the newest local message we have. Returns
  /// null when no local message has both a matching MAM id and a non-empty
  /// stanza-id.
  String? _stanzaIdAtLatestMamId(String bareJid, {required bool isRoom}) {
    final normalized = _bareJid(bareJid);
    final list = isRoom ? _roomMessages[normalized] : _messages[normalized];
    if (list == null || list.isEmpty) {
      return null;
    }
    final latestMamId = isRoom
        ? _latestRoomMamIdFor(normalized)
        : latestMamIdFor(normalized);
    if (latestMamId == null || latestMamId.isEmpty) {
      return null;
    }
    for (final message in list.reversed) {
      if (message.mamId == latestMamId) {
        final sid = message.stanzaId;
        if (sid != null && sid.isNotEmpty) {
          return sid;
        }
        return null;
      }
    }
    return null;
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

  void _requestVcardDetails(
    String bareJid, {
    required bool preferName,
    String? advertisedHash,
  }) {
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
    // R4.1: Skip the IQ entirely when we already have the bytes cached for
    // the advertised photo hash. `preferName == true` callers (e.g. self
    // vCard fetch on Ready, or contact list "show details") bypass the cache
    // because they want the FN/NICKNAME fields, not just the avatar.
    if (!shouldFetchVcardForCache(
      bareJid: bareJid,
      preferName: preferName,
      cachedAvatarBytes: _vcardAvatarBytes,
      cachedAvatarState: _vcardAvatarState,
      advertisedHash: advertisedHash,
    )) {
      return;
    }
    _vcardRequests.add(bareJid);
    final manager = VCardManager.getInstance(connection);
    manager
        .getVCardFor(Jid.fromFullJid(bareJid))
        .then((vcard) async {
          _vcardRequests.remove(bareJid);
          if (vcard is InvalidVCard) {
            _vcardUnavailable.add(bareJid);
            return;
          }
          _vcardUnavailable.remove(bareJid);
          _storeVcardDisplayName(bareJid, vcardDisplayName(vcard));
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
        })
        .catchError((_) {
          _vcardRequests.remove(bareJid);
        });
  }

  void _storeVcardDisplayName(String bareJid, String name) {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      return;
    }
    final existing = _vcardDisplayNames[bareJid];
    if (existing == normalizedName) {
      return;
    }
    _vcardDisplayNames[bareJid] = normalizedName;
    notifyListeners();
  }

  void _applyVcardToContact(
    String bareJid,
    VCard vcard, {
    required bool preferName,
  }) {
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
    final hash = normalizeVcardPhotoHash(photo?.textValue ?? '');
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
    // The centralised guard inside `_requestVcardDetails` (R4.1) handles the
    // "same hash & bytes already cached" case by short-circuiting. Pass the
    // advertised hash *before* mutating cached state so the guard can compare
    // it against the previously recorded hash and refetch when they differ.
    _vcardRequests.remove(bareJid);
    _requestVcardDetails(bareJid, preferName: false, advertisedHash: hash);
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
      final normalizedHash = normalizeVcardPhotoHash(hash);
      _selfVcardPhotoHash = normalizedHash;
      _selfVcardPhotoKnown = true;
      _vcardAvatarBytes[selfBareJid] = bytes;
      storage.storeVcardAvatar(selfBareJid, base64Encode(bytes));
      _vcardAvatarState[selfBareJid] = normalizedHash;
      storage.storeVcardAvatarState(selfBareJid, normalizedHash);
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
          child.getAttribute('xmlns')?.value ==
              'http://jabber.org/protocol/muc#user') {
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

  void _sendMucDefaultConfig(String roomJid) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    final iq = buildMucDefaultConfigIq(roomJid);
    connection.writeStanza(iq);
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
