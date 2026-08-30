import 'dart:async';

import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';
import 'package:xmpp_stone/src/features/streammanagement/KeepaliveState.dart';
import 'package:xmpp_stone/src/features/streammanagement/StreamManagmentModule.dart';

class _FakeSocket extends Stream<String> implements XmppWebSocket {
  _FakeSocket({this.quic = false});

  final bool quic;
  final List<String> writes = <String>[];

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
    return this;
  }

  @override
  void write(Object? message) {
    writes.add(message.toString());
  }

  @override
  void close() {}
  @override
  Future<dynamic> getQuicStats() => Future.value(null);
  @override
  bool get isQuic => quic;

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
    return '<stream:stream to="$domain">';
  }

  @override
  StreamSubscription<String> listen(
    void Function(String event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return const Stream<String>.empty().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class _ConnectionSetup {
  const _ConnectionSetup({required this.connection, required this.socket});

  final Connection connection;
  final _FakeSocket socket;
}

void main() {
  _ConnectionSetup _newConnection() {
    final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
      ..bufferedWritesEnabled = false;
    final connection = Connection.getInstance(account);
    StreamManagementModule.getInstance(connection);
    final socket = _FakeSocket();
    connection.socket = socket;
    connection.setState(XmppConnectionState.SessionInitialized);
    return _ConnectionSetup(connection: connection, socket: socket);
  }

  tearDown(() {
    for (final connection in Connection.instances.values.toList()) {
      connection.dispose();
      Connection.removeInstance(connection.account);
    }
  });

  test('probeKeepalive sends ping and reports latency on IQ response',
      () async {
    final setup = _newConnection();
    final connection = setup.connection;
    final fakeSocket = setup.socket;
    final states = <KeepaliveState>[];
    final sub = connection.keepaliveStateStream.listen(states.add);
    await Future<void>.delayed(Duration.zero);

    connection.probeKeepalive(shortTimeout: true);

    expect(fakeSocket.writes, isNotEmpty);
    final pingXml = fakeSocket.writes.last;
    expect(pingXml, contains('urn:xmpp:ping'));
    final idMatch = RegExp("id=['\\\"]([^'\\\"]+)['\\\"]").firstMatch(pingXml);
    expect(idMatch, isNotNull);
    final id = idMatch!.group(1)!;

    await Future<void>.delayed(Duration.zero);
    connection.fireNewStanzaEvent(IqStanza(id, IqStanzaType.RESULT));
    await Future<void>.delayed(Duration.zero);

    expect(states.last.lastLatency, isNotNull);
    await sub.cancel();
  });

  test('probeKeepalive emits ping timeout failure', () async {
    final setup = _newConnection();
    final connection = setup.connection;
    final failureFuture = connection.keepaliveFailureStream.first;
    await Future<void>.delayed(Duration.zero);

    connection.probeKeepalive(shortTimeout: true);
    final failure = await failureFuture.timeout(const Duration(seconds: 8));

    expect(failure.reason, KeepaliveFailureReason.pingTimeout);
    expect(failure.shortTimeout, isTrue);
  });

  test('probeKeepalive does not send an XMPP ping on QUIC', () async {
    final account = XmppAccountSettings.fromJid('quic@example.com', 'secret')
      ..bufferedWritesEnabled = false;
    final connection = Connection.getInstance(account);
    StreamManagementModule.getInstance(connection);
    final socket = _FakeSocket(quic: true);
    connection.socket = socket;

    connection.probeKeepalive(shortTimeout: true);
    await Future<void>.delayed(Duration.zero);

    expect(socket.writes, isEmpty);
  });

  test('leaving Ready clears a pending keepalive probe', () async {
    final setup = _newConnection();
    final states = <KeepaliveState>[];
    final subscription = setup.connection.keepaliveStateStream.listen(
      states.add,
    );
    await Future<void>.delayed(Duration.zero);

    setup.connection.probeKeepalive(shortTimeout: true);
    await Future<void>.delayed(Duration.zero);
    expect(states.last.awaitingPing, isTrue);

    setup.connection.setState(XmppConnectionState.Authenticating);
    await Future<void>.delayed(Duration.zero);

    expect(states.last.awaitingPing, isFalse);
    await subscription.cancel();
  });

  test('pre-bind write gate rejects ordinary stanzas', () {
    final setup = _newConnection();
    setup.connection.setState(XmppConnectionState.Authenticating);

    setup.connection.write(
      '<iq id="stale"><ping xmlns="urn:xmpp:ping"/></iq>',
    );
    setup.connection.write('<active xmlns="urn:xmpp:csi:0"/>');

    expect(setup.socket.writes, isEmpty);
  });

  test('pre-bind write gate permits negotiation and post-bind traffic', () {
    final setup = _newConnection();
    setup.connection.setState(XmppConnectionState.Authenticating);

    setup.connection.write(
      "<?xml version='1.0'?><stream:stream to='example.com'>"
      '<authenticate xmlns="urn:xmpp:sasl:2" mechanism="PLAIN"/>',
    );
    expect(setup.socket.writes, hasLength(1));

    setup.connection.setState(XmppConnectionState.SessionInitialized);
    setup.connection.write('<presence/>');
    expect(setup.socket.writes, hasLength(2));
  });

  test('StreamManagementModule.configure overrides start out at defaults', () {
    final setup = _newConnection();
    final module = StreamManagementModule.getInstance(setup.connection);

    expect(
      module.smAckIntervalForeground,
      StreamManagementModule.defaultSmAckIntervalForeground,
    );
    expect(
      module.pingIntervalBackground,
      StreamManagementModule.defaultPingIntervalBackground,
    );
    expect(
      module.keepaliveMaxTimeout,
      StreamManagementModule.defaultKeepaliveMaxTimeout,
    );
  });

  test('StreamManagementModule.configure applies only the given overrides', () {
    final setup = _newConnection();
    final module = StreamManagementModule.getInstance(setup.connection);

    module.configure(
      smAckIntervalForeground: const Duration(seconds: 10),
      pingIntervalBackground: const Duration(minutes: 2),
    );

    expect(module.smAckIntervalForeground, const Duration(seconds: 10));
    expect(module.pingIntervalBackground, const Duration(minutes: 2));
    // Untouched values keep their defaults.
    expect(
      module.smAckIntervalBackground,
      StreamManagementModule.defaultSmAckIntervalBackground,
    );
    expect(
      module.pingIntervalForeground,
      StreamManagementModule.defaultPingIntervalForeground,
    );
    expect(
      module.pendingAckRequestDelay,
      StreamManagementModule.defaultPendingAckRequestDelay,
    );
    expect(
      module.keepaliveMaxTimeout,
      StreamManagementModule.defaultKeepaliveMaxTimeout,
    );
  });

  test('Connection.configureKeepalive forwards to the stream management module',
      () {
    final setup = _newConnection();
    final connection = setup.connection;

    connection.configureKeepalive(
      pendingAckRequestDelay: const Duration(seconds: 3),
      keepaliveMaxTimeout: const Duration(seconds: 90),
    );

    final module = StreamManagementModule.getInstance(connection);
    expect(module.pendingAckRequestDelay, const Duration(seconds: 3));
    expect(module.keepaliveMaxTimeout, const Duration(seconds: 90));
  });

  test(
      'Connection.configureKeepalive is a no-op without a stream management module',
      () {
    final account = XmppAccountSettings.fromJid('bob@example.com', 'secret')
      ..bufferedWritesEnabled = false;
    final connection = Connection.getInstance(account);
    // Deliberately do not call StreamManagementModule.getInstance.
    expect(
      () => connection.configureKeepalive(
        pendingAckRequestDelay: const Duration(seconds: 1),
      ),
      returnsNormally,
    );
  });
}
