import 'dart:async';
import 'package:universal_io/io.dart';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';
import 'package:xmpp_stone/src/connection/XmppWebTransportHtml.dart';

export 'XmppWebsocketApi.dart';

XmppWebSocket createSocket() {
  return XmppWebSocketHtml();
}

bool isTlsRequired() {
  // return the `false`, cause for the 'html' socket initially creates as secured
  return false;
}

class XmppWebSocketHtml extends XmppWebSocket {
  static String TAG = 'XmppWebSocketIo';

  WebSocketChannel? _socket;
  late String Function(String event) _map;

  // When the caller requests WebTransport and the browser supports it, we
  // delegate all operations to an XmppWebTransportHtml instance.
  XmppWebTransportHtml? _webTransportDelegate;

  XmppWebSocketHtml();

  @override
  Future<XmppWebSocket> connect<S>(String host, int port,
      {String Function(String event)? map,
      String? wsPath,
      Uri? wsUri,
      bool useWebSocket = true,
      bool useWebTransport = false,
      bool useQuic = false,
      bool directTls = false,
      String? tlsHost}) async {
    // Try WebTransport first when requested and supported by the browser.
    if (useWebTransport && XmppWebTransportHtml.isSupported()) {
      final wt = XmppWebTransportHtml();
      await wt.connect<S>(
        host,
        port,
        map: map,
        wsPath: wsPath,
        wsUri: wsUri,
        useWebTransport: true,
        directTls: directTls,
        tlsHost: tlsHost,
      );
      _webTransportDelegate = wt;
      return this;
    }

    // Fall back to plain WebSocket.
    final uri = wsUri ??
        Uri(
          scheme: 'wss',
          host: host,
          port: port,
          path: wsPath,
        );
    _socket = WebSocketChannel.connect(uri);

    if (map != null) {
      _map = map;
    } else {
      _map = (element) => element;
    }

    return Future.value(this);
  }

  @override
  void close() {
    if (_webTransportDelegate != null) {
      _webTransportDelegate!.close();
    } else {
      _socket?.sink.close();
    }
  }

  @override
  void write(Object? message) {
    if (_webTransportDelegate != null) {
      _webTransportDelegate!.write(message);
    } else {
      _socket?.sink.add(message);
    }
  }

  @override
  StreamSubscription<String> listen(void Function(String event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    if (_webTransportDelegate != null) {
      return _webTransportDelegate!.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
    }
    return _socket!.stream.map((event) => event.toString()).map(_map).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError);
  }

  @override
  Future<SecureSocket?> secure(
      {host,
      SecurityContext? context,
      bool Function(X509Certificate certificate)? onBadCertificate,
      List<String>? supportedProtocols}) {
    // return the `null`, cause for the 'html' socket initially creates as secured
    return Future.value(null);
  }

  /// True when this socket is backed by a WebTransport connection.
  bool get isWebTransport => _webTransportDelegate != null;

  @override
  String getStreamOpeningElement(String domain) {
    return """<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' to='$domain' version='1.0'/>""";
  }
}
