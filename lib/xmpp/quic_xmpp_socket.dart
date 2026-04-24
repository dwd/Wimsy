import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
// ignore_for_file: implementation_imports

import 'package:flutter_quic/flutter_quic.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketIo.dart';
import 'package:xmpp_stone/src/logger/Log.dart';

class QuicCapableXmppSocket extends XmppWebSocket {
  QuicCapableXmppSocket({
    this.quicConnectTimeout = const Duration(seconds: 3),
    this.happyEyeballsDelay = const Duration(milliseconds: 250),
  });

  final Duration quicConnectTimeout;
  final Duration happyEyeballsDelay;
  final XmppWebSocketIo _fallbackSocket = XmppWebSocketIo();
  final StreamController<String> _quicStreamController =
      StreamController<String>.broadcast();

  static Future<void>? _rustInitFuture;
  static bool _rustInitialized = false;
  static const int _auxStreamSlots = 20;
  static const int _maxControlBufferChars = 16 * 1024;

  bool _useQuic = false;
  bool _closed = false;
  bool _postBindReady = false;
  bool _auxOpenStarted = false;
  // Set to true when connectionOpenBi times out (peer has not granted bidi
  // stream credits). Cleared when we detect the server has sent a new
  // MAX_STREAMS frame (frameRx.maxStreamsBidi increases in connectionStats).
  bool _auxStreamsBlocked = false;
  // The frameRx.maxStreamsBidi count the last time we checked stats. Used to
  // detect when the server sends a new MAX_STREAMS(bidi) frame.
  BigInt _lastMaxStreamsBidiFrameCount = BigInt.zero;
  Timer? _maxStreamsWatchTimer;
  String? _accountBareJid;
  String _controlBuffer = '';
  late String Function(String event) _map;
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
  // for the same slot await the same future rather than racing on _connection.
  final Map<int, Future<_QuicStreamChannel>> _auxStreamOpening = {};
  // Global serialisation lock for connectionOpenBi calls. Because the FFI
  // function uses Auto_Owned transfer (it consumes the RustArc and returns a
  // new one), only one call may be in-flight at a time across ALL slots.
  // Concurrent calls on different slots would both read the same _connection
  // arc; the second would find it already disposed.
  Future<void> _auxOpenLock = Future<void>.value();

  @override
  Future<XmppWebSocket> connect<S>(
    String host,
    int port, {
    String Function(String event)? map,
    List<String>? wsProtocols,
    String? wsPath,
    Uri? wsUri,
    bool useWebSocket = false,
    bool useQuic = false,
    bool directTls = false,
    String? tlsHost,
  }) async {
    _map = map ?? (element) => element;
    _closed = false;
    if (!useQuic) {
      _useQuic = false;
      return _fallbackSocket.connect(
        host,
        port,
        map: map,
        wsProtocols: wsProtocols,
        wsPath: wsPath,
        wsUri: wsUri,
        useWebSocket: useWebSocket,
        useQuic: false,
        directTls: directTls,
        tlsHost: tlsHost,
      );
    }

    _useQuic = true;
    await _ensureRustInitialized();
    await _connectQuic(host, port, tlsHost ?? host);
    _startControlRecvLoop();
    return this;
  }

  @override
  bool get isQuic => true;

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
    _writeQueue = _writeQueue.then((_) async {
      if (_closed) {
        return;
      }
      try {
        final target = await _selectSendTarget(payload);
        Log.xmppp_sending(payload, channel: target.label);
        final updated = await sendStreamWriteAll(
          stream: target.stream,
          data: utf8.encode(payload),
        );
        target.update(updated);
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
      debugPrint('QUIC closing ${auxSlots.length} aux stream(s): slots=$auxSlots');
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
    _auxOpenStarted = false;
    _auxStreamsBlocked = false;
    _lastMaxStreamsBidiFrameCount = BigInt.zero;
    _maxStreamsWatchTimer?.cancel();
    _maxStreamsWatchTimer = null;
    _accountBareJid = null;
    _controlBuffer = '';
    _auxStreamsBySlot.clear();
    _auxStreamOpening.clear();
    _auxOpenLock = Future<void>.value();

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

  Future<void> _connectQuic(String host, int port, String serverName) async {
    final addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty) {
      throw SocketException('No addresses found for QUIC host $host');
    }
    final candidates = buildQuicHappyEyeballsPlan(addresses);
    Object? lastError;
    for (var i = 0; i < candidates.length; i++) {
      final address = candidates[i];
      final timeout = (i == 0 && candidates.length > 1)
          ? (happyEyeballsDelay * 2)
          : quicConnectTimeout;
      debugPrint(
        'QUIC connect attempt ${i + 1}/${candidates.length}: '
        '${address.address}:$port type=${address.type} timeout=${timeout.inMilliseconds}ms',
      );
      try {
        final connected = await _connectQuicAddress(
          address,
          port,
          serverName,
          timeout: timeout,
        );
        debugPrint(
          'QUIC connect winner: ${address.address}:$port type=${address.type}',
        );
        _endpoint = connected.endpoint;
        _connection = connected.connection;
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
        debugPrint(
          'QUIC connect failed: ${address.address}:$port '
          'type=${address.type} error=$error',
        );
        lastError = error;
      }
    }
    throw Exception(
      'Failed QUIC connect host=$host port=$port error=$lastError',
    );
  }

  Future<_QuicConnectResult> _connectQuicAddress(
    InternetAddress address,
    int port,
    String serverName, {
    required Duration timeout,
  }) async {
    final endpoint = await createClientEndpoint();
    final connect = endpointConnect(
      endpoint: endpoint,
      addr: _formatSocketAddress(address, port),
      serverName: serverName,
    );
    final connected = await connect.timeout(timeout);
    final (conn, sendStream, recvStream) = await connectionOpenBi(connection: connected.$2);
    return _QuicConnectResult(
      endpoint: connected.$1,
      connection: conn,
      sendStream: sendStream,
      recvStream: recvStream,
    );
  }

  void _startControlRecvLoop() {
    final recvStream = _recvStream;
    if (recvStream == null) {
      return;
    }
    _startRecvLoop(recvStream, isControl: true);
  }

  void _startRecvLoop(
    QuicRecvStream initial, {
    required bool isControl,
    int? slot,
  }) {
    unawaited(
      Future<void>(() async {
        var recvStream = initial;
        try {
          while (!_closed) {
            final readResult = await recvStreamRead(
              stream: recvStream,
              maxLength: BigInt.from(16 * 1024),
            );
            recvStream = readResult.$1;
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
            final chunk = utf8.decode(bytes, allowMalformed: true);
            if (isControl) {
              _captureBindResult(chunk);
            }
            _quicStreamController.add(_map(chunk));
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
          if (isControl) {
            if (!_quicStreamController.isClosed) {
              await _quicStreamController.close();
            }
          } else if (slot != null) {
            debugPrint('QUIC aux stream recv loop ended slot=$slot');
          }
        }
      }),
    );
  }

  Future<_QuicSendTarget> _selectSendTarget(String payload) async {
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

    final toBare = extractToBareJidForRouting(payload);
    // Keep on the control stream when:
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

    final slot = quicAuxSlotForBareJid(toBare, _auxStreamSlots);
    // Do not block the write queue if the aux stream is not yet open: if we
    // cannot get the aux channel synchronously, fall back to the control
    // stream. The write queue is a single serial chain; awaiting aux-stream
    // creation here deadlocks every subsequent write (including critical
    // negotiation stanzas) behind a potentially slow/failed aux open.
    final existing = _auxStreamsBySlot[slot];
    if (existing == null) {
      // Kick off opening the aux stream for future sends, but send this
      // payload on the control stream right now.
      // ignore: unawaited_futures
      _ensureAuxStream(slot, reason: 'on-demand routing for $toBare').then(
        (_) {},
        onError: (Object error) {
          // Log but do not rethrow: this future is unawaited, so rethrowing
          // would surface as an unhandled fatal error via PlatformDispatcher.
          // Aux stream open failures are expected during teardown (disposed
          // RustArc, closed connection, timeout) and are non-fatal — the
          // payload was already sent on the control stream.
          debugPrint(
            'QUIC aux stream on-demand open failed slot=$slot error=$error',
          );
        },
      );
      return _QuicSendTarget(
        stream: control,
        update: (updated) => _sendStream = updated,
        label: 'quic-control',
      );
    }
    final channel = existing;
    return _QuicSendTarget(
      stream: channel.sendStream,
      update: (updated) => channel.sendStream = updated,
      label: 'quic-aux-$slot',
    );
  }

  Future<_QuicStreamChannel> _ensureAuxStream(int slot, {String? reason}) {
    final existing = _auxStreamsBySlot[slot];
    if (existing != null) {
      return Future.value(existing);
    }
    // Coalesce concurrent opens for the same slot: if one is already in
    // flight, return the same future so callers share the result rather than
    // each trying to consume _connection via Auto_Owned FFI transfer.
    return _auxStreamOpening.putIfAbsent(slot, () => _openAuxStream(slot, reason: reason ?? 'pre-open'));
  }

  Future<_QuicStreamChannel> _openAuxStream(int slot, {String reason = 'pre-open'}) async {
    try {
      // Serialise all connectionOpenBi calls globally: the FFI function uses
      // Auto_Owned transfer, consuming _connection and returning a new arc.
      // Two concurrent calls on different slots would both capture the same
      // (soon-to-be-consumed) arc, causing DroppableDisposedException on the
      // second call.
      final completer = Completer<void>();
      final previousLock = _auxOpenLock;
      _auxOpenLock = completer.future;
      try {
        debugPrint('QUIC aux stream slot=$slot awaiting open lock (reason=$reason)');
        await previousLock;
        if (_connection == null || _closed) {
          throw StateError('QUIC connection is not established');
        }
        debugPrint('QUIC aux stream opening slot=$slot reason=$reason (calling connectionOpenBi)');
        await _logConnectionStats('pre-open slot=$slot');
        // Re-read _connection after the stats call: _logConnectionStats
        // consumes the arc via Auto_Owned and stores the returned arc back
        // into _connection, so the local variable captured above is stale.
        final freshConnection = _connection;
        if (freshConnection == null || _closed) {
          throw StateError('QUIC connection lost during pre-open stats');
        }
        // connectionOpenBi (Quinn open_bi) will BLOCK until the peer has
        // granted enough bidirectional-stream credits for a new stream to be
        // opened. If the server advertises a low initial_max_streams_bidi and
        // does not proactively send MAX_STREAMS frames, this future can hang
        // indefinitely — which previously held _auxOpenLock forever and
        // prevented every subsequent aux slot from even logging that it was
        // trying to open. Add progress logging and a hard timeout so this
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
          final opened = await connectionOpenBi(connection: freshConnection)
              .timeout(const Duration(seconds: 10), onTimeout: () {
            // Mark that we are credit-starved and log stats so we can see
            // the server's MAX_STREAMS frame count at the moment of timeout.
            _auxStreamsBlocked = true;
            _startMaxStreamsWatcher();
            throw TimeoutException(
              'connectionOpenBi timed out for aux slot $slot after 10s '
              '(peer likely did not grant additional bidi stream credits)',
            );
          });
          // Re-check after the async gap: close() may have fired while we awaited.
          if (_closed) {
            // Discard the newly opened streams; the connection is being torn down.
            throw StateError('QUIC socket closed during aux stream open');
          }
          _connection = opened.$1;
          final channel = _QuicStreamChannel(
            sendStream: opened.$2,
            recvStream: opened.$3,
          );
          _auxStreamsBySlot[slot] = channel;
          final elapsed = DateTime.now().difference(openStart);
          debugPrint(
            'QUIC aux stream opened (outbound) slot=$slot '
            'in ${elapsed.inMilliseconds}ms',
          );
          _startRecvLoop(opened.$3, isControl: false, slot: slot);
          return channel;
        } catch (error, stack) {
          final elapsed = DateTime.now().difference(openStart);
          debugPrint(
            'QUIC aux stream open error slot=$slot after '
            '${elapsed.inMilliseconds}ms error=$error',
          );
          debugPrint('QUIC aux stream open stack slot=$slot: $stack');
          // Log stats after a timeout/error so we can see the connection
          // state at the moment of failure. Use unawaited here since we are
          // in a catch block and the arc may already be consumed; errors are
          // swallowed by _logConnectionStats itself.
          unawaited(_logConnectionStats('post-open-error slot=$slot'));
          rethrow;
        } finally {
          progressTimer.cancel();
        }
      } finally {
        completer.complete();
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

    final bindResult = RegExp(
      '<bind\\b[^>]*xmlns=(["\\\'])urn:ietf:params:xml:ns:xmpp-bind\\1[^>]*>.*?<jid>([^<]+)</jid>',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(_controlBuffer);
    if (bindResult == null) {
      return;
    }
    final fullJid = bindResult.group(2);
    final bare = bareJidForRouting(fullJid);
    if (bare == null || bare.isEmpty) {
      return;
    }
    _accountBareJid = bare;
    _postBindReady = true;
    debugPrint('QUIC post-bind multi-stream enabled; accountBareJid=$bare');
    _startAuxStreamsOpen();
  }

  void _startAuxStreamsOpen() {
    if (_auxOpenStarted || _closed) {
      return;
    }
    _auxOpenStarted = true;
    // Open aux streams one at a time (sequentially). Opening all 20 slots
    // concurrently previously caused every slot after the first to fail with
    // DroppableDisposedException because the Auto_Owned FFI arc was consumed
    // by slot 0's timed-out call. Sequential opening also means we stop
    // immediately when we hit a credit-starvation timeout rather than
    // queuing 19 more doomed calls behind it.
    unawaited(_openAuxStreamsSequentially());
  }

  Future<void> _openAuxStreamsSequentially() async {
    for (var slot = 0; slot < _auxStreamSlots; slot++) {
      if (_closed) {
        return;
      }
      if (_auxStreamsBlocked) {
        debugPrint(
          'QUIC aux stream pre-open stopping at slot=$slot: '
          'peer has not granted bidi stream credits '
          '(will retry when MAX_STREAMS frame is received)',
        );
        return;
      }
      try {
        await _ensureAuxStream(
          slot,
          reason: 'post-bind pre-open slot $slot of $_auxStreamSlots',
        );
      } catch (error) {
        debugPrint('QUIC aux stream open failed slot=$slot error=$error');
        if (_auxStreamsBlocked) {
          // Timeout set the flag; stop trying further slots.
          return;
        }
      }
    }
  }

  /// Logs key connection stats (MAX_STREAMS frame counts) for diagnostics.
  /// Returns a Future that completes after the stats have been fetched and
  /// _connection updated with the returned arc. Callers inside async contexts
  /// should await this so that _connection is valid for the next FFI call.
  Future<void> _logConnectionStats(String context) async {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    try {
      final result = await connectionStats(connection: connection);
      _connection = result.$1;
      final stats = result.$2;
      final rxMaxBidi = stats.frameRx.maxStreamsBidi;
      final rxMaxUni = stats.frameRx.maxStreamsUni;
      final rxBlockedBidi = stats.frameRx.streamsBlockedBidi;
      final txBlockedBidi = stats.frameTx.streamsBlockedBidi;
      final txStream = stats.frameTx.stream;
      final rxStream = stats.frameRx.stream;
      debugPrint(
        'QUIC connection stats [$context]: '
        'server MAX_STREAMS(bidi) frames received=$rxMaxBidi '
        'MAX_STREAMS(uni) frames received=$rxMaxUni '
        'STREAMS_BLOCKED(bidi) sent by us=$txBlockedBidi '
        'STREAMS_BLOCKED(bidi) received from server=$rxBlockedBidi '
        'STREAM frames sent=$txStream received=$rxStream',
      );
      _lastMaxStreamsBidiFrameCount = rxMaxBidi;
    } catch (error) {
      debugPrint('QUIC connection stats error [$context]: $error');
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
      final result =
          await connectionPeerTransportParams(connection: connection);
      _connection = result.$1;
      final params = result.$2;
      final bidi = params.initialMaxStreamsBidi;
      final uni = params.initialMaxStreamsUni;
      final data = params.initialMaxData;
      debugPrint(
        'QUIC peer transport params [$context]: '
        'initial_max_streams_bidi=$bidi '
        'initial_max_streams_uni=$uni '
        'initial_max_data=$data',
      );
      // The control stream consumes client-initiated bidi stream id 0, so we
      // need the peer to have advertised at least 2 to open aux slot 0.
      if (bidi <= BigInt.one) {
        _auxStreamsBlocked = true;
        debugPrint(
          'QUIC peer transport params [$context]: '
          'peer advertised initial_max_streams_bidi=$bidi (<= 1); '
          'aux stream opens are pre-flagged as blocked, '
          'waiting for server MAX_STREAMS(bidi) frame before attempting',
        );
        _startMaxStreamsWatcher();
      }
    } catch (error) {
      debugPrint('QUIC peer transport params error [$context]: $error');
    }
  }

  /// Starts a periodic watcher that detects when the server sends a new
  /// MAX_STREAMS(bidi) frame, clears the blocked flag, and resumes aux opens.
  void _startMaxStreamsWatcher() {
    if (_maxStreamsWatchTimer != null) {
      return; // Already watching.
    }
    debugPrint(
      'QUIC aux stream watcher started: '
      'waiting for server MAX_STREAMS(bidi) frame',
    );
    _maxStreamsWatchTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_closed || _connection == null) {
        _maxStreamsWatchTimer?.cancel();
        _maxStreamsWatchTimer = null;
        return;
      }
      final prevCount = _lastMaxStreamsBidiFrameCount;
      unawaited(_logConnectionStats('max-streams-watcher').then((_) {
        final rxMaxBidi = _lastMaxStreamsBidiFrameCount;
        debugPrint(
          'QUIC aux stream watcher: '
          'server MAX_STREAMS(bidi) frames received=$rxMaxBidi '
          '(was $prevCount)',
        );
        if (rxMaxBidi > prevCount) {
          _auxStreamsBlocked = false;
          _maxStreamsWatchTimer?.cancel();
          _maxStreamsWatchTimer = null;
          debugPrint(
            'QUIC aux stream watcher: server granted more bidi stream credits '
            '(MAX_STREAMS frame count increased to $rxMaxBidi); '
            'resuming aux stream opens',
          );
          unawaited(_openAuxStreamsSequentially());
        }
      }));
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

  bool _isQuicConnectionClosure(Object error) {
    final message = error.toString();
    return message.contains('QuicReadException.connectionLost') ||
        message.contains('ConnectionLost') ||
        message.contains('TimedOut');
  }
}

List<InternetAddress> buildQuicHappyEyeballsPlan(
  List<InternetAddress> addresses,
) {
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
      addresses.isNotEmpty && addresses.first.type == InternetAddressType.IPv6;
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

String? extractToBareJidForRouting(String payload) {
  final toMatch = RegExp('\\bto=(["\\\'])([^"\\\']+)\\1').firstMatch(payload);
  if (toMatch == null) {
    return null;
  }
  return bareJidForRouting(toMatch.group(2));
}

String? bareJidForRouting(String? jid) {
  if (jid == null) {
    return null;
  }
  final trimmed = jid.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final slash = trimmed.indexOf('/');
  if (slash == -1) {
    return trimmed;
  }
  return trimmed.substring(0, slash);
}

int quicAuxSlotForBareJid(String bareJid, int slotCount) {
  if (slotCount <= 0) {
    throw ArgumentError.value(slotCount, 'slotCount', 'must be > 0');
  }
  var hash = 0x811c9dc5;
  for (final unit in bareJid.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash % slotCount;
}

class _QuicConnectResult {
  const _QuicConnectResult({
    required this.endpoint,
    required this.connection,
    required this.sendStream,
    required this.recvStream,
  });

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
