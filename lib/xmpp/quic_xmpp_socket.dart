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

  bool _useQuic = false;
  bool _closed = false;
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
    _startRecvLoop();
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
    final stream = _sendStream;
    if (stream == null) {
      throw StateError('QUIC send stream is not connected');
    }
    _writeQueue = _writeQueue.then((_) async {
      if (_closed) {
        return;
      }
      try {
        _sendStream = await sendStreamWriteAll(
          stream: stream,
          data: utf8.encode(payload),
        );
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
    final stream = _sendStream;
    _sendStream = null;
    _recvStream = null;
    _connection = null;
    _endpoint = null;
    if (stream != null) {
      unawaited(
        Future<void>(() async {
          try {
            await sendStreamFinish(stream: stream);
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

  void _startRecvLoop() {
    unawaited(
      Future<void>(() async {
        var recvStream = _recvStream;
        try {
          while (!_closed && recvStream != null) {
            final readResult = await recvStreamRead(
              stream: recvStream,
              maxLength: BigInt.from(16 * 1024),
            );
            recvStream = readResult.$1;
            _recvStream = recvStream;
            final bytes = readResult.$2;
            if (bytes == null) {
              break;
            }
            if (bytes.isEmpty) {
              continue;
            }
            final chunk = utf8.decode(bytes, allowMalformed: true);
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
          if (!_quicStreamController.isClosed) {
            await _quicStreamController.close();
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
