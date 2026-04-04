import 'dart:async';

import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';

class _RecordingSocket extends Stream<String> implements XmppWebSocket {
  _RecordingSocket(this.attempts);

  final List<String> attempts;
  final _controller = StreamController<String>.broadcast();

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
    final transport = useWebSocket
        ? 'websocket'
        : (useQuic ? 'quic' : (directTls ? 'tcp-direct-tls' : 'tcp'));
    attempts.add('$transport:$host:$port');
    if (useQuic) {
      throw Exception('quic failed');
    }
    return this;
  }

  @override
  void write(Object? message) {}

  @override
  void close() {
    _controller.close();
  }

  @override
  Future<SecureSocket?> secure({
    host,
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    List<String>? supportedProtocols,
  }) async {
    return null;
  }

  @override
  String getStreamOpeningElement(String domain) {
    return "<stream:stream to='$domain'>";
  }

  @override
  StreamSubscription<String> listen(
    void Function(String event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

void main() {
  test('Connection falls back to TCP endpoints when QUIC endpoints fail',
      () async {
    final account = XmppAccountSettings.fromJid('alice@example.com', 'secret');
    account.quicEndpoints = const <XmppQuicEndpoint>[
      XmppQuicEndpoint(
          host: 'quic.example.com', port: 443, tlsHost: 'example.com'),
    ];
    account.tcpEndpoints = const <XmppTcpEndpoint>[
      XmppTcpEndpoint(
        host: 'tcp.example.com',
        port: 5222,
        directTls: false,
        tlsHost: 'example.com',
      ),
    ];

    final attempts = <String>[];
    final connection = Connection(
      account,
      socketFactory: () => _RecordingSocket(attempts),
    );

    await connection.openSocket();

    expect(
      attempts,
      equals(<String>[
        'quic:quic.example.com:443',
        'tcp:tcp.example.com:5222',
      ]),
    );
    expect(connection.state, XmppConnectionState.SocketOpened);

    connection.dispose();
  });
}
