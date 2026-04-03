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

    connection.probeKeepalive(shortTimeout: true);
    final failure = await failureFuture.timeout(const Duration(seconds: 8));

    expect(failure.reason, KeepaliveFailureReason.pingTimeout);
    expect(failure.shortTimeout, isTrue);
  });
}
