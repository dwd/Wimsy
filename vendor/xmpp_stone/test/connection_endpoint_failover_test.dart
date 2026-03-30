import 'dart:async';

import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';

class _FakeXmppSocket extends XmppWebSocket {
  _FakeXmppSocket({
    this.connectError,
  });

  final Object? connectError;
  int connectCalls = 0;
  final List<String> writes = <String>[];
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  @override
  Future<XmppWebSocket> connect<S>(
    String host,
    int port, {
    String Function(String event)? map,
    List<String>? wsProtocols,
    String? wsPath,
    Uri? wsUri,
    bool useWebSocket = false,
    bool directTls = false,
    String? tlsHost,
  }) async {
    connectCalls += 1;
    if (connectError != null) {
      throw connectError!;
    }
    return this;
  }

  @override
  void close() {
    if (!_controller.isClosed) {
      _controller.close();
    }
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

  @override
  Future<SecureSocket?> secure({
    host,
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    List<String>? supportedProtocols,
  }) {
    return Future<SecureSocket?>.value(null);
  }

  @override
  void write(Object? message) {
    writes.add(message.toString());
  }
}

void main() {
  test('Connection retries next endpoint when first endpoint fails', () async {
    final account = XmppAccountSettings.fromJid('alice@example.com', 'secret');
    account.tcpEndpoints = const <XmppTcpEndpoint>[
      XmppTcpEndpoint(host: 'first.example', port: 5222, directTls: false),
      XmppTcpEndpoint(host: 'second.example', port: 5222, directTls: false),
    ];
    final first = _FakeXmppSocket(connectError: Exception('first failed'));
    final second = _FakeXmppSocket();
    final sockets = <_FakeXmppSocket>[first, second];
    final connection = Connection(
      account,
      socketFactory: () => sockets.removeAt(0),
    );

    await connection.openSocket();

    expect(connection.state, XmppConnectionState.SocketOpened);
    expect(first.connectCalls, 1);
    expect(second.connectCalls, 1);
    expect(second.writes.single, contains("to='example.com'"));
    connection.dispose();
  });

  test('Connection forcefully closes when all endpoints fail', () async {
    final account = XmppAccountSettings.fromJid('alice@example.com', 'secret');
    account.tcpEndpoints = const <XmppTcpEndpoint>[
      XmppTcpEndpoint(host: 'first.example', port: 5222, directTls: false),
      XmppTcpEndpoint(host: 'second.example', port: 5222, directTls: false),
    ];
    final sockets = <_FakeXmppSocket>[
      _FakeXmppSocket(connectError: Exception('first failed')),
      _FakeXmppSocket(connectError: Exception('second failed')),
    ];
    final connection = Connection(
      account,
      socketFactory: () => sockets.removeAt(0),
    );

    await connection.openSocket();

    expect(connection.state, XmppConnectionState.ForcefullyClosed);
    connection.dispose();
  });
}
