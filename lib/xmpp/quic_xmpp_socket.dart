import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
// ignore_for_file: implementation_imports

import 'package:flutter_quic/flutter_quic.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketIo.dart';

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
    final auxStreams = _auxStreamsBySlot.values
        .map((channel) => channel.sendStream)
        .toList(growable: false);

    _sendStream = null;
    _recvStream = null;
    _connection = null;
    _endpoint = null;
    _postBindReady = false;
    _auxOpenStarted = false;
    _accountBareJid = null;
    _controlBuffer = '';
    _auxStreamsBySlot.clear();

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
    final streamResult = await connectionOpenBi(connection: connected.$2);
    return _QuicConnectResult(
      endpoint: connected.$1,
      connection: streamResult.$1,
      sendStream: streamResult.$2,
      recvStream: streamResult.$3,
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
          if (isControl && !_quicStreamController.isClosed) {
            await _quicStreamController.close();
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
      );
    }

    final toBare = extractToBareJidForRouting(payload);
    if (toBare == null ||
        (_accountBareJid != null && toBare == _accountBareJid)) {
      return _QuicSendTarget(
        stream: control,
        update: (updated) => _sendStream = updated,
      );
    }

    final slot = quicAuxSlotForBareJid(toBare, _auxStreamSlots);
    final channel = await _ensureAuxStream(slot);
    return _QuicSendTarget(
      stream: channel.sendStream,
      update: (updated) => channel.sendStream = updated,
    );
  }

  Future<_QuicStreamChannel> _ensureAuxStream(int slot) async {
    final existing = _auxStreamsBySlot[slot];
    if (existing != null) {
      return existing;
    }
    final connection = _connection;
    if (connection == null || _closed) {
      throw StateError('QUIC connection is not established');
    }
    final opened = await connectionOpenBi(connection: connection);
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
    _startRecvLoop(opened.$3, isControl: false, slot: slot);
    return channel;
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
    unawaited(
      Future<void>(() async {
        for (var slot = 0; slot < _auxStreamSlots; slot++) {
          if (_closed) {
            break;
          }
          try {
            await _ensureAuxStream(slot);
          } catch (error) {
            debugPrint('QUIC aux stream open failed slot=$slot error=$error');
            break;
          }
        }
      }),
    );
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
  const _QuicSendTarget({required this.stream, required this.update});

  final QuicSendStream stream;
  final void Function(QuicSendStream updated) update;
}
