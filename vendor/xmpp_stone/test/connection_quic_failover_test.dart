import 'dart:async';

import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';
import 'package:xmpp_stone/src/connection/XmppEarlyDataSocket.dart';

class _RecordingSocket extends Stream<String> implements XmppWebSocket {
  _RecordingSocket(this.attempts, {this.quicDelay, this.quicSucceeds = false});

  final List<String> attempts;
  final Duration? quicDelay;
  final bool quicSucceeds;
  bool _isQuic = false;
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
    bool useWebTransport = false,
    bool useQuic = false,
    bool directTls = false,
    String? tlsHost,
  }) async {
    final transport = useWebSocket
        ? 'websocket'
        : (useQuic ? 'quic' : (directTls ? 'tcp-direct-tls' : 'tcp'));
    attempts.add('$transport:$host:$port');
    if (useQuic) {
      _isQuic = true;
      if (quicDelay != null) await Future<void>.delayed(quicDelay!);
      if (!quicSucceeds) throw Exception('quic failed');
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
  Future<dynamic> getQuicStats() => Future.value(null);
  @override
  bool get isQuic => _isQuic;

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

class _EarlySocket extends _RecordingSocket implements XmppEarlyDataSocket {
  _EarlySocket() : super([], quicSucceeds: true);
  @override
  bool allowEarlyData = false;
  @override
  bool get earlyDataPending => allowEarlyData;
  final writes = <String>[];
  void Function()? beforeAttach;
  @override
  void write(Object? message) => writes.add(message.toString());
  void setAuxMapperFactory(String Function(String) Function() factory) =>
      beforeAttach?.call();
}

void main() {
  test(
      'token expiry during acquisition cannot send password auth as early data',
      () async {
    final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
      ..quicEndpoints = [XmppQuicEndpoint(host: 'quic.example.com', port: 443)]
      ..tcpEndpoints = []
      ..sasl2CachedFastTls0Rtt = true
      ..fastToken = 'token'
      ..fastMechanism = 'HT-SHA-256-NONE'
      ..sasl2CachedFastMechanisms = ['HT-SHA-256-NONE']
      ..sasl2CachedMechanisms = ['PLAIN']
      ..sasl2LastMechanism = 'PLAIN'
      ..iapConfigVersionValue = 'v1'
      ..sasl2UserAgentId = '12cf3230-c260-4e59-8adc-ddb96f2bef53'
      ..persistFastCounter = (_) async {};
    final socket = _EarlySocket()
      ..beforeAttach = () {
        account.fastTokenExpiry = '2000-01-01T00:00:00Z';
      };
    final connection = Connection(account, socketFactory: () => socket);
    await connection.openSocket();
    await Future<void>.delayed(Duration.zero);
    expect(socket.allowEarlyData, isTrue);
    expect(socket.writes.where((write) => write.contains('authenticate')),
        isEmpty);
    expect(connection.state, XmppConnectionState.ForcefullyClosed);
    connection.dispose();
  });

  test(
      'early acquisition requires FAST permission, token, identity and durable counter',
      () async {
    for (final missing in [
      'none',
      'permission',
      'token',
      'identity',
      'storage'
    ]) {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..quicEndpoints = [
          XmppQuicEndpoint(host: 'quic.example.com', port: 443)
        ]
        ..tcpEndpoints = []
        ..sasl2CachedFastTls0Rtt = missing != 'permission'
        ..fastToken = missing == 'token' ? '' : 'token'
        ..fastMechanism = 'HT-SHA-256-NONE'
        ..sasl2CachedFastMechanisms = ['HT-SHA-256-NONE']
        ..iapConfigVersionValue = 'v1'
        ..sasl2UserAgentId = missing == 'identity'
            ? null
            : '12cf3230-c260-4e59-8adc-ddb96f2bef53';
      if (missing != 'storage') account.persistFastCounter = (_) async {};
      final socket = _EarlySocket();
      final connection = Connection(account, socketFactory: () => socket);
      await connection.openSocket();
      expect(socket.allowEarlyData, missing == 'none', reason: missing);
      connection.dispose();
    }
  });

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
    account.quicExclusiveHeadStart = const Duration(milliseconds: 10);

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

  test('TCP safety net starts after the QUIC-exclusive head start', () async {
    final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
      ..quicEndpoints = const <XmppQuicEndpoint>[
        XmppQuicEndpoint(host: 'quic.example.com', port: 443),
      ]
      ..tcpEndpoints = const <XmppTcpEndpoint>[
        XmppTcpEndpoint(host: 'tcp.example.com', port: 5222, directTls: false),
      ]
      ..quicExclusiveHeadStart = const Duration(milliseconds: 10);
    final attempts = <String>[];
    var socketNumber = 0;
    final connection = Connection(
      account,
      socketFactory: () => _RecordingSocket(
        attempts,
        quicDelay:
            socketNumber++ == 0 ? const Duration(milliseconds: 50) : null,
      ),
    );

    await connection.openSocket();

    expect(attempts, ['quic:quic.example.com:443', 'tcp:tcp.example.com:5222']);
    expect(connection.socket!.isQuic, isFalse);
    connection.dispose();
  });

  test('network cancellation supersedes an in-flight acquisition', () async {
    final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
      ..quicEndpoints = const <XmppQuicEndpoint>[
        XmppQuicEndpoint(host: 'quic.example.com', port: 443),
      ]
      ..tcpEndpoints = const <XmppTcpEndpoint>[];
    final connection = Connection(
      account,
      socketFactory: () => _RecordingSocket(
        <String>[],
        quicDelay: const Duration(milliseconds: 20),
        quicSucceeds: true,
      ),
    );

    final opening = connection.openSocket();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    connection.cancelSocketAcquisition();

    await opening;
    expect(connection.socket, isNull);
    expect(connection.state, XmppConnectionState.ForcefullyClosed);
    connection.dispose();
  });

  test('each logical acquisition refreshes its endpoint plan', () async {
    final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
      ..quicEndpoints = const <XmppQuicEndpoint>[]
      ..tcpEndpoints = const <XmppTcpEndpoint>[
        XmppTcpEndpoint(
            host: 'stale.example.com', port: 5222, directTls: false),
      ]
      ..refreshEndpoints = () async => const XmppEndpointRefreshResult(
            quic: <XmppQuicEndpoint>[],
            tcp: <XmppTcpEndpoint>[
              XmppTcpEndpoint(
                  host: 'fresh.example.com', port: 5222, directTls: false),
            ],
          );
    final attempts = <String>[];
    final connection = Connection(
      account,
      socketFactory: () => _RecordingSocket(attempts),
    );

    await connection.openSocket();

    expect(attempts, ['tcp:fresh.example.com:5222']);
    connection.dispose();
  });
}
