import 'dart:async';
import 'dart:typed_data';
import 'package:universal_io/io.dart';

XmppWebSocket createSocket() {
  throw UnsupportedError('No implementation of the connect api provided');
}

bool isTlsRequired() {
  throw UnsupportedError('No implementation of the connect api provided');
}

abstract class XmppWebSocket extends Stream<String> {
  Future<XmppWebSocket> connect<S>(String host, int port,
      {String Function(String event)? map,
      String? wsPath,
      Uri? wsUri,
      bool useWebSocket = false,
      bool useWebTransport = false,
      bool useQuic = false,
      bool directTls = false,
      String? tlsHost,
      bool Function(X509Certificate certificate)? onBadCertificate,
      Uint8List? pinnedCertSha256});

  void write(Object? message);

  void close();

  bool get isQuic => false;

  Future<dynamic> getQuicStats() => Future.value(null);

  /// Cumulative bytes written to this socket since it was created.
  ///
  /// Used to estimate bandwidth on transports (TCP, WebSocket,
  /// WebTransport) that don't expose their own byte counters the way QUIC
  /// does via [getQuicStats]. Implementations that can't track this default
  /// to 0, which simply reports no measurable bandwidth.
  int get bytesSent => 0;

  /// Cumulative bytes read from this socket since it was created. See
  /// [bytesSent].
  int get bytesReceived => 0;

  Future<SecureSocket?> secure(
      {host,
      SecurityContext? context,
      bool Function(X509Certificate certificate)? onBadCertificate,
      List<String>? supportedProtocols});

  String getStreamOpeningElement(String domain);
}
