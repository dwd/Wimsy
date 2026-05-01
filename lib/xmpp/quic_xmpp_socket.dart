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
    this.quicConnectTimeout = const Duration(seconds: 5),
    this.happyEyeballsDelay = const Duration(milliseconds: 250),
    this.quicConnectMaxAttempts = 3,
  });

  final Duration quicConnectTimeout;
  final Duration happyEyeballsDelay;

  /// How many times to retry the full Happy Eyeballs round (across all
  /// candidate addresses) before giving up. Each retry races every
  /// candidate again with a fresh staggered start.
  final int quicConnectMaxAttempts;
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
  // for the same slot await the same future rather than racing on _connection.
  final Map<int, Future<_QuicStreamChannel>> _auxStreamOpening = {};
  // Global serialisation lock for ALL FFI calls that consume _connection via
  // Auto_Owned transfer (connectionOpenBi, connectionAcceptBi, connectionStats,
  // connectionPeerTransportParams, connectionCloseReason). Only one such call
  // may be in-flight at a time; concurrent callers would both read the same
  // arc and the second would find it already disposed.
  Future<void> _auxOpenLock = Future<void>.value();

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
    // If the caller supplied a map factory (Connection.makeStreamResponseMapper),
    // store it so aux recv loops can each get their own independent buffer.
    _makeAuxMapper = null; // reset; Connection sets this via makeStreamResponseMapper
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
    _startServerStreamAcceptLoop();
    return this;
  }

  @override
  bool get isQuic => _useQuic;

  @override
  Future<QuicConnectionStats?> getQuicStats() async {
    final conn = _connection;
    if (conn == null || !_useQuic) return null;
    try {
      final (updatedConn, stats) = await connectionStats(connection: conn);
      _connection = updatedConn;
      return stats;
    } catch (e) {
      // debugPrint('Error getting QUIC stats: $e');
      return null;
    }
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
    _writeQueue = _writeQueue.then((_) async {
      if (_closed) {
        return;
      }
      try {
        final target = await _selectSendTarget(payload);
        if (target == null) {
          // Payload has been enqueued for the aux stream; nothing to send now.
          return;
        }
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
    _auxStreamsBlocked = false;
    _lastMaxStreamsBidiFrameCount = BigInt.zero;
    _maxStreamsWatchTimer?.cancel();
    _maxStreamsWatchTimer = null;
    _accountBareJid = null;
    _controlBuffer = '';
    _auxStreamsBySlot.clear();
    _auxStreamOpening.clear();
    _auxStreamPendingQueue.clear();
    _serverStreamPool.clear();
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

    final maxAttempts = quicConnectMaxAttempts < 1 ? 1 : quicConnectMaxAttempts;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      debugPrint(
        'QUIC connect round $attempt/$maxAttempts: '
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
        );
        final winnerAddress = connected.address;
        debugPrint(
          'QUIC connect winner: '
          '${winnerAddress?.address ?? '?'}:$port '
          'type=${winnerAddress?.type ?? '?'} '
          '(round $attempt/$maxAttempts)',
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
        lastError = error;
        debugPrint(
          'QUIC connect round $attempt/$maxAttempts failed: $error',
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
  /// Throws if every candidate fails or times out.
  Future<_QuicConnectResult> _raceQuicCandidates(
    List<InternetAddress> candidates,
    int port,
    String serverName,
  ) async {
    if (candidates.isEmpty) {
      throw SocketException('No QUIC candidates to attempt');
    }
    final completer = Completer<_QuicConnectResult>();
    final errors = <String>[];
    var pending = candidates.length;
    final timers = <Timer>[];

    void recordFailure(InternetAddress address, Object error) {
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
      if (completer.isCompleted) {
        // Another candidate already won; do not start more attempts.
        pending--;
        return;
      }
      debugPrint(
        'QUIC connect attempt: ${address.address}:$port '
        'type=${address.type} timeout=${quicConnectTimeout.inMilliseconds}ms',
      );
      unawaited(
        _connectQuicAddress(
          address,
          port,
          serverName,
          timeout: quicConnectTimeout,
        ).then((result) {
          if (completer.isCompleted) {
            // We lost the race: discard this connection. Best-effort; we
            // don't have a clean cancel path through the FFI, so just let
            // the Rust side drop it when the arc goes out of scope.
            debugPrint(
              'QUIC connect discard (lost race): '
              '${address.address}:$port type=${address.type}',
            );
            return;
          }
          completer.complete(
            _QuicConnectResult(
              address: address,
              endpoint: result.endpoint,
              connection: result.connection,
              sendStream: result.sendStream,
              recvStream: result.recvStream,
            ),
          );
        }).catchError((Object error) {
          debugPrint(
            'QUIC connect failed: ${address.address}:$port '
            'type=${address.type} error=$error',
          );
          if (!completer.isCompleted) {
            recordFailure(address, error);
          }
        }),
      );
    }

    for (var i = 0; i < candidates.length; i++) {
      final address = candidates[i];
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
  }) async {
    final endpoint = await createClientEndpoint();
    // Build a per-connection qlog path so each QUIC session gets its own
    // trace file.  The file is written by Quinn in qlog JSON-SEQ format and
    // can be analysed with qvis (https://qvis.quictools.info/) or Wireshark.
    final qlogPath =
        '/tmp/wimsy_quic_${DateTime.now().millisecondsSinceEpoch}.qlog';
    debugPrint('QUIC qlog: writing trace to $qlogPath');
    final connect = endpointConnect(
      endpoint: endpoint,
      addr: _formatSocketAddress(address, port),
      serverName: serverName,
      qlogPath: qlogPath,
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

  /// Accepts server-initiated bidirectional QUIC streams and routes their
  /// data into [_quicStreamController] exactly like client-initiated aux
  /// streams. Per XEP-0467 §Multiple Streams the server may open streams to
  /// push large responses (e.g. MAM pages) without waiting for the client to
  /// open a stream first. Each accepted stream gets its own independent XML
  /// mapper so partial-chunk buffering does not corrupt other streams.
  ///
  /// Each `connectionAcceptBi` call uses a shared reference to `_connection`
  /// (not Auto_Owned), so it does NOT consume the arc and can run concurrently
  /// with `connectionOpenBi` calls without holding [_auxOpenLock].
  void _startServerStreamAcceptLoop() {
    final conn = _connection;
    if (conn == null) return;
    var streamIndex = 0;
    unawaited(
      Future<void>(() async {
        while (!_closed) {
          final connection = _connection;
          if (connection == null) break;
          try {
            // connectionAcceptBi takes &QuicConnection (shared ref), so it
            // does not consume the arc and is safe to call concurrently with
            // connectionOpenBi / connectionStats.
            final result = await connectionAcceptBi(connection: connection);
            final recvStream = result.$2;
            if (recvStream == null) {
              // Connection closed — exit the accept loop.
              debugPrint('QUIC server-stream accept loop: connection closed');
              break;
            }
            final sendStream = result.$1;
            final label = 'quic-server-${streamIndex++}';
            debugPrint(
              'QUIC accepted server-initiated stream: $label '
              '(pooled for reuse as aux stream)',
            );
            // Pool the stream pair. When _ensureAuxStream next needs a new
            // slot it will pop from here instead of calling connectionOpenBi,
            // saving a round-trip and a bidi-stream credit.
            if (sendStream != null) {
              _serverStreamPool.add(
                _QuicStreamChannel(
                  sendStream: sendStream,
                  recvStream: recvStream,
                ),
              );
            } else {
              // No send stream — start a receive-only loop for completeness.
              final mapper = _makeAuxMapper?.call() ?? _map;
              _startRecvLoop(
                recvStream,
                isControl: false,
                mapper: mapper,
                label: label,
              );
            }
          } catch (error) {
            if (!_closed) {
              debugPrint('QUIC server-stream accept loop error: $error');
            }
            break;
          }
        }
      }),
    );
  }

  void _startControlRecvLoop() {
    final recvStream = _recvStream;
    if (recvStream == null) {
      return;
    }
    _startRecvLoop(recvStream, isControl: true, mapper: _map);
  }

  void _startRecvLoop(
    QuicRecvStream initial, {
    required bool isControl,
    int? slot,
    String? label,
    String Function(String)? mapper,
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
            final recvLabel = isControl
                ? 'quic-control'
                : (label ?? 'quic-aux-${slot ?? '?'}');
            Log.xmppp_receiving(chunk, channel: recvLabel);
            // Use the per-stream mapper if provided (aux streams), otherwise
            // fall back to the shared _map (control stream). This ensures each
            // QUIC stream's partial XML fragments are buffered independently
            // and do not corrupt each other's parse state.
            final mapped = (mapper ?? _map)(chunk);
            _quicStreamController.add(mapped);
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
            await _logQuicCloseReason();
            if (!_quicStreamController.isClosed) {
              await _quicStreamController.close();
            }
          } else {
            final endLabel = label ?? (slot != null ? 'quic-aux-$slot' : 'quic-aux-?');
            debugPrint('QUIC aux stream recv loop ended label=$endLabel');
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

    final slot = quicAuxSlotForBareJid(toBare, _auxStreamSlots);
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
    return _auxStreamOpening.putIfAbsent(slot, () => _openAuxStream(slot, reason: reason ?? 'on-demand'));
  }

  Future<_QuicStreamChannel> _openAuxStream(int slot, {String reason = 'pre-open'}) async {
    // Prefer a server-initiated stream from the pool over opening a new
    // client-initiated stream. This avoids a connectionOpenBi round-trip and
    // conserves bidi-stream credits.
    if (_serverStreamPool.isNotEmpty) {
      final pooled = _serverStreamPool.removeAt(0);
      _auxStreamsBySlot[slot] = pooled;
      debugPrint(
        'QUIC aux stream slot=$slot assigned from server-stream pool '
        '(${_serverStreamPool.length} remaining in pool)',
      );
      final auxMapper = _makeAuxMapper?.call() ?? _map;
      _startRecvLoop(
        pooled.recvStream,
        isControl: false,
        slot: slot,
        mapper: auxMapper,
      );
      _auxStreamOpening.remove(slot);
      return pooled;
    }

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
          // Give each aux recv loop its own independent XML mapper/buffer so
          // that partial fragments from different QUIC streams do not
          // interleave in the shared restOfResponse buffer of Connection's
          // prepareStreamResponse. Fall back to _map if no factory was set
          // (e.g. in tests that don't call setAuxMapperFactory).
          final auxMapper = _makeAuxMapper?.call() ?? _map;
          _startRecvLoop(opened.$3, isControl: false, slot: slot, mapper: auxMapper);
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
            'lazy aux stream opens via _selectSendTarget will now succeed',
          );
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
  Future<void> _logQuicCloseReason() async {
    final conn = _connection;
    if (conn == null) {
      debugPrint('QUIC connection closed (no connection arc available for close-reason query)');
      return;
    }
    try {
      final (updatedConn, reason) = await connectionCloseReason(connection: conn);
      _connection = updatedConn;
      if (reason == null) {
        debugPrint('QUIC connection closed cleanly (no error reported)');
        return;
      }
      final String who;
      final String detail;
      if (reason.contains('LocallyClosed')) {
        who = 'LOCAL (we closed it)';
        detail = reason;
      } else if (reason.contains('ApplicationClosed')) {
        who = 'REMOTE (peer sent APPLICATION_CLOSE)';
        detail = reason;
      } else if (reason.contains('TimedOut')) {
        who = 'TIMEOUT (idle timeout — neither side sent keepalive in time)';
        detail = reason;
      } else if (reason.contains('Reset')) {
        who = 'REMOTE (stateless reset from peer)';
        detail = reason;
      } else if (reason.contains('TransportError')) {
        who = 'TRANSPORT ERROR (QUIC protocol error)';
        detail = reason;
      } else if (reason.contains('VersionMismatch')) {
        who = 'VERSION MISMATCH';
        detail = reason;
      } else {
        who = 'UNKNOWN';
        detail = reason;
      }
      debugPrint('QUIC connection closed: $who — $detail');
    } catch (e) {
      debugPrint('QUIC connection closed (could not query close reason: $e)');
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

/// Returns true when [payload] begins with a top-level XMPP stanza element
/// (`message`, `presence`, or `iq`).
///
/// Per XEP-0467 §Multiple Streams, only stanzas may be sent on aux streams;
/// every other top level element (stream errors, CSI, `<r/>`/`<a/>`, SASL
/// frames, the `<stream:stream>` opener, etc.) MUST be sent on the initial
/// stream. This helper looks at the first XML element name in the payload,
/// skipping any leading `<?xml…?>` prolog and whitespace, and matching the
/// XMPP-defined stanza local-names case-sensitively as required by the
/// `jabber:client` namespace.
bool isStanzaPayload(String payload) {
  var i = 0;
  final length = payload.length;
  while (i < length) {
    final ch = payload.codeUnitAt(i);
    // Skip whitespace.
    if (ch == 0x20 || ch == 0x09 || ch == 0x0a || ch == 0x0d) {
      i++;
      continue;
    }
    if (ch != 0x3c /* '<' */) {
      return false;
    }
    // Skip XML prolog `<?xml … ?>`.
    if (i + 1 < length && payload.codeUnitAt(i + 1) == 0x3f /* '?' */) {
      final end = payload.indexOf('?>', i + 2);
      if (end < 0) {
        return false;
      }
      i = end + 2;
      continue;
    }
    // First real element starts at i+1.
    final nameStart = i + 1;
    var j = nameStart;
    while (j < length) {
      final c = payload.codeUnitAt(j);
      if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d ||
          c == 0x2f /* '/' */ || c == 0x3e /* '>' */) {
        break;
      }
      j++;
    }
    final name = payload.substring(nameStart, j);
    return name == 'message' || name == 'presence' || name == 'iq';
  }
  return false;
}

bool _isStanzaPayload(String payload) => isStanzaPayload(payload);

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
    this.address,
    required this.endpoint,
    required this.connection,
    required this.sendStream,
    required this.recvStream,
  });

  /// Remote address that won the race. May be null for intermediate results
  /// produced by [_connectQuicAddress] before the racer wraps them.
  final InternetAddress? address;
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
