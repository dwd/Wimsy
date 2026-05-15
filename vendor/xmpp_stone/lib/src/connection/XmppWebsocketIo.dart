import 'dart:async';
import 'dart:convert';
import 'package:universal_io/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xmpp_stone/src/connection/HappyEyeballsConnector.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';
import 'package:xmpp_stone/src/logger/Log.dart';

export 'XmppWebsocketApi.dart';

XmppWebSocket createSocket() {
  return XmppWebSocketIo();
}

bool isTlsRequired() {
  return true;
}

class XmppWebSocketIo extends XmppWebSocket {
  static String TAG = 'XmppWebSocketIo';
  Socket? _tcpSocket;
  WebSocketChannel? _webSocket;
  bool _useWebSocket = false;
  late String Function(String event) _map;
  final HostLookup _hostLookup;
  final TcpAddressConnect _tcpConnect;
  final SecureSocketFactory _secureSocketFactory;
  final WebSocketChannelFactory _webSocketConnect;
  final Duration _happyEyeballsDelay;
  final Duration _connectTimeout;

  XmppWebSocketIo({
    HostLookup? hostLookup,
    TcpAddressConnect? tcpConnect,
    SecureSocketFactory? secureSocketFactory,
    WebSocketChannelFactory? webSocketConnect,
    Duration happyEyeballsDelay = const Duration(milliseconds: 250),
    Duration connectTimeout = const Duration(seconds: 5),
  })  : _tcpConnect = tcpConnect ?? Socket.connect,
        _hostLookup = hostLookup ?? InternetAddress.lookup,
        _secureSocketFactory =
            secureSocketFactory ?? _defaultSecureSocketFactory,
        _webSocketConnect = webSocketConnect ?? _defaultWebSocketConnect,
        _happyEyeballsDelay = happyEyeballsDelay,
        _connectTimeout = connectTimeout;

  @override
  Future<XmppWebSocket> connect<S>(String host, int port,
      {String Function(String event)? map,
      List<String>? wsProtocols,
      String? wsPath,
      Uri? wsUri,
      bool useWebSocket = false,
      bool useWebTransport = false,
      bool useQuic = false,
      bool directTls = false,
      String? tlsHost}) async {
    if (useQuic) {
      throw UnsupportedError('QUIC is not implemented in XmppWebSocketIo');
    }
    _useWebSocket = useWebSocket || wsUri != null || wsPath != null;
    Log.i(TAG,
        'Socket connect: host=$host port=$port useWebSocket=$_useWebSocket directTls=$directTls');
    if (_useWebSocket) {
      final uri = wsUri ??
          Uri(
            scheme: port == 443 ? 'wss' : 'ws',
            host: host,
            port: port,
            path: wsPath,
          );
      Log.i(TAG, 'WebSocket URI: $uri');
      _webSocket = _webSocketConnect(uri, protocols: wsProtocols);
    } else {
      final connector = HappyEyeballsConnector(
        hostLookup: _hostLookup,
        tcpConnect: _tcpConnect,
        fallbackDelay: _happyEyeballsDelay,
        connectTimeout: _connectTimeout,
      );
      if (directTls) {
        Log.i(TAG, 'Direct TLS: SecureSocket.connect');
        final rawSocket = await connector.connect(host, port);
        _logHappyEyeballsWinner(rawSocket);
        _tcpSocket =
            await _secureSocketFactory(rawSocket, host: tlsHost ?? host);
      } else {
        Log.i(TAG, 'Plain TCP: HappyEyeballs connect');
        _tcpSocket = await connector.connect(host, port);
        _logHappyEyeballsWinner(_tcpSocket!);
      }
    }

    if (map != null) {
      _map = map;
    } else {
      _map = (element) => element;
    }

    return Future.value(this);
  }

  @override
  void close() {
    if (_useWebSocket) {
      _webSocket?.sink.close();
    } else {
      _tcpSocket?.close();
    }
  }

  @override
  void write(Object? message) {
    if (_useWebSocket) {
      if (_webSocket == null) {
        return;
      }
      Log.xmppp_sending(message.toString(), channel: 'ws');
      _webSocket!.sink.add(message);
    } else {
      if (_tcpSocket == null) {
        return;
      }
      Log.xmppp_sending(message.toString(), channel: 'tcp');
      _tcpSocket!.write(message);
    }
  }

  @override
  StreamSubscription<String> listen(void Function(String event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    final channel = _useWebSocket ? 'ws' : 'tcp';
    void logAndDeliver(String event) {
      Log.xmppp_receiving(event, channel: channel);
      onData?.call(event);
    }

    if (_useWebSocket) {
      return _webSocket!.stream
          .map((event) => event.toString())
          .map(_map)
          .listen(logAndDeliver,
              onError: onError, onDone: onDone, cancelOnError: cancelOnError);
    }
    return _tcpSocket!
        .cast<List<int>>()
        .transform(utf8.decoder)
        .map(_map)
        .listen(logAndDeliver,
            onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Future<SecureSocket?> secure(
      {host,
      SecurityContext? context,
      bool Function(X509Certificate certificate)? onBadCertificate,
      List<String>? supportedProtocols}) {
    if (_useWebSocket) {
      return Future.value(null);
    }
    Log.i(TAG, 'StartTLS: SecureSocket.secure');
    return _secureSocketFactory(
      _tcpSocket!,
      host: host,
      onBadCertificate: onBadCertificate,
      supportedProtocols: supportedProtocols,
    ).then((secureSocket) {
      if (secureSocket != null) {
        _tcpSocket = secureSocket;
      }
      return secureSocket;
    });
  }

  @override
  String getStreamOpeningElement(String domain) {
    return """<?xml version='1.0'?><stream:stream xmlns='jabber:client' version='1.0' xmlns:stream='http://etherx.jabber.org/streams' to='$domain' xml:lang='en'>""";
  }

  void _logHappyEyeballsWinner(Socket socket) {
    try {
      final address = socket.remoteAddress;
      Log.i(
          TAG,
          'HappyEyeballs winner: ${address.address}:${socket.remotePort} '
          'type=${address.type}');
    } catch (_) {
      // Mock/test sockets may not expose remote endpoint details.
    }
  }
}

typedef SecureSocketFactory = Future<SecureSocket> Function(
  Socket socket, {
  String? host,
  SecurityContext? context,
  bool Function(X509Certificate certificate)? onBadCertificate,
  List<String>? supportedProtocols,
});
typedef WebSocketChannelFactory = WebSocketChannel Function(
  Uri uri, {
  Iterable<String>? protocols,
});

Future<SecureSocket> _defaultSecureSocketFactory(
  Socket socket, {
  String? host,
  SecurityContext? context,
  bool Function(X509Certificate certificate)? onBadCertificate,
  List<String>? supportedProtocols,
}) {
  return SecureSocket.secure(
    socket,
    host: host,
    context: context,
    onBadCertificate: onBadCertificate,
    supportedProtocols: supportedProtocols,
  );
}

WebSocketChannel _defaultWebSocketConnect(
  Uri uri, {
  Iterable<String>? protocols,
}) {
  return WebSocketChannel.connect(uri, protocols: protocols);
}
