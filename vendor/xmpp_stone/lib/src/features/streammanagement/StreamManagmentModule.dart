import 'dart:async';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:xmpp_stone/src/elements/nonzas/ANonza.dart';
import 'package:xmpp_stone/src/elements/nonzas/EnableNonza.dart';
import 'package:xmpp_stone/src/elements/nonzas/EnabledNonza.dart';
import 'package:xmpp_stone/src/elements/nonzas/FailedNonza.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/elements/nonzas/RNonza.dart';
import 'package:xmpp_stone/src/elements/nonzas/ResumeNonza.dart';
import 'package:xmpp_stone/src/elements/nonzas/ResumedNonza.dart';
import 'package:xmpp_stone/src/elements/nonzas/SMNonza.dart';
import 'package:xmpp_stone/src/elements/stanzas/AbstractStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';
import 'package:xmpp_stone/src/features/streammanagement/KeepaliveState.dart';
import 'package:xmpp_stone/src/features/streammanagement/StreamState.dart';

import '../../../xmpp_stone.dart';
import '../Negotiator.dart';

class StreamManagementModule extends Negotiator {
  static const TAG = 'StreamManagementModule';

  // Defaults are exposed as `static const` so callers (e.g. a settings
  // control panel) can offer a "reset to defaults" action without having to
  // hard-code the values themselves.
  static const Duration defaultSmAckIntervalForeground = Duration(minutes: 1);
  static const Duration defaultSmAckIntervalBackground = Duration(minutes: 5);
  static const Duration defaultPingIntervalForeground = Duration(seconds: 30);
  static const Duration defaultPingIntervalBackground = Duration(minutes: 5);
  static const Duration defaultPendingAckRequestDelay = Duration(seconds: 15);
  static const Duration defaultKeepaliveMaxTimeout = Duration(seconds: 30);

  // Mutable copies of the above, adjustable at runtime via [configure] so a
  // control panel can tune keepalive cadence without restarting the app.
  Duration _smAckIntervalForeground = defaultSmAckIntervalForeground;
  Duration _smAckIntervalBackground = defaultSmAckIntervalBackground;
  Duration _pingIntervalForeground = defaultPingIntervalForeground;
  Duration _pingIntervalBackground = defaultPingIntervalBackground;
  Duration _pendingAckRequestDelay = defaultPendingAckRequestDelay;
  Duration _keepaliveMaxTimeout = defaultKeepaliveMaxTimeout;

  static Map<Connection, StreamManagementModule> instances = {};

  static StreamManagementModule getInstance(Connection connection) {
    var module = instances[connection];
    if (module == null) {
      module = StreamManagementModule(connection);
      instances[connection] = module;
    }
    return module;
  }

  static void removeInstance(Connection connection) {
    var instance = instances[connection];
    instance?._disposeRuntime();
    instance?._xmppConnectionStateSubscription.cancel();
    instance?._deliveredStanzasStreamController.close();
    instance?._keepaliveStateController.close();
    instance?._keepaliveFailureController.close();
    instances.remove(connection);
  }

  StreamState streamState = StreamState();
  final Connection _connection;
  late StreamSubscription<XmppConnectionState> _xmppConnectionStateSubscription;
  StreamSubscription<AbstractStanza?>? inStanzaSubscription;
  StreamSubscription<AbstractStanza>? outStanzaSubscription;
  StreamSubscription<AbstractStanza?>? _keepaliveIqSubscription;
  StreamSubscription<Nonza>? inNonzaSubscription;

  bool ackTurnedOn = true;
  bool _backgroundMode = false;
  Timer? _keepaliveTimer;
  Timer? _pendingAckRequestTimer;
  Timer? _pendingSmAckTimer;
  Timer? _pendingPingTimer;
  int lastAckSent = 0;
  DateTime? _pendingSmAckAt;
  DateTime? _pendingPingAt;
  String? _pendingPingId;
  Duration? _lastKeepaliveLatency;
  DateTime? _lastKeepaliveSuccessAt;
  DateTime? _lastKeepaliveFailureAt;

  final StreamController<AbstractStanza> _deliveredStanzasStreamController =
      StreamController.broadcast();
  final StreamController<KeepaliveState> _keepaliveStateController =
      StreamController.broadcast();
  final StreamController<KeepaliveFailure> _keepaliveFailureController =
      StreamController.broadcast();

  Stream<AbstractStanza> get deliveredStanzasStream {
    return _deliveredStanzasStreamController.stream;
  }

  Stream<KeepaliveState> get keepaliveStateStream {
    return _keepaliveStateController.stream;
  }

  Stream<KeepaliveFailure> get keepaliveFailureStream {
    return _keepaliveFailureController.stream;
  }

  Duration? get lastKeepaliveLatency => _lastKeepaliveLatency;

  /// Current keepalive/ping tuning, exposed so a control panel can display
  /// the effective values (including any overrides applied via [configure]).
  Duration get smAckIntervalForeground => _smAckIntervalForeground;
  Duration get smAckIntervalBackground => _smAckIntervalBackground;
  Duration get pingIntervalForeground => _pingIntervalForeground;
  Duration get pingIntervalBackground => _pingIntervalBackground;
  Duration get pendingAckRequestDelay => _pendingAckRequestDelay;
  Duration get keepaliveMaxTimeout => _keepaliveMaxTimeout;

  /// Overrides keepalive/ping cadence at runtime. Any parameter left `null`
  /// keeps its current value. Passing no arguments is a no-op. The active
  /// keepalive timer is restarted so a new foreground/background interval
  /// takes effect immediately instead of waiting for the next tick.
  void configure({
    Duration? smAckIntervalForeground,
    Duration? smAckIntervalBackground,
    Duration? pingIntervalForeground,
    Duration? pingIntervalBackground,
    Duration? pendingAckRequestDelay,
    Duration? keepaliveMaxTimeout,
  }) {
    if (smAckIntervalForeground != null) {
      _smAckIntervalForeground = smAckIntervalForeground;
    }
    if (smAckIntervalBackground != null) {
      _smAckIntervalBackground = smAckIntervalBackground;
    }
    if (pingIntervalForeground != null) {
      _pingIntervalForeground = pingIntervalForeground;
    }
    if (pingIntervalBackground != null) {
      _pingIntervalBackground = pingIntervalBackground;
    }
    if (pendingAckRequestDelay != null) {
      _pendingAckRequestDelay = pendingAckRequestDelay;
    }
    if (keepaliveMaxTimeout != null) {
      _keepaliveMaxTimeout = keepaliveMaxTimeout;
    }
    Log.i(
      TAG,
      'Keepalive tuning updated: smAckFg=${_smAckIntervalForeground.inSeconds}s '
      'smAckBg=${_smAckIntervalBackground.inSeconds}s '
      'pingFg=${_pingIntervalForeground.inSeconds}s '
      'pingBg=${_pingIntervalBackground.inSeconds}s '
      'pendingAckDelay=${_pendingAckRequestDelay.inSeconds}s '
      'maxTimeout=${_keepaliveMaxTimeout.inSeconds}s',
    );
    _restartKeepaliveTimer();
  }

  StreamManagementModule(this._connection) {
    _connection.streamManagementModule = this;
    ackTurnedOn = _connection.account.ackEnabled;
    expectedName = 'StreamManagementModule';
    _keepaliveIqSubscription = _connection.inStanzasStream.listen(
      _handleKeepaliveIq,
    );
    _xmppConnectionStateSubscription =
        _connection.connectionStateStream.listen(_handleConnectionState);
  }

  @override
  List<Nonza> match(List<Nonza> requests) {
    var nonza = requests.firstWhereOrNull((request) => SMNonza.match(request));
    return nonza != null ? [nonza] : [];
  }

  @override
  void negotiate(List<Nonza> nonzas) {
    // Per XEP-0467 §Stream Management: XEP-0198 cannot apply to QUIC
    // connections, and "MUST NOT be advertised or negotiated" over QUIC.
    // QUIC provides its own per-stream reliability and ordering at the
    // transport layer, so SM's resumption / per-stanza acknowledgement
    // machinery is redundant (and would in fact misbehave across the
    // multiple aux streams introduced by XEP-0467 §Multiple Streams).
    //
    // We never emit `<enable/>` on QUIC and we ignore any `<sm/>` feature
    // the server might still advertise. The doap.xml entry for XEP-0198
    // remains because we DO support SM on TCP — only the QUIC path opts out.
    //
    // We must still transition to DONE so the negotiator queue advances
    // (otherwise the connection never reaches Ready post-bind).
    if (_connection.isQuic) {
      state = NegotiatorState.DONE;
      return;
    }
    if (nonzas.isNotEmpty &&
        SMNonza.match(nonzas[0]) &&
        _connection.authenticated) {
      state = NegotiatorState.NEGOTIATING;
      inNonzaSubscription ??= _connection.inNonzasStream.listen(parseNonza);
      if (streamState.isResumeAvailable()) {
        tryToResumeStream();
      } else {
        sendEnableStreamManagement();
      }
    }
  }

  @override
  bool isReady() {
    // Over QUIC, SM is skipped but we must still report ready so that
    // negotiate() is called and can advance the negotiator queue to DONE.
    if (_connection.isQuic) return true;
    return super.isReady() &&
        (isResumeAvailable() ||
            (_connection.fullJid.resource != null &&
                _connection.fullJid.resource!.isNotEmpty));
  }

  void parseNonza(Nonza nonza) {
    if (state == NegotiatorState.NEGOTIATING) {
      if (EnabledNonza.match(nonza)) {
        handleEnabled(nonza);
      } else if (ResumedNonza.match(nonza)) {
        resumeState(nonza);
      } else if (FailedNonza.match(nonza)) {
        if (streamState.tryingToResume) {
          Log.d(
            TAG,
            'Resuming failed recv=${streamState.lastReceivedStanza} ackSent=$lastAckSent',
          );
          streamState = StreamState();
          lastAckSent = 0;
          _pendingAckRequestTimer?.cancel();
          _pendingAckRequestTimer = null;
          inStanzaSubscription?.cancel();
          outStanzaSubscription?.cancel();
          inStanzaSubscription = null;
          outStanzaSubscription = null;
          state = NegotiatorState.DONE;
          negotiatorStateStreamController = StreamController();
          state = NegotiatorState.IDLE;
          _restartKeepaliveTimer();
        } else {
          Log.d(TAG, 'StreamManagmentFailed');
          state = NegotiatorState.DONE;
          _restartKeepaliveTimer();
        }
      }
      return;
    }

    if (ANonza.match(nonza)) {
      parseAckResponse(nonza.getAttribute('h')!.value!);
      _handleSmAckResponse();
      return;
    }
    if (RNonza.match(nonza)) {
      sendAckResponse();
    }
  }

  void parseOutStanza(AbstractStanza stanza) {
    streamState.lastSentStanza++;
    streamState.nonConfirmedSentStanzas.addLast(stanza);
    _schedulePendingAckRequest();
  }

  void parseInStanza(AbstractStanza? stanza) {
    if (stanza == null) {
      return;
    }
    streamState.lastReceivedStanza++;
    Log.d(
      TAG,
      'SM recv h=${streamState.lastReceivedStanza} lastAckSent=$lastAckSent stanza=${stanza.name}',
    );
  }

  void handleEnabled(Nonza nonza) {
    streamState.streamManagementEnabled = true;
    var resume = nonza.getAttribute('resume');
    if (resume != null && resume.value == 'true') {
      streamState.streamResumeEnabled = true;
      streamState.id = nonza.getAttribute('id')!.value;
    }
    resetRuntimeCounters();
    Log.d(
      TAG,
      'SM enabled resume=${streamState.streamResumeEnabled} recv=${streamState.lastReceivedStanza} ackSent=$lastAckSent',
    );
    state = NegotiatorState.DONE;
    outStanzaSubscription?.cancel();
    inStanzaSubscription?.cancel();
    outStanzaSubscription = _connection.outStanzasStream.listen(parseOutStanza);
    inStanzaSubscription = _connection.inStanzasStream.listen(parseInStanza);
    _restartKeepaliveTimer();
    _emitKeepaliveState();
  }

  void handleResumed(Nonza nonza) {
    parseAckResponse(nonza.getAttribute('h')!.value!);
    state = NegotiatorState.DONE;
    _restartKeepaliveTimer();
    Log.d(
      TAG,
      'SM resumed recv=${streamState.lastReceivedStanza} ackSent=$lastAckSent',
    );
    _emitKeepaliveState();
  }

  void sendEnableStreamManagement() =>
      _connection.writeNonza(EnableNonza(_connection.account.smResumable));

  void sendAckResponse() => _sendAckResponseWithLog();

  void sendAckRequest({bool force = false, bool shortTimeout = false}) {
    if (!ackTurnedOn) {
      return;
    }
    if (!_connection.isOpened()) {
      return;
    }
    if (_pendingSmAckAt != null && !force) {
      if (shortTimeout) {
        _scheduleSmAckTimeout(shortTimeout: true);
      }
      return;
    }
    _connection.writeNonza(RNonza());
    _pendingSmAckAt = DateTime.now();
    _scheduleSmAckTimeout(shortTimeout: shortTimeout);
    _emitKeepaliveState();
  }

  /// Switches keepalive cadence between foreground and background intervals.
  void setBackgroundMode(bool enabled) {
    if (_backgroundMode == enabled) {
      return;
    }
    _backgroundMode = enabled;
    _restartKeepaliveTimer();
    _emitKeepaliveState();
  }

  /// Triggers an immediate keepalive probe.
  ///
  /// Uses XEP-0198 ack probes when SM is enabled, otherwise falls back to
  /// XEP-0199 ping probes.
  void probeKeepalive({bool shortTimeout = false}) {
    if (!_connection.isOpened()) {
      return;
    }
    // QUIC has transport-level PINGs, and XEP-0198 does not apply to it.
    // More importantly, an IQ response may arrive on another XEP-0467 stream
    // and never reach this module's inStanzasStream subscription. Treating
    // that as a dead connection would force-close a healthy QUIC session.
    if (_connection.isQuic) {
      Log.d(
        TAG,
        'Ignoring XMPP keepalive probe on QUIC connection; '
        'transport keepalive is active',
      );
      return;
    }
    if (_isSmEnabled()) {
      sendAckRequest(force: true, shortTimeout: shortTimeout);
      return;
    }
    _sendPing(shortTimeout: shortTimeout);
  }

  /// Clears runtime stream management counters and pending keepalive state.
  void resetRuntimeCounters() {
    streamState.lastSentStanza = 0;
    streamState.lastReceivedStanza = 0;
    streamState.nonConfirmedSentStanzas.clear();
    streamState.tryingToResume = false;
    lastAckSent = 0;
    _pendingAckRequestTimer?.cancel();
    _pendingAckRequestTimer = null;
    _clearPendingSmAck();
    _clearPendingPing();
    _emitKeepaliveState();
  }

  void _sendAckResponseWithLog() {
    lastAckSent = streamState.lastReceivedStanza;
    Log.d(
      TAG,
      'SM ack send h=$lastAckSent lastRecv=${streamState.lastReceivedStanza}',
    );
    _connection.writeNonza(ANonza(lastAckSent));
    if (ackTurnedOn &&
        _pendingAckRequestTimer != null &&
        _pendingAckRequestTimer!.isActive) {
      _pendingAckRequestTimer!.cancel();
      Log.d(TAG, 'Early r because we received an ack');
      sendAckRequest();
    }
  }

  void tryToResumeStream() {
    if (!streamState.tryingToResume) {
      _connection.writeNonza(
        ResumeNonza(streamState.id, streamState.lastReceivedStanza),
      );
      streamState.tryingToResume = true;
    }
  }

  void resumeState(Nonza resumedNonza) {
    streamState.tryingToResume = false;
    state = NegotiatorState.DONE_CLEAN_OTHERS;
    _connection.setState(XmppConnectionState.Resumed);
    handleResumed(resumedNonza);
  }

  bool isResumeAvailable() => streamState.isResumeAvailable();

  void reset() {
    negotiatorStateStreamController = StreamController();
    backToIdle();
  }

  void parseAckResponse(String rawValue) {
    var lastDeliveredStanza = int.parse(rawValue);
    var shouldStay = streamState.lastSentStanza - lastDeliveredStanza;
    if (shouldStay < 0) {
      shouldStay = 0;
    }
    while (streamState.nonConfirmedSentStanzas.length > shouldStay) {
      var stanza =
          streamState.nonConfirmedSentStanzas.removeFirst() as AbstractStanza;
      if (ackTurnedOn) {
        _deliveredStanzasStreamController.add(stanza);
      }
      if (stanza.id != null) {
        Log.d(TAG, 'Delivered: ${stanza.id}');
      } else {
        Log.d(TAG, 'Delivered stanza without id ${stanza.name}');
      }
    }
  }

  void _schedulePendingAckRequest() {
    if (!ackTurnedOn || !_isSmEnabled()) {
      return;
    }
    if (_pendingAckRequestTimer?.isActive == true) {
      return;
    }
    _pendingAckRequestTimer = Timer(_pendingAckRequestDelay, () {
      _pendingAckRequestTimer = null;
      if (streamState.nonConfirmedSentStanzas.isNotEmpty) {
        sendAckRequest();
      }
    });
  }

  void _handleConnectionState(XmppConnectionState state) {
    if (state == XmppConnectionState.Reconnecting) {
      backToIdle();
    }
    final sessionReady = state == XmppConnectionState.Ready ||
        state == XmppConnectionState.Resumed;
    if (!sessionReady) {
      _keepaliveTimer?.cancel();
      _keepaliveTimer = null;
      _pendingAckRequestTimer?.cancel();
      _pendingAckRequestTimer = null;
      _clearPendingSmAck();
      _clearPendingPing();
      _emitKeepaliveState();
    }
    if (state == XmppConnectionState.Closed) {
      streamState = StreamState();
      lastAckSent = 0;
      Log.d(TAG, 'SM reset on Closed: recv=0 ackSent=0');
      _pendingAckRequestTimer?.cancel();
      _pendingAckRequestTimer = null;
      inStanzaSubscription?.cancel();
      outStanzaSubscription?.cancel();
      inStanzaSubscription = null;
      outStanzaSubscription = null;
      _clearPendingSmAck();
      _clearPendingPing();
      _emitKeepaliveState();
      return;
    }
    if (sessionReady) {
      // On QUIC, XEP-0198 SM is disabled (see negotiate()), so there is no
      // SM ack machinery.  QUIC also has its own transport-level keepalive
      // (PING frames, configured in flutter_quic's endpoint.rs), so we do
      // not need — and must not start — the XMPP-level ping keepalive timer
      // here.  Starting it would fire a ping every 30 s whose reply is never
      // matched (the IQ router does not see the reply on QUIC), causing a
      // keepaliveTimeout reconnect loop every ~60 s.
      if (_connection.isQuic) return;
      _restartKeepaliveTimer();
      probeKeepalive(shortTimeout: false);
    }
  }

  void _restartKeepaliveTimer() {
    _keepaliveTimer?.cancel();
    if (!_connection.isOpened()) {
      return;
    }
    final interval = _currentProbeInterval();
    _keepaliveTimer = Timer.periodic(interval, (_) {
      _tickKeepalive();
    });
  }

  Duration _currentProbeInterval() {
    if (_isSmEnabled()) {
      return _backgroundMode
          ? _smAckIntervalBackground
          : _smAckIntervalForeground;
    }
    return _backgroundMode ? _pingIntervalBackground : _pingIntervalForeground;
  }

  bool _isSmEnabled() {
    return streamState.streamManagementEnabled;
  }

  void _tickKeepalive() {
    if (!_connection.isOpened()) {
      return;
    }
    if (_isSmEnabled()) {
      sendAckRequest();
      return;
    }
    _sendPing();
  }

  void _handleSmAckResponse() {
    final startedAt = _pendingSmAckAt;
    if (startedAt == null) {
      return;
    }
    _pendingSmAckAt = null;
    _pendingSmAckTimer?.cancel();
    _pendingSmAckTimer = null;
    _handleKeepaliveSuccess(DateTime.now().difference(startedAt));
  }

  void _scheduleSmAckTimeout({required bool shortTimeout}) {
    _pendingSmAckTimer?.cancel();
    _pendingSmAckTimer = Timer(
      _keepaliveTimeout(shortTimeout: shortTimeout),
      () => _handleSmAckTimeout(shortTimeout: shortTimeout),
    );
  }

  void _handleSmAckTimeout({required bool shortTimeout}) {
    if (_pendingSmAckAt == null) {
      return;
    }
    _clearPendingSmAck();
    _handleKeepaliveFailure(
      KeepaliveFailureReason.smAckTimeout,
      shortTimeout: shortTimeout,
    );
    if (_pendingPingAt == null) {
      _sendPing(shortTimeout: shortTimeout);
    }
  }

  void _sendPing({bool shortTimeout = false}) {
    if (!_connection.isOpened()) {
      return;
    }
    if (_pendingPingAt != null) {
      return;
    }
    final domain = _connection.serverName.userAtDomain;
    if (domain.isEmpty) {
      return;
    }
    final id = AbstractStanza.getRandomId();
    final stanza = IqStanza(id, IqStanzaType.GET);
    stanza.toJid = Jid.fromFullJid(domain);
    final ping = XmppElement()..name = 'ping';
    ping.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:ping'));
    stanza.addChild(ping);
    _pendingPingId = id;
    _pendingPingAt = DateTime.now();
    final timeout = _keepaliveTimeout(shortTimeout: shortTimeout);
    // H1: log the ping ID and timeout so we can correlate which ping times out.
    // H2: log whether we are on a QUIC connection; the IQ router may not route
    //     ping replies from aux QUIC streams back to inStanzasStream, in which
    //     case the reply can never be seen and the timeout will always fire.
    Log.d(
      TAG,
      'Keepalive ping sent id=$id timeout=${timeout.inMilliseconds}ms '
      'lastLatency=${_lastKeepaliveLatency?.inMilliseconds}ms '
      'shortTimeout=$shortTimeout '
      'isQuic=${_connection.isQuic}',
    );
    _pendingPingTimer = Timer(
      timeout,
      () => _handlePingTimeout(shortTimeout: shortTimeout),
    );
    _connection.writeStanza(stanza);
    _emitKeepaliveState();
  }

  void _handleKeepaliveIq(AbstractStanza? stanza) {
    if (stanza is! IqStanza) {
      return;
    }
    final pendingId = _pendingPingId;
    // H2: log every IQ that arrives while a ping is pending so we can see
    //     whether the ping reply arrives but with the wrong ID, or never arrives
    //     at all (indicating the reply is swallowed before reaching this stream).
    if (pendingId != null) {
      Log.d(
        TAG,
        'Keepalive IQ check: incoming id=${stanza.id} type=${stanza.type} '
        'pendingId=$pendingId match=${stanza.id == pendingId}',
      );
    }
    if (pendingId == null || stanza.id != pendingId) {
      return;
    }
    if (stanza.type != IqStanzaType.RESULT &&
        stanza.type != IqStanzaType.ERROR) {
      return;
    }
    final startedAt = _pendingPingAt;
    _clearPendingPing();
    if (startedAt == null) {
      return;
    }
    _handleKeepaliveSuccess(DateTime.now().difference(startedAt));
  }

  void _handlePingTimeout({required bool shortTimeout}) {
    if (_pendingPingAt == null) {
      return;
    }
    // H1 + H2: log timeout details — this tells us the actual elapsed time
    //          and whether we are on QUIC (where replies may never arrive).
    final elapsed = _pendingPingAt != null
        ? DateTime.now().difference(_pendingPingAt!)
        : null;
    Log.w(
      TAG,
      'Keepalive ping timed out id=$_pendingPingId '
      'elapsed=${elapsed?.inMilliseconds}ms '
      'shortTimeout=$shortTimeout '
      'isQuic=${_connection.isQuic}',
    );
    _clearPendingPing();
    _handleKeepaliveFailure(
      KeepaliveFailureReason.pingTimeout,
      shortTimeout: shortTimeout,
    );
  }

  void _handleKeepaliveSuccess(Duration latency) {
    _lastKeepaliveLatency = latency;
    _lastKeepaliveSuccessAt = DateTime.now();
    _emitKeepaliveState();
  }

  void _handleKeepaliveFailure(
    KeepaliveFailureReason reason, {
    required bool shortTimeout,
  }) {
    _lastKeepaliveFailureAt = DateTime.now();
    _lastKeepaliveLatency = null;
    _keepaliveFailureController.add(
      KeepaliveFailure(
        reason: reason,
        shortTimeout: shortTimeout,
        occurredAt: _lastKeepaliveFailureAt!,
      ),
    );
    if (reason == KeepaliveFailureReason.pingTimeout) {
      _connection.requestReconnect(
        reason: ReconnectionReason.keepaliveTimeout,
        immediate: true,
        shortTimeout: shortTimeout,
      );
    }
    _emitKeepaliveState();
  }

  Duration _keepaliveTimeout({required bool shortTimeout}) {
    final base = _lastKeepaliveLatency ?? Duration.zero;
    final multiplier = shortTimeout ? 5 : 10;
    final scaled = base * multiplier;
    final floor = Duration(seconds: shortTimeout ? 5 : 10);
    final candidate = scaled > floor ? scaled : floor;
    final result =
        candidate > _keepaliveMaxTimeout ? _keepaliveMaxTimeout : candidate;
    // H1: log the computed timeout and the latency it was based on, so we can
    //     confirm that a zero/missing latency baseline is causing the 10 s floor
    //     to be used on the very first probe after connection.
    Log.d(
      TAG,
      'Keepalive timeout computed: result=${result.inMilliseconds}ms '
      'base=${base.inMilliseconds}ms multiplier=$multiplier '
      'floor=${floor.inMilliseconds}ms shortTimeout=$shortTimeout',
    );
    return result;
  }

  void _clearPendingSmAck() {
    _pendingSmAckAt = null;
    _pendingSmAckTimer?.cancel();
    _pendingSmAckTimer = null;
  }

  void _clearPendingPing() {
    _pendingPingId = null;
    _pendingPingAt = null;
    _pendingPingTimer?.cancel();
    _pendingPingTimer = null;
  }

  void _emitKeepaliveState() {
    _keepaliveStateController.add(
      KeepaliveState(
        healthy: _lastKeepaliveFailureAt == null ||
            (_lastKeepaliveSuccessAt != null &&
                _lastKeepaliveSuccessAt!.isAfter(_lastKeepaliveFailureAt!)),
        smEnabled: _isSmEnabled(),
        backgroundMode: _backgroundMode,
        awaitingSmAck: _pendingSmAckAt != null,
        awaitingPing: _pendingPingAt != null,
        lastLatency: _lastKeepaliveLatency,
        lastSuccessAt: _lastKeepaliveSuccessAt,
        lastFailureAt: _lastKeepaliveFailureAt,
      ),
    );
  }

  void _disposeRuntime() {
    _keepaliveTimer?.cancel();
    _pendingAckRequestTimer?.cancel();
    _clearPendingSmAck();
    _clearPendingPing();
    _keepaliveIqSubscription?.cancel();
    inNonzaSubscription?.cancel();
    outStanzaSubscription?.cancel();
    inStanzaSubscription?.cancel();
  }
}
