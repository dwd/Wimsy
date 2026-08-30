import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';
// ignore_for_file: implementation_imports

import 'package:flutter_quic/flutter_quic.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketIo.dart';
import 'package:xmpp_stone/src/connection/XmppStreamRouting.dart';
import 'package:xmpp_stone/src/logger/Log.dart';
import 'dns_cache.dart';

export 'package:xmpp_stone/src/connection/XmppStreamRouting.dart'
    show bareJidForRouting, extractToBareJidForRouting, isStanzaPayload;

/// Result of a QUIC connection migration attempt.
enum MigrationResult { success, failed }

class QuicCapableXmppSocket extends XmppWebSocket {
  QuicCapableXmppSocket({
    this.quicConnectTimeout = const Duration(seconds: 15),
    this.happyEyeballsDelay = const Duration(milliseconds: 250),
    this.quicConnectMaxAttempts = 3,
    this.quicConnectParallelAttempts = 1,
    this.migrationProbeTimeout = const Duration(seconds: 15),
    this.migrationProbeInterval = const Duration(seconds: 1),
  });

  final Duration quicConnectTimeout;
  final Duration happyEyeballsDelay;

  /// How many times to retry the full Happy Eyeballs round (across all
  /// candidate addresses) before giving up. Each retry races every
  /// candidate again with a fresh staggered start.
  final int quicConnectMaxAttempts;

  /// How many parallel connection attempts to launch per candidate address
  /// within each Happy Eyeballs round. Under high packet loss the first QUIC
  /// Initial packet may be dropped before Quinn's internal retransmit fires;
  /// launching [quicConnectParallelAttempts] copies of each attempt (staggered
  /// by [happyEyeballsDelay]) ensures that at least one Initial packet reaches
  /// the server even on very lossy paths.
  final int quicConnectParallelAttempts;

  /// Maximum time to wait for traffic proving the rebound UDP path works.
  /// Exposed for testing so tests can use a short timeout.
  @visibleForTesting
  final Duration migrationProbeTimeout;

  /// Interval between explicit ack-eliciting PINGs on the replacement path.
  @visibleForTesting
  final Duration migrationProbeInterval;

  /// Override for [endpointRebindToCurrentAddress] used in tests to avoid
  /// real FFI calls.  When null the real FFI function is used.
  @visibleForTesting
  Future<void> Function(QuicEndpoint endpoint)? rebindOverride;
  @visibleForTesting
  Future<void> Function(QuicConnection connection)? migrationPingOverride;
  final XmppWebSocketIo _fallbackSocket = XmppWebSocketIo(
    hostLookup: resolveHostCached,
  );
  final StreamController<String> _quicStreamController =
      StreamController<String>.broadcast();

  static Future<void>? _rustInitFuture;
  static bool _rustInitialized = false;
  static const int _auxStreamSlots = 20;
  static const int _maxControlBufferChars = 16 * 1024;

  bool _useQuic = false;
  bool _closed = false;
  int _connectionGeneration = 0;
  int? _activeAttemptId;
  bool _postBindReady = false;
  // Set to true when connectionOpenBi times out (peer has not granted bidi
  // stream credits). Cleared when we detect the server has sent a new
  // MAX_STREAMS frame (frameRx.maxStreamsBidi increases in connectionStats).
  bool _auxStreamsBlocked = false;
  // The frameRx.maxStreamsBidi count the last time we checked stats. Used to
  // detect when the server sends a new MAX_STREAMS(bidi) frame.
  BigInt _lastMaxStreamsBidiFrameCount = BigInt.zero;
  Timer? _maxStreamsWatchTimer;
  // Periodic timer that sends QUIC PING frames to keep the connection alive.
  // The interval is set to half the effective idle timeout (min of QUIC and
  // XMPP advertised timeouts, or 5 minutes if neither is advertised).
  Timer? _pingTimer;
  // The negotiated QUIC idle timeout in milliseconds, or null if infinite.
  // Populated after connect by _logPeerTransportParams.
  int? _quicNegotiatedIdleTimeoutMs;
  DateTime? _quicConnectedAt;
  DateTime? _lastQuicReceiveAt;
  DateTime? _lastQuicSendAt;
  DateTime? _lastQuicPingAt;
  Future<MigrationResult>? _migrationFuture;
  final Set<Future<void>> _loserCleanupTasks = <Future<void>>{};
  static final QuicAddressHealth _addressHealth = QuicAddressHealth();

  /// Identifies the currently active logical connection attempt. Async work
  /// captures this value and must stop before mutating state when it changes.
  @visibleForTesting
  int get connectionGeneration => _connectionGeneration;

  bool _isCurrentGeneration(int generation) =>
      !_closed && generation == _connectionGeneration;

  String get _activeAttemptContext =>
      quicAttemptLogContext(_connectionGeneration, _activeAttemptId ?? 0);

  @visibleForTesting
  int beginConnectionGenerationForTesting() {
    _closed = false;
    return ++_connectionGeneration;
  }

  @visibleForTesting
  bool isConnectionGenerationCurrentForTesting(int generation) =>
      _isCurrentGeneration(generation);

  /// The negotiated QUIC idle timeout in milliseconds, or null if no timeout
  /// was negotiated (i.e. the connection may remain idle indefinitely).
  /// Populated after a successful QUIC connect.
  int? get quicNegotiatedIdleTimeoutMs => _quicNegotiatedIdleTimeoutMs;
  String? _accountBareJid;
  String _controlBuffer = '';
  late String Function(String event) _map;
  // Factory that produces an independent mapper closure (with its own buffer)
  // for each aux QUIC stream. Set by Connection after connect() via
  // setAuxMapperFactory(). Each call returns a new closure with its own
  // partial-XML buffer, so interleaved chunks from different QUIC streams
  // do not corrupt each other's parse state.
  String Function(String) Function()? _makeAuxMapper;

  /// Called by [Connection] after a successful QUIC connect to supply a
  /// factory for per-aux-stream XML mappers. Each aux recv loop calls this
  /// factory once to get its own independent buffer/mapper closure.
  void setAuxMapperFactory(String Function(String) Function() factory) {
    _makeAuxMapper = factory;
  }

  Future<void> _writeQueue = Future<void>.value();

  // Kept as members so the winning endpoint/connection remain alive while
  // stream objects are in use.
  // ignore: unused_field
  QuicEndpoint? _endpoint;
  // ignore: unused_field
  QuicConnection? _connection;
  QuicSendStream? _sendStream;
  QuicRecvStream? _recvStream;
  final Map<int, _QuicStreamChannel> _auxStreamsBySlot = {};
  // In-flight futures for aux stream opens, keyed by slot. Concurrent callers
  // for the same slot await the same future rather than issuing duplicate
  // connectionOpenBi calls for the same JID hash.
  final Map<int, Future<_QuicStreamChannel>> _auxStreamOpening = {};
  // Per-slot queue of stanzas that arrived while the aux stream for that slot
  // was still being opened. Flushed onto the aux stream once it is ready.
  final Map<int, List<String>> _auxStreamPendingQueue = {};

  // Pool of server-initiated bidirectional streams that have been accepted but
  // not yet assigned to a slot. When we need to open an aux stream for a new
  // bare-JID slot, we pop from this pool first rather than calling
  // connectionOpenBi, saving a round-trip and a stream-credit.
  final List<_QuicStreamChannel> _serverStreamPool = [];

  /// Number of server-initiated streams currently waiting in the pool.
  /// Exposed for testing only.
  @visibleForTesting
  int get serverStreamPoolSize => _serverStreamPool.length;

  /// Injects a fake server-initiated stream into the pool for testing.
  /// The [sendStream] and [recvStream] are the raw QUIC stream objects.
  /// In production these come from [connectionAcceptBi]; in tests a fake
  /// pair can be injected to verify pool-preference logic without a live
  /// QUIC connection.
  @visibleForTesting
  void injectServerStreamForTesting(
    QuicSendStream sendStream,
    QuicRecvStream recvStream,
  ) {
    _serverStreamPool.add(
      _QuicStreamChannel(sendStream: sendStream, recvStream: recvStream),
    );
  }

  /// Directly sets the QUIC-active flag for unit tests that need to exercise
  /// [attemptMigration] without going through a real [connect] call.
  @visibleForTesting
  set useQuicForTesting(bool value) => _useQuic = value;

  /// Directly sets the endpoint for unit tests that need to exercise
  /// [attemptMigration] without going through a real [connect] call.
  @visibleForTesting
  set endpointForTesting(QuicEndpoint? value) => _endpoint = value;

  /// Directly sets the connection for migration tests without opening QUIC.
  @visibleForTesting
  set connectionForTesting(QuicConnection? value) => _connection = value;

  @override
  Future<XmppWebSocket> connect<S>(
    String host,
    int port, {
    String Function(String event)? map,
    String? wsPath,
    Uri? wsUri,
    bool useWebSocket = false,
    bool useWebTransport = false,
    bool useQuic = false,
    bool directTls = false,
    String? tlsHost,
  }) async {
    final generation = ++_connectionGeneration;
    _map = map ?? (element) => element;
    // If the caller supplied a map factory (Connection.makeStreamResponseMapper),
    // store it so aux recv loops can each get their own independent buffer.
    _makeAuxMapper =
        null; // reset; Connection sets this via makeStreamResponseMapper
    _closed = false;
    if (!useQuic) {
      _useQuic = false;
      return _fallbackSocket.connect(
        host,
        port,
        map: map,
        wsPath: wsPath,
        wsUri: wsUri,
        useWebSocket: useWebSocket,
        useWebTransport: useWebTransport,
        useQuic: false,
        directTls: directTls,
        tlsHost: tlsHost,
      );
    }

    _useQuic = true;
    await _ensureRustInitialized();
    await _connectQuic(host, port, tlsHost ?? host, generation);
    if (!_isCurrentGeneration(generation)) {
      throw StateError('QUIC connection generation $generation was superseded');
    }
    _startControlRecvLoop(generation);
    _startServerStreamAcceptLoop(generation);
    return this;
  }

  @override
  bool get isQuic => _useQuic;

  @override
  Future<QuicConnectionStats?> getQuicStats() async {
    final conn = _connection;
    if (conn == null || !_useQuic) return null;
    try {
      return await connectionStats(connection: conn);
    } catch (e) {
      // debugPrint('Error getting QUIC stats: $e');
      return null;
    }
  }

  /// Attempt QUIC connection migration after a network-interface change.
  ///
  /// Rebinds the endpoint's UDP socket to a fresh unspecified address on the
  /// same address family, which causes Quinn to probe the new path (RFC 9000
  /// §9). Polls [getQuicStats] every 200 ms for up to
  /// [migrationProbeTimeout] waiting for either a received `PATH_CHALLENGE` or
  /// any UDP datagram on the new socket. The latter is sufficient proof that
  /// the new bidirectional path works and covers peers that do not emit an
  /// observable challenge during NAT rebinding.
  ///
  /// Returns [MigrationResult.success] when the new path carries traffic, or
  /// [MigrationResult.failed] on timeout, FFI error, or when QUIC is inactive.
  Future<MigrationResult> attemptMigration() {
    final inFlight = _migrationFuture;
    if (inFlight != null) {
      return inFlight;
    }
    final migration = _attemptMigration();
    _migrationFuture = migration;
    migration.whenComplete(() {
      if (identical(_migrationFuture, migration)) {
        _migrationFuture = null;
      }
    });
    return migration;
  }

  Future<MigrationResult> _attemptMigration() async {
    final generation = _connectionGeneration;
    final endpoint = _endpoint;
    final connection = _connection;
    if (!_useQuic ||
        endpoint == null ||
        connection == null ||
        !_isCurrentGeneration(generation)) {
      return MigrationResult.failed;
    }
    // Snapshot the current path_challenge RX counter before rebinding.
    BigInt baselinePathChallenge;
    BigInt baselineUdpDatagrams;
    try {
      final stats = await getQuicStats();
      baselinePathChallenge = stats?.frameRx.pathChallenge ?? BigInt.zero;
      baselineUdpDatagrams = stats?.udpRx.datagrams ?? BigInt.zero;
    } catch (_) {
      baselinePathChallenge = BigInt.zero;
      baselineUdpDatagrams = BigInt.zero;
    }
    // Rebind the UDP socket to trigger PATH_CHALLENGE on the new path.
    try {
      final rebind = rebindOverride;
      if (rebind != null) {
        await rebind(endpoint);
      } else {
        await endpointRebindToCurrentAddress(endpoint: endpoint);
      }
      if (!_isCurrentGeneration(generation)) {
        return MigrationResult.failed;
      }
    } catch (e) {
      debugPrint('QUIC migration: rebind failed: $e');
      return MigrationResult.failed;
    }
    // Send repeated ack-eliciting probes. Quinn performs its own PTO-based
    // recovery, but explicit periodic PINGs give a newly activated, lossy
    // mobile path several independent chances to carry traffic.
    final deadline = DateTime.now().add(migrationProbeTimeout);
    var nextProbeAt = DateTime.now();
    while (_isCurrentGeneration(generation) &&
        DateTime.now().isBefore(deadline)) {
      final now = DateTime.now();
      if (!now.isBefore(nextProbeAt)) {
        try {
          final sendProbe = migrationPingOverride;
          if (sendProbe != null) {
            await sendProbe(connection);
          } else {
            await connectionSendPing(connection: connection);
          }
        } catch (_) {
          // A transient send failure does not end migration; later probes may
          // succeed once Android finishes activating the replacement route.
        }
        nextProbeAt = now.add(migrationProbeInterval);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      try {
        final stats = await getQuicStats();
        final currentPathChallenge =
            stats?.frameRx.pathChallenge ?? BigInt.zero;
        final currentUdpDatagrams = stats?.udpRx.datagrams ?? BigInt.zero;
        if (currentPathChallenge > baselinePathChallenge ||
            currentUdpDatagrams > baselineUdpDatagrams) {
          return MigrationResult.success;
        }
      } catch (_) {
        // Ignore transient stat errors; keep polling until deadline.
      }
    }
    return MigrationResult.failed;
  }

  @override
  void write(Object? message) {
    if (!_useQuic) {
      _fallbackSocket.write(message);
      return;
    }
    final payload = message?.toString() ?? '';
    if (payload.isEmpty) {
      return;
    }
    final generation = _connectionGeneration;
    _writeQueue = _writeQueue.then((_) async {
      if (!_isCurrentGeneration(generation)) {
        return;
      }
      try {
        final target = await _selectSendTarget(payload);
        if (!_isCurrentGeneration(generation)) {
          return;
        }
        if (target == null) {
          // Payload has been enqueued for the aux stream; nothing to send now.
          return;
        }
        Log.xmppp_sending(payload, channel: target.label);
        _lastQuicSendAt = DateTime.now();
        final updated = await sendStreamWriteAll(
          stream: target.stream,
          data: utf8.encode(payload),
        );
        if (_isCurrentGeneration(generation)) {
          target.update(updated);
        }
      } catch (error, stackTrace) {
        if (!_quicStreamController.isClosed) {
          _quicStreamController.addError(error, stackTrace);
        }
      }
    });
  }

  @override
  void close() {
    _closed = true;
    _connectionGeneration++;
    if (!_useQuic) {
      _fallbackSocket.close();
      return;
    }

    final controlStream = _sendStream;
    final auxSlots = _auxStreamsBySlot.keys.toList(growable: false);
    final auxStreams = _auxStreamsBySlot.values
        .map((channel) => channel.sendStream)
        .toList(growable: false);
    if (auxSlots.isNotEmpty) {
      debugPrint(
        'QUIC closing $_activeAttemptContext '
        '${auxSlots.length} aux stream(s): slots=$auxSlots',
      );
    }

    _sendStream = null;
    _recvStream = null;
    // Do NOT null _connection here: any in-flight connectionOpenBi call holds
    // a local reference to the same RustArc. Nulling it here drops the last
    // Dart-side strong reference and disposes the arc while the FFI call is
    // still encoding its arguments, causing DroppableDisposedException.
    // The connection will be released naturally once all local references drop.
    _endpoint = null;
    _postBindReady = false;
    _auxStreamsBlocked = false;
    _lastMaxStreamsBidiFrameCount = BigInt.zero;
    _maxStreamsWatchTimer?.cancel();
    _maxStreamsWatchTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _quicNegotiatedIdleTimeoutMs = null;
    _quicConnectedAt = null;
    _lastQuicReceiveAt = null;
    _lastQuicSendAt = null;
    _lastQuicPingAt = null;
    _accountBareJid = null;
    _controlBuffer = '';
    _auxStreamsBySlot.clear();
    _auxStreamOpening.clear();
    _auxStreamPendingQueue.clear();
    _serverStreamPool.clear();
    _activeAttemptId = null;
    final loserCleanup = _loserCleanupTasks.toList(growable: false);
    if (loserCleanup.isNotEmpty) {
      unawaited(Future.wait(loserCleanup));
    }

    if (controlStream != null) {
      unawaited(
        Future<void>(() async {
          try {
            await sendStreamFinish(stream: controlStream);
          } catch (_) {
            // ignore close races
          }
        }),
      );
    }

    for (final auxStream in auxStreams) {
      unawaited(
        Future<void>(() async {
          try {
            await sendStreamFinish(stream: auxStream);
          } catch (_) {
            // ignore close races
          }
        }),
      );
    }

    if (!_quicStreamController.isClosed) {
      unawaited(_quicStreamController.close());
    }
  }

  @override
  Future<SecureSocket?> secure({
    host,
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    List<String>? supportedProtocols,
  }) {
    if (_useQuic) {
      return Future<SecureSocket?>.value(null);
    }
    return _fallbackSocket.secure(
      host: host,
      context: context,
      onBadCertificate: onBadCertificate,
      supportedProtocols: supportedProtocols,
    );
  }

  @override
  String getStreamOpeningElement(String domain) {
    return _fallbackSocket.getStreamOpeningElement(domain);
  }

  @override
  StreamSubscription<String> listen(
    void Function(String event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (!_useQuic) {
      return _fallbackSocket.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
    }
    return _quicStreamController.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  Future<void> _connectQuic(
    String host,
    int port,
    String serverName,
    int generation,
  ) async {
    final addresses = await resolveHostCached(host);
    if (addresses.isEmpty) {
      throw SocketException('No addresses found for QUIC host $host');
    }
    final candidates = buildQuicHappyEyeballsPlan(
      addresses,
      health: _addressHealth,
    );

    final maxAttempts = quicConnectMaxAttempts < 1 ? 1 : quicConnectMaxAttempts;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (!_isCurrentGeneration(generation)) {
        throw StateError(
          'QUIC connection generation $generation was superseded',
        );
      }
      debugPrint(
        'QUIC connect round $attempt/$maxAttempts: generation=$generation '
        'racing ${candidates.length} candidate(s) '
        'host=$host port=$port '
        'stagger=${happyEyeballsDelay.inMilliseconds}ms '
        'perAttemptTimeout=${quicConnectTimeout.inMilliseconds}ms',
      );
      try {
        final connected = await _raceQuicCandidates(
          candidates,
          port,
          serverName,
          generation,
        );
        if (!_isCurrentGeneration(generation)) {
          throw StateError(
            'QUIC connection generation $generation was superseded',
          );
        }
        final winnerAddress = connected.address;
        if (winnerAddress != null) {
          _addressHealth.recordSuccess(winnerAddress);
        }
        debugPrint(
          'QUIC connect winner: generation=${connected.generation} '
          'attempt=${connected.attemptId} '
          '${winnerAddress?.address ?? '?'}:$port '
          'type=${winnerAddress?.type ?? '?'} '
          '(round $attempt/$maxAttempts)',
        );
        _endpoint = connected.endpoint;
        _connection = connected.connection;
        _activeAttemptId = connected.attemptId;
        _sendStream = connected.sendStream;
        _recvStream = connected.recvStream;
        // Log initial connection stats so we can see the server's stream-credit
        // situation immediately after the handshake. Must be awaited: the call
        // consumes _connection via Auto_Owned and stores the replacement arc
        // back into _connection; without await the arc would be stale for any
        // subsequent FFI call (e.g. _startAuxStreamsOpen).
        await _logConnectionStats('post-connect');
        // Log the peer's advertised transport parameters so we know up front
        // how many bidi streams the server will allow us to open before it
        // needs to send MAX_STREAMS. If the peer advertised <= 1 (just enough
        // for the control stream) there is no point attempting aux opens:
        // `open_bi()` would block indefinitely waiting for credit.
        await _logPeerTransportParams('post-connect');
        return;
      } catch (error) {
        lastError = error;
        debugPrint(
          'QUIC connect round $attempt/$maxAttempts failed: '
          'generation=$generation error=$error',
        );
      }
    }
    throw Exception(
      'Failed QUIC connect host=$host port=$port '
      'after $maxAttempts attempt(s) error=$lastError',
    );
  }

  /// Races every candidate address in parallel using a Happy Eyeballs style
  /// staggered start: candidate `i` is launched after `i * happyEyeballsDelay`.
  /// Each individual attempt is bounded by [quicConnectTimeout]. The first
  /// attempt to succeed wins; the rest are abandoned (their Futures are
  /// drained in the background to avoid unhandled-error noise).
  ///
  /// Each candidate is launched [quicConnectParallelAttempts] times with
  /// additional staggering so that multiple QUIC Initial packets are in-flight
  /// simultaneously. This improves reliability on high-loss paths where the
  /// first Initial packet may be dropped before Quinn's internal retransmit
  /// fires.
  ///
  /// Throws if every candidate fails or times out.
  Future<_QuicConnectResult> _raceQuicCandidates(
    List<InternetAddress> candidates,
    int port,
    String serverName,
    int generation,
  ) async {
    if (candidates.isEmpty) {
      throw SocketException('No QUIC candidates to attempt');
    }
    final completer = Completer<_QuicConnectResult>();
    final errors = <String>[];
    var pending = candidates.length;
    final timers = <Timer>[];
    var nextAttemptId = 0;

    void recordFailure(InternetAddress address, Object error) {
      _addressHealth.recordFailure(address);
      errors.add('${address.address}/${address.type.name}: $error');
      pending--;
      if (pending == 0 && !completer.isCompleted) {
        completer.completeError(
          Exception(
            'All ${candidates.length} QUIC candidate(s) failed: '
            '${errors.join('; ')}',
          ),
        );
      }
    }

    void launch(InternetAddress address) {
      if (completer.isCompleted || !_isCurrentGeneration(generation)) {
        // Another candidate already won; do not start more attempts.
        pending--;
        return;
      }
      final attemptId = ++nextAttemptId;
      final context = quicAttemptLogContext(generation, attemptId);
      debugPrint(
        'QUIC connect attempt: $context ${address.address}:$port '
        'type=${address.type} timeout=${quicConnectTimeout.inMilliseconds}ms',
      );
      unawaited(
        _connectQuicAddress(
              address,
              port,
              serverName,
              timeout: quicConnectTimeout,
              generation: generation,
              attemptId: attemptId,
            )
            .then((result) async {
              if (completer.isCompleted || !_isCurrentGeneration(generation)) {
                await _trackLoserCleanup(
                  result,
                  address: address,
                  port: port,
                  generation: generation,
                  attemptId: attemptId,
                );
                return;
              }
              completer.complete(
                _QuicConnectResult(
                  generation: generation,
                  attemptId: attemptId,
                  address: address,
                  endpoint: result.endpoint,
                  connection: result.connection,
                  sendStream: result.sendStream,
                  recvStream: result.recvStream,
                ),
              );
            })
            .catchError((Object error) {
              debugPrint(
                'QUIC connect failed: $context ${address.address}:$port '
                'type=${address.type} error=$error',
              );
              if (!completer.isCompleted && _isCurrentGeneration(generation)) {
                recordFailure(address, error);
              }
            }),
      );
    }

    // Build the expanded launch schedule: each candidate is repeated
    // [quicConnectParallelAttempts] times. The schedule interleaves candidates
    // and repetitions so that the stagger between any two consecutive launches
    // is always [happyEyeballsDelay], regardless of how many candidates or
    // parallel attempts are configured.
    //
    // Example with 2 candidates (A, B) and parallelAttempts=3:
    //   t=0ms   A[0]
    //   t=250ms B[0]
    //   t=500ms A[1]
    //   t=750ms B[1]
    //   t=1000ms A[2]
    //   t=1250ms B[2]
    final parallelAttempts = quicConnectParallelAttempts < 1
        ? 1
        : quicConnectParallelAttempts;
    final schedule = <InternetAddress>[];
    for (var rep = 0; rep < parallelAttempts; rep++) {
      for (final address in candidates) {
        schedule.add(address);
      }
    }
    // Update pending to match the expanded schedule length.
    pending = schedule.length;

    for (var i = 0; i < schedule.length; i++) {
      final address = schedule[i];
      if (i == 0) {
        launch(address);
      } else {
        final timer = Timer(happyEyeballsDelay * i, () => launch(address));
        timers.add(timer);
      }
    }

    try {
      return await completer.future;
    } finally {
      for (final timer in timers) {
        timer.cancel();
      }
    }
  }

  Future<_QuicConnectResult> _connectQuicAddress(
    InternetAddress address,
    int port,
    String serverName, {
    required Duration timeout,
    required int generation,
    required int attemptId,
  }) async {
    final endpoint = await createClientEndpoint();
    // Build a per-connection qlog path so each QUIC session gets its own
    // trace file.  The file is written by Quinn in qlog JSON-SEQ format and
    // can be analysed with qvis (https://qvis.quictools.info/) or Wireshark.
    final qlogPath =
        '/tmp/wimsy_quic_g${generation}_a${attemptId}_${DateTime.now().millisecondsSinceEpoch}.qlog';
    debugPrint(
      'QUIC qlog: ${quicAttemptLogContext(generation, attemptId)} '
      'writing trace to $qlogPath',
    );
    final connect = endpointConnect(
      endpoint: endpoint,
      addr: _formatSocketAddress(address, port),
      serverName: serverName,
      qlogPath: qlogPath,
    );
    final connected = await connect.timeout(timeout);
    final (sendStream, recvStream) = await connectionOpenBi(
      connection: connected.$2,
    );
    return _QuicConnectResult(
      generation: generation,
      attemptId: attemptId,
      endpoint: connected.$1,
      connection: connected.$2,
      sendStream: sendStream,
      recvStream: recvStream,
    );
  }

  Future<void> _trackLoserCleanup(
    _QuicConnectResult result, {
    required InternetAddress address,
    required int port,
    required int generation,
    required int attemptId,
  }) {
    final cleanup = _discardQuicResult(
      result,
      address: address,
      port: port,
      generation: generation,
      attemptId: attemptId,
    );
    _loserCleanupTasks.add(cleanup);
    cleanup.whenComplete(() => _loserCleanupTasks.remove(cleanup));
    return cleanup;
  }

  Future<void> _discardQuicResult(
    _QuicConnectResult result, {
    required InternetAddress address,
    required int port,
    required int generation,
    required int attemptId,
  }) async {
    final context = quicAttemptLogContext(generation, attemptId);
    try {
      await sendStreamFinish(stream: result.sendStream);
      debugPrint(
        'QUIC connect discard complete: $context ${address.address}:$port '
        'type=${address.type}',
      );
    } catch (error) {
      debugPrint(
        'QUIC connect discard failed: $context ${address.address}:$port '
        'type=${address.type} error=$error',
      );
    }
  }

  /// Accepts server-initiated bidirectional QUIC streams and routes their
  /// data into [_quicStreamController] exactly like client-initiated aux
  /// streams. Per XEP-0467 §Multiple Streams the server may open streams to
  /// push large responses (e.g. MAM pages) without waiting for the client to
  /// open a stream first. Each accepted stream gets its own independent XML
  /// mapper so partial-chunk buffering does not corrupt other streams.
  ///
  /// Each `connectionAcceptBi` call uses a shared reference to `_connection`
  /// so it can run concurrently with `connectionOpenBi` calls.
  void _startServerStreamAcceptLoop(int generation) {
    final conn = _connection;
    if (conn == null) return;
    var streamIndex = 0;
    final context = _activeAttemptContext;
    unawaited(
      Future<void>(() async {
        while (_isCurrentGeneration(generation)) {
          final connection = _connection;
          if (connection == null) break;
          try {
            // connectionAcceptBi takes &QuicConnection (shared ref).
            final result = await connectionAcceptBi(connection: connection);
            if (!_isCurrentGeneration(generation)) {
              break;
            }
            final recvStream = result.$2;
            if (recvStream == null) {
              // Connection closed — exit the accept loop.
              debugPrint(
                'QUIC server-stream accept loop: $context connection closed',
              );
              break;
            }
            final sendStream = result.$1;
            final label = 'quic-server-${streamIndex++}';
            debugPrint(
              'QUIC accepted server-initiated stream: $context $label '
              '(recv loop started immediately; send stream pooled for reuse)',
            );
            // Start the recv loop immediately so inbound stanzas pushed by
            // the server on this stream are processed right away, regardless
            // of whether the send side is ever assigned to a slot.
            final mapper = _makeAuxMapper?.call() ?? _map;
            _startRecvLoop(
              recvStream,
              isControl: false,
              mapper: mapper,
              label: label,
              generation: generation,
            );
            if (sendStream != null) {
              // Pool the send stream (with its already-running recv loop) so
              // that _openAuxStream can reuse it for outbound traffic without
              // calling connectionOpenBi.
              _serverStreamPool.add(
                _QuicStreamChannel(
                  sendStream: sendStream,
                  recvStream: recvStream,
                ),
              );
            }
          } catch (error) {
            if (_isCurrentGeneration(generation)) {
              debugPrint(
                'QUIC server-stream accept loop error: $context $error',
              );
            }
            break;
          }
        }
      }),
    );
  }

  void _startControlRecvLoop(int generation) {
    final recvStream = _recvStream;
    if (recvStream == null) {
      return;
    }
    _startRecvLoop(
      recvStream,
      isControl: true,
      mapper: _map,
      generation: generation,
    );
  }

  void _startRecvLoop(
    QuicRecvStream initial, {
    required bool isControl,
    int? slot,
    String? label,
    String Function(String)? mapper,
    int? generation,
  }) {
    final recvGeneration = generation ?? _connectionGeneration;
    final context = _activeAttemptContext;
    unawaited(
      Future<void>(() async {
        var recvStream = initial;
        try {
          while (_isCurrentGeneration(recvGeneration)) {
            final readResult = await recvStreamRead(
              stream: recvStream,
              maxLength: BigInt.from(16 * 1024),
            );
            recvStream = readResult.$1;
            if (!_isCurrentGeneration(recvGeneration)) {
              break;
            }
            if (isControl) {
              _recvStream = recvStream;
            } else if (slot != null) {
              final channel = _auxStreamsBySlot[slot];
              if (channel != null) {
                channel.recvStream = recvStream;
              }
            }
            final bytes = readResult.$2;
            if (bytes == null) {
              break;
            }
            if (bytes.isEmpty) {
              continue;
            }
            _lastQuicReceiveAt = DateTime.now();
            final chunk = utf8.decode(bytes, allowMalformed: true);
            if (isControl) {
              _captureBindResult(chunk);
            }
            final recvLabel = isControl
                ? 'quic-control'
                : (label ?? 'quic-aux-${slot ?? '?'}');
            Log.xmppp_receiving(chunk, channel: recvLabel);
            // Use the per-stream mapper if provided (aux streams), otherwise
            // fall back to the shared _map (control stream). This ensures each
            // QUIC stream's partial XML fragments are buffered independently
            // and do not corrupt each other's parse state.
            final mapped = (mapper ?? _map)(chunk);
            if (_isCurrentGeneration(recvGeneration)) {
              _quicStreamController.add(mapped);
            }
          }
        } catch (error, stackTrace) {
          if (!_quicStreamController.isClosed &&
              !_isQuicConnectionClosure(error)) {
            try {
              _quicStreamController.addError(error, stackTrace);
            } catch (_) {
              // If no listener is present for stream errors, treat as closed.
            }
          }
        } finally {
          if (isControl && _isCurrentGeneration(recvGeneration)) {
            await _logQuicCloseReason(context);
            if (!_quicStreamController.isClosed) {
              await _quicStreamController.close();
            }
          } else {
            final endLabel =
                label ?? (slot != null ? 'quic-aux-$slot' : 'quic-aux-?');
            debugPrint(
              'QUIC aux stream recv loop ended $context label=$endLabel',
            );
          }
        }
      }),
    );
  }

  Future<_QuicSendTarget?> _selectSendTarget(String payload) async {
    final control = _sendStream;
    if (control == null) {
      throw StateError('QUIC control send stream is not connected');
    }
    if (!_postBindReady) {
      return _QuicSendTarget(
        stream: control,
        update: (updated) => _sendStream = updated,
        label: 'quic-control',
      );
    }

    // Per XEP-0467 §Multiple Streams: only stanzas (`message`/`presence`/`iq`)
    // may be routed onto an aux stream. Top-level non-stanzas — stream errors,
    // CSI (`<active/>`/`<inactive/>`), XEP-0198 `<r/>`/`<a/>`, SASL frames,
    // `<stream:stream>` openers, etc. — MUST be sent on the initial (control)
    // stream regardless of any `to=` they might carry. We check the element
    // name first so a future extension that puts a `to=` on a non-stanza top
    // level element does not accidentally route off the control stream.
    if (!_isStanzaPayload(payload)) {
      return _QuicSendTarget(
        stream: control,
        update: (updated) => _sendStream = updated,
        label: 'quic-control',
      );
    }

    final toBare = extractToBareJidForRouting(payload);
    // Keep stanzas on the control stream when:
    //  * the stanza has no `to` (server-directed, typical for negotiation IQs)
    //  * the `to` is our own bare JID (self-directed)
    //  * the `to` is our own server's bare domain (e.g. disco#info to the
    //    account domain during negotiation) — this is negotiation traffic
    //    which MUST not be queued behind an aux-stream open.
    final accountDomain = _accountBareJid == null
        ? null
        : _accountBareJid!.contains('@')
        ? _accountBareJid!.split('@').last
        : _accountBareJid;
    if (toBare == null ||
        (_accountBareJid != null && toBare == _accountBareJid) ||
        (accountDomain != null && toBare == accountDomain)) {
      return _QuicSendTarget(
        stream: control,
        update: (updated) => _sendStream = updated,
        label: 'quic-control',
      );
    }

    final slot = xmppAuxSlotForBareJid(toBare, _auxStreamSlots);
    final existing = _auxStreamsBySlot[slot];
    if (existing == null) {
      // The aux stream for this slot is not yet open. Enqueue the payload so
      // it is sent on the correct stream once it opens, rather than falling
      // back to the control stream and mixing traffic.
      _auxStreamPendingQueue.putIfAbsent(slot, () => []).add(payload);
      // Kick off opening the aux stream (coalesced: concurrent calls for the
      // same slot share one future). On success flush the pending queue.
      _ensureAuxStream(slot, reason: 'on-demand routing for $toBare').then(
        (channel) => _flushAuxPendingQueue(slot, channel),
        onError: (Object error) {
          // Aux stream open failed (disposed arc, timeout, closed connection).
          // Drain the pending queue onto the control stream so stanzas are not
          // silently dropped.
          debugPrint(
            'QUIC aux stream on-demand open failed slot=$slot error=$error; '
            'draining ${_auxStreamPendingQueue[slot]?.length ?? 0} queued '
            'stanza(s) to control stream',
          );
          final queued = _auxStreamPendingQueue.remove(slot) ?? [];
          for (final qPayload in queued) {
            Log.xmppp_sending(qPayload, channel: 'quic-control (fallback)');
            _writeQueue = _writeQueue.then((_) async {
              if (_closed || _sendStream == null) return;
              try {
                final updated = await sendStreamWriteAll(
                  stream: _sendStream!,
                  data: utf8.encode(qPayload),
                );
                _sendStream = updated;
              } catch (_) {}
            });
          }
        },
      );
      // Return a null-target sentinel: the write() caller must not send the
      // payload now — it has been enqueued above.
      return null;
    }
    final channel = existing;
    return _QuicSendTarget(
      stream: channel.sendStream,
      update: (updated) => channel.sendStream = updated,
      label: 'quic-aux-$slot',
    );
  }

  /// Flushes stanzas queued for [slot] onto [channel] now that the aux stream
  /// is open. Each stanza is sent in order via the write queue.
  void _flushAuxPendingQueue(int slot, _QuicStreamChannel channel) {
    final queued = _auxStreamPendingQueue.remove(slot);
    if (queued == null || queued.isEmpty) return;
    debugPrint(
      'QUIC aux stream slot=$slot flushing ${queued.length} queued stanza(s)',
    );
    for (final qPayload in queued) {
      Log.xmppp_sending(qPayload, channel: 'quic-aux-$slot (flushed)');
      _writeQueue = _writeQueue.then((_) async {
        if (_closed) return;
        try {
          final updated = await sendStreamWriteAll(
            stream: channel.sendStream,
            data: utf8.encode(qPayload),
          );
          channel.sendStream = updated;
        } catch (error, stackTrace) {
          if (!_quicStreamController.isClosed) {
            _quicStreamController.addError(error, stackTrace);
          }
        }
      });
    }
  }

  Future<_QuicStreamChannel> _ensureAuxStream(int slot, {String? reason}) {
    final existing = _auxStreamsBySlot[slot];
    if (existing != null) {
      return Future.value(existing);
    }
    // If the peer is known to be credit-starved (advertised
    // initial_max_streams_bidi <= 1, or a previous open hit the timeout),
    // skip even attempting connectionOpenBi: it will block until the server
    // grants more credits via a MAX_STREAMS frame, which `_maxStreamsWatchTimer`
    // is monitoring. Failing fast lets the caller fall back to the control
    // stream rather than queueing on the FFI lock.
    if (_auxStreamsBlocked) {
      return Future.error(
        StateError(
          'QUIC aux streams blocked: peer has not granted bidi stream credits',
        ),
      );
    }
    // Coalesce concurrent opens for the same slot: if one is already in
    // flight, return the same future so callers share the result rather than
    // each trying to consume _connection via Auto_Owned FFI transfer.
    return _auxStreamOpening.putIfAbsent(
      slot,
      () => _openAuxStream(slot, reason: reason ?? 'on-demand'),
    );
  }

  Future<_QuicStreamChannel> _openAuxStream(
    int slot, {
    String reason = 'pre-open',
  }) async {
    // Prefer a server-initiated stream from the pool over opening a new
    // client-initiated stream. This avoids a connectionOpenBi round-trip and
    // conserves bidi-stream credits.
    if (_serverStreamPool.isNotEmpty) {
      final pooled = _serverStreamPool.removeAt(0);
      _auxStreamsBySlot[slot] = pooled;
      debugPrint(
        'QUIC aux stream slot=$slot assigned from server-stream pool '
        '(recv loop already running; ${_serverStreamPool.length} remaining in pool)',
      );
      // The recv loop for this stream was started immediately when the server
      // stream was accepted — do NOT start a second one here.
      _auxStreamOpening.remove(slot);
      return pooled;
    }

    try {
      final connection = _connection;
      if (connection == null || _closed) {
        throw StateError('QUIC connection is not established');
      }
      debugPrint(
        'QUIC aux stream opening slot=$slot reason=$reason (calling connectionOpenBi)',
      );
      // connectionOpenBi now takes &QuicConnection (shared ref) so multiple
      // concurrent opens on different slots are safe — no serialisation lock
      // needed. Quinn's open_bi only needs &self internally.
      //
      // connectionOpenBi (Quinn open_bi) will BLOCK until the peer has
      // granted enough bidirectional-stream credits for a new stream to be
      // opened. If the server advertises a low initial_max_streams_bidi and
      // does not proactively send MAX_STREAMS frames, this future can hang
      // indefinitely. Add progress logging and a hard timeout so this
      // failure mode is visible and recoverable.
      final openStart = DateTime.now();
      Timer? progressTimer;
      progressTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        final elapsed = DateTime.now().difference(openStart);
        debugPrint(
          'QUIC aux stream slot=$slot connectionOpenBi still pending after '
          '${elapsed.inMilliseconds}ms — peer has likely not granted bidi '
          'stream credits yet',
        );
      });
      try {
        final (
          sendStream,
          recvStream,
        ) = await connectionOpenBi(connection: connection).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            // Mark that we are credit-starved and log stats so we can see
            // the server's MAX_STREAMS frame count at the moment of timeout.
            _auxStreamsBlocked = true;
            _startMaxStreamsWatcher();
            throw TimeoutException(
              'connectionOpenBi timed out for aux slot $slot after 10s '
              '(peer likely did not grant additional bidi stream credits)',
            );
          },
        );
        // Re-check after the async gap: close() may have fired while we awaited.
        if (_closed) {
          // Discard the newly opened streams; the connection is being torn down.
          throw StateError('QUIC socket closed during aux stream open');
        }
        final channel = _QuicStreamChannel(
          sendStream: sendStream,
          recvStream: recvStream,
        );
        _auxStreamsBySlot[slot] = channel;
        final elapsed = DateTime.now().difference(openStart);
        debugPrint(
          'QUIC aux stream opened (outbound) slot=$slot '
          'in ${elapsed.inMilliseconds}ms',
        );
        // Give each aux recv loop its own independent XML mapper/buffer so
        // that partial fragments from different QUIC streams do not
        // interleave in the shared restOfResponse buffer of Connection's
        // prepareStreamResponse. Fall back to _map if no factory was set
        // (e.g. in tests that don't call setAuxMapperFactory).
        final auxMapper = _makeAuxMapper?.call() ?? _map;
        _startRecvLoop(
          recvStream,
          isControl: false,
          slot: slot,
          mapper: auxMapper,
        );
        return channel;
      } catch (error, stack) {
        final elapsed = DateTime.now().difference(openStart);
        debugPrint(
          'QUIC aux stream open error slot=$slot after '
          '${elapsed.inMilliseconds}ms error=$error',
        );
        debugPrint('QUIC aux stream open stack slot=$slot: $stack');
        unawaited(_logConnectionStats('post-open-error slot=$slot'));
        rethrow;
      } finally {
        progressTimer.cancel();
      }
    } finally {
      _auxStreamOpening.remove(slot);
    }
  }

  void _captureBindResult(String chunk) {
    if (_postBindReady) {
      return;
    }
    _controlBuffer += chunk;
    if (_controlBuffer.length > _maxControlBufferChars) {
      _controlBuffer = _controlBuffer.substring(
        _controlBuffer.length - _maxControlBufferChars,
      );
    }

    final bare = extractBoundBareJid(_controlBuffer);
    if (bare == null || bare.isEmpty) {
      return;
    }
    _accountBareJid = bare;
    _postBindReady = true;
    debugPrint(
      'QUIC post-bind multi-stream enabled; accountBareJid=$bare; '
      'aux streams will be opened lazily on demand',
    );
    // Per XEP-0467 §Multiple Streams, aux streams "MAY be opened ... after
    // resource binding" — they are not required to be eagerly pre-opened.
    // We previously opened all _auxStreamSlots immediately post-bind, which
    // was permissible but suboptimal:
    //   * On a credit-starved server it burned the first slot on a 10s
    //     timeout and then chained DroppableDisposedException across the
    //     remaining 19 (see WIMSY-1B/1C/1D Sentry chain).
    //   * It opened streams the client did not actually need yet.
    // Aux streams are now opened lazily by `_selectSendTarget` the first
    // time a stanza is routed to a destination bare JID that hashes to a
    // slot we have not yet opened. This matches the spec's intent ("opened
    // when needed for a destination bare-JID pair") and naturally limits
    // how many credits we consume to the number of distinct bare JIDs we
    // are actually communicating with.
  }

  /// Logs key connection stats (MAX_STREAMS frame counts) for diagnostics.
  Future<void> _logConnectionStats(String context) async {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    try {
      final stats = await connectionStats(connection: connection);
      final rxMaxBidi = stats.frameRx.maxStreamsBidi;
      final rxMaxUni = stats.frameRx.maxStreamsUni;
      final rxBlockedBidi = stats.frameRx.streamsBlockedBidi;
      final txBlockedBidi = stats.frameTx.streamsBlockedBidi;
      final txStream = stats.frameTx.stream;
      final rxStream = stats.frameRx.stream;
      debugPrint(
        'QUIC connection stats [$_activeAttemptContext $context]: '
        'server MAX_STREAMS(bidi) frames received=$rxMaxBidi '
        'MAX_STREAMS(uni) frames received=$rxMaxUni '
        'STREAMS_BLOCKED(bidi) sent by us=$txBlockedBidi '
        'STREAMS_BLOCKED(bidi) received from server=$rxBlockedBidi '
        'STREAM frames sent=$txStream received=$rxStream',
      );
      _lastMaxStreamsBidiFrameCount = rxMaxBidi;
    } catch (error) {
      debugPrint(
        'QUIC connection stats error [$_activeAttemptContext $context]: $error',
      );
    }
  }

  /// Logs the peer's advertised QUIC transport parameters (initial stream
  /// credits and connection flow-control window) for diagnostics.
  ///
  /// Exposed via our patched vendored quinn/quinn-proto (upstream quinn 0.11
  /// does not surface peer transport parameters). If the peer advertised only
  /// enough bidi streams for the control stream (<= 1), pre-flags aux stream
  /// opens as blocked so `_startAuxStreamsOpen` can decline immediately
  /// instead of burning a 10s timeout on `connectionOpenBi`.
  Future<void> _logPeerTransportParams(String context) async {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    try {
      final params = await connectionPeerTransportParams(
        connection: connection,
      );
      final bidi = params.initialMaxStreamsBidi;
      final uni = params.initialMaxStreamsUni;
      final data = params.initialMaxData;
      final idleMs = params.negotiatedIdleTimeoutMs;
      // Store the negotiated QUIC idle timeout for use by the PING timer.
      _quicNegotiatedIdleTimeoutMs = idleMs?.toInt();
      _quicConnectedAt ??= DateTime.now();
      final idleDesc = idleMs != null
          ? '${(idleMs.toInt() / 1000).toStringAsFixed(1)}s'
          : 'infinite';
      debugPrint(
        'QUIC peer transport params [$_activeAttemptContext $context]: '
        'initial_max_streams_bidi=$bidi '
        'initial_max_streams_uni=$uni '
        'initial_max_data=$data '
        'negotiated_idle_timeout=$idleDesc',
      );
      // The control stream consumes client-initiated bidi stream id 0, so we
      // need the peer to have advertised at least 2 to open aux slot 0.
      if (bidi <= BigInt.one) {
        _auxStreamsBlocked = true;
        debugPrint(
          'QUIC peer transport params [$_activeAttemptContext $context]: '
          'peer advertised initial_max_streams_bidi=$bidi (<= 1); '
          'aux stream opens are pre-flagged as blocked, '
          'waiting for server MAX_STREAMS(bidi) frame before attempting',
        );
        _startMaxStreamsWatcher();
      }
    } catch (error) {
      debugPrint(
        'QUIC peer transport params error '
        '[$_activeAttemptContext $context]: $error',
      );
    }
  }

  /// Starts a periodic QUIC PING timer that sends a PING frame at [interval].
  ///
  /// The PING elicits an ACK from the peer, resetting both sides' idle timers
  /// and preventing the QUIC connection from being closed due to inactivity.
  /// Any previously running PING timer is cancelled first.
  void startPingTimer(Duration interval) {
    _pingTimer?.cancel();
    _pingTimer = null;
    final connection = _connection;
    final generation = _connectionGeneration;
    if (connection == null || _closed) {
      return;
    }
    debugPrint(
      'QUIC PING timer started: $_activeAttemptContext '
      'interval=${interval.inSeconds}s '
      '(quic_idle_timeout=${_quicNegotiatedIdleTimeoutMs != null ? '${(_quicNegotiatedIdleTimeoutMs! / 1000).toStringAsFixed(1)}s' : 'infinite'})',
    );
    _pingTimer = Timer.periodic(interval, (_) async {
      final conn = _connection;
      if (conn == null || !_isCurrentGeneration(generation)) {
        _pingTimer?.cancel();
        _pingTimer = null;
        return;
      }
      try {
        await connectionSendPing(connection: conn);
        if (!_isCurrentGeneration(generation)) return;
        _lastQuicPingAt = DateTime.now();
        debugPrint(
          'QUIC PING sent $_activeAttemptContext (keeping connection alive)',
        );
      } catch (e) {
        debugPrint('QUIC PING error: $_activeAttemptContext $e');
      }
    });
  }

  /// Stops the periodic QUIC PING timer.
  void stopPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  /// Starts a periodic watcher that detects when the server sends a new
  /// MAX_STREAMS(bidi) frame, clears the blocked flag, and resumes aux opens.
  void _startMaxStreamsWatcher() {
    if (_maxStreamsWatchTimer != null) {
      return; // Already watching.
    }
    debugPrint(
      'QUIC aux stream watcher started: $_activeAttemptContext '
      'waiting for server MAX_STREAMS(bidi) frame',
    );
    final generation = _connectionGeneration;
    _maxStreamsWatchTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isCurrentGeneration(generation) || _connection == null) {
        _maxStreamsWatchTimer?.cancel();
        _maxStreamsWatchTimer = null;
        return;
      }
      final prevCount = _lastMaxStreamsBidiFrameCount;
      unawaited(
        _logConnectionStats('max-streams-watcher').then((_) {
          if (!_isCurrentGeneration(generation)) return;
          final rxMaxBidi = _lastMaxStreamsBidiFrameCount;
          debugPrint(
            'QUIC aux stream watcher: $_activeAttemptContext '
            'server MAX_STREAMS(bidi) frames received=$rxMaxBidi '
            '(was $prevCount)',
          );
          if (rxMaxBidi > prevCount) {
            _auxStreamsBlocked = false;
            _maxStreamsWatchTimer?.cancel();
            _maxStreamsWatchTimer = null;
            debugPrint(
              'QUIC aux stream watcher: $_activeAttemptContext '
              'server granted more bidi stream credits '
              '(MAX_STREAMS frame count increased to $rxMaxBidi); '
              'lazy aux stream opens via _selectSendTarget will now succeed',
            );
          }
        }),
      );
    });
  }

  String _formatSocketAddress(InternetAddress address, int port) {
    if (address.type == InternetAddressType.IPv6) {
      return '[${address.address}]:$port';
    }
    return '${address.address}:$port';
  }

  Future<void> _ensureRustInitialized() {
    if (_rustInitialized) {
      return Future<void>.value();
    }
    _rustInitFuture ??= RustLib.init().then((_) {
      _rustInitialized = true;
    });
    return _rustInitFuture!;
  }

  /// Logs a human-readable message explaining who closed the QUIC connection
  /// and why, using Quinn's [ConnectionError] variant embedded in the Debug
  /// string returned by [connectionCloseReason].
  ///
  /// Variant meanings:
  ///  - `LocallyClosed`      — **we** called `connection.close()` (client-side)
  ///  - `ApplicationClosed`  — the **remote peer** sent a QUIC APPLICATION_CLOSE
  ///  - `TimedOut`           — idle timeout expired (no keepalive from either side)
  ///  - `Reset`              — stateless reset from the remote peer
  ///  - `TransportError`     — QUIC transport-level protocol error
  ///  - `VersionMismatch`    — QUIC version negotiation failed
  ///  - null / unknown       — stream ended cleanly or reason unavailable
  Future<void> _logQuicCloseReason(String attemptContext) async {
    final conn = _connection;
    if (conn == null) {
      debugPrint(
        'QUIC connection closed (no connection arc available for close-reason query)',
      );
      return;
    }
    try {
      final reason = await connectionCloseReason(connection: conn);
      QuicConnectionStats? stats;
      try {
        stats = await connectionStats(connection: conn);
      } catch (_) {
        // The close reason is still useful if the connection arc was disposed
        // before the final statistics could be copied across FFI.
      }
      final now = DateTime.now();
      final attribution = describeQuicCloseAttribution(reason);
      final idle = _quicNegotiatedIdleTimeoutMs == null
          ? 'infinite'
          : '${_quicNegotiatedIdleTimeoutMs}ms';
      final peerCloseFrames = stats?.frameRx.connectionClose;
      final path = stats?.path;
      Log.w(
        'QuicTransport',
        'connection dropped: attribution=$attribution '
            '$attemptContext '
            'reason=${reason ?? 'none (control stream ended without a QUIC close error)'} '
            'negotiated_idle_timeout=$idle '
            'connection_age=${_formatDiagnosticAge(now, _quicConnectedAt)} '
            'last_receive_age=${_formatDiagnosticAge(now, _lastQuicReceiveAt)} '
            'last_send_age=${_formatDiagnosticAge(now, _lastQuicSendAt)} '
            'last_ping_age=${_formatDiagnosticAge(now, _lastQuicPingAt)} '
            'peer_close_frames=${peerCloseFrames ?? 'unavailable'} '
            'rtt_ms=${path?.rttMillis ?? 'unavailable'} '
            'lost_packets=${path?.lostPackets ?? 'unavailable'} '
            'sent_packets=${path?.sentPackets ?? 'unavailable'}',
      );
    } catch (e) {
      Log.w(
        'QuicTransport',
        'connection dropped: attribution=unknown; close diagnostics unavailable: $e',
      );
    }
  }

  bool _isQuicConnectionClosure(Object error) {
    final message = error.toString();
    return message.contains('QuicReadException.connectionLost') ||
        message.contains('ConnectionLost') ||
        message.contains('TimedOut') ||
        message.contains('ApplicationClosed') ||
        message.contains('Reset');
  }
}

/// Converts Quinn's close variant into a careful client/server attribution.
///
/// A local `TimedOut` observation says that this client's negotiated idle
/// timer expired. It cannot establish whether the server independently timed
/// out first, because a server or the network may silently discard packets.
@visibleForTesting
String describeQuicCloseAttribution(String? reason) {
  if (reason == null) return 'unknown-clean-stream-end';
  if (reason.contains('LocallyClosed')) return 'client-initiated';
  if (reason.contains('ApplicationClosed')) return 'server-initiated';
  if (reason.contains('TimedOut')) return 'client-observed-idle-timeout';
  if (reason.contains('Reset')) return 'server-or-network-reset';
  if (reason.contains('TransportError')) return 'quic-transport-error';
  if (reason.contains('VersionMismatch')) return 'quic-version-mismatch';
  return 'unknown';
}

@visibleForTesting
String quicAttemptLogContext(int generation, int attemptId) =>
    'generation=$generation attempt=$attemptId';

String _formatDiagnosticAge(DateTime now, DateTime? then) {
  if (then == null) return 'never';
  return '${now.difference(then).inMilliseconds}ms';
}

List<InternetAddress> buildQuicHappyEyeballsPlan(
  List<InternetAddress> addresses, {
  QuicAddressHealth? health,
}) {
  final ipv6 = <InternetAddress>[];
  final ipv4 = <InternetAddress>[];
  for (final address in addresses) {
    if (address.type == InternetAddressType.IPv6) {
      ipv6.add(address);
    } else if (address.type == InternetAddressType.IPv4) {
      ipv4.add(address);
    }
  }

  final preferIpv6 =
      !(health?.shouldTemporarilyPreferIpv4 ?? false) &&
      addresses.isNotEmpty &&
      addresses.first.type == InternetAddressType.IPv6;
  if (health != null) {
    ipv6.replaceRange(0, ipv6.length, health.order(ipv6));
    ipv4.replaceRange(0, ipv4.length, health.order(ipv4));
  }
  final plan = <InternetAddress>[];
  while (ipv6.isNotEmpty || ipv4.isNotEmpty) {
    if (preferIpv6) {
      if (ipv6.isNotEmpty) {
        plan.add(ipv6.removeAt(0));
      }
      if (ipv4.isNotEmpty) {
        plan.add(ipv4.removeAt(0));
      }
    } else {
      if (ipv4.isNotEmpty) {
        plan.add(ipv4.removeAt(0));
      }
      if (ipv6.isNotEmpty) {
        plan.add(ipv6.removeAt(0));
      }
    }
  }
  return plan;
}

/// Short-lived endpoint health used only to order future QUIC candidates.
/// Failures decay, so an unhealthy family continues to be probed.
class QuicAddressHealth {
  QuicAddressHealth({
    this.failureWindow = const Duration(minutes: 10),
    this.ipv4PreferenceThreshold = 2,
  });

  final Duration failureWindow;
  final int ipv4PreferenceThreshold;
  final Map<String, List<DateTime>> _failures = <String, List<DateTime>>{};

  void recordFailure(InternetAddress address) {
    _prune();
    _failures
        .putIfAbsent(address.address, () => <DateTime>[])
        .add(DateTime.now());
  }

  void recordSuccess(InternetAddress address) =>
      _failures.remove(address.address);

  bool get shouldTemporarilyPreferIpv4 {
    _prune();
    final failures = _failures.entries.where(
      (entry) =>
          InternetAddress.tryParse(entry.key)?.type == InternetAddressType.IPv6,
    );
    return failures.fold<int>(0, (sum, entry) => sum + entry.value.length) >=
        ipv4PreferenceThreshold;
  }

  List<InternetAddress> order(List<InternetAddress> addresses) =>
      List<InternetAddress>.of(addresses)..sort(
        (a, b) => (_failures[a.address]?.length ?? 0).compareTo(
          _failures[b.address]?.length ?? 0,
        ),
      );

  void _prune() {
    final cutoff = DateTime.now().subtract(failureWindow);
    _failures.removeWhere((_, failures) {
      failures.removeWhere((failure) => failure.isBefore(cutoff));
      return failures.isEmpty;
    });
  }
}

bool _isStanzaPayload(String payload) => isStanzaPayload(payload);

int quicAuxSlotForBareJid(String bareJid, int slotCount) {
  return xmppAuxSlotForBareJid(bareJid, slotCount);
}

class _QuicConnectResult {
  const _QuicConnectResult({
    this.address,
    required this.generation,
    required this.attemptId,
    required this.endpoint,
    required this.connection,
    required this.sendStream,
    required this.recvStream,
  });

  /// Remote address that won the race. May be null for intermediate results
  /// produced by [_connectQuicAddress] before the racer wraps them.
  final InternetAddress? address;
  final int generation;
  final int attemptId;
  final QuicEndpoint endpoint;
  final QuicConnection connection;
  final QuicSendStream sendStream;
  final QuicRecvStream recvStream;
}

class _QuicStreamChannel {
  _QuicStreamChannel({required this.sendStream, required this.recvStream});

  QuicSendStream sendStream;
  QuicRecvStream recvStream;
}

class _QuicSendTarget {
  const _QuicSendTarget({
    required this.stream,
    required this.update,
    required this.label,
  });

  final QuicSendStream stream;
  final void Function(QuicSendStream updated) update;
  final String label;
}
