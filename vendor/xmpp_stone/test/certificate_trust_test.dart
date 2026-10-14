import 'dart:async';
import 'dart:typed_data';

import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';

class _FakeCertificate extends Mock implements X509Certificate {}

/// Captures the `onBadCertificate` callback passed to `connect()` for a
/// Direct TLS endpoint, so tests can simulate the TLS layer presenting an
/// invalid/unrecognized certificate and observe how [Connection] reacts.
class _FakeXmppSocket extends Stream<String> implements XmppWebSocket {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  bool Function(X509Certificate certificate)? capturedOnBadCertificate;

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
    bool Function(X509Certificate certificate)? onBadCertificate,
    Uint8List? pinnedCertSha256,
  }) async {
    capturedOnBadCertificate = onBadCertificate;
    return this;
  }

  @override
  void write(Object? message) {}

  @override
  void close() {
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  @override
  Future<dynamic> getQuicStats() => Future.value(null);
  @override
  bool get isQuic => false;

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
  group('Direct TLS certificate trust', () {
    late XmppAccountSettings account;
    late _FakeXmppSocket socket;
    late Connection connection;

    setUp(() {
      account = XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account.tcpEndpoints = const [
        XmppTcpEndpoint(host: 'example.com', port: 5223, directTls: true),
      ];
      socket = _FakeXmppSocket();
      connection = Connection(account, socketFactory: () => socket);
    });

    tearDown(() {
      connection.dispose();
    });

    test(
        'isCertificateTrusted=false rejects the certificate and reports it '
        'via onUntrustedCertificate', () async {
      var untrustedCalls = 0;
      account.isCertificateTrusted = (host, port, certificate) => false;
      account.onUntrustedCertificate = (host, port, certificate) {
        untrustedCalls++;
        expect(host, 'example.com');
        expect(port, 5223);
      };

      await connection.openSocket();
      final callback = socket.capturedOnBadCertificate;
      expect(callback, isNotNull);

      final accepted = callback!(_FakeCertificate());

      expect(accepted, isFalse);
      expect(untrustedCalls, 1);
    });

    test(
        'isCertificateTrusted=true accepts the certificate without '
        'reporting it as untrusted', () async {
      var untrustedCalls = 0;
      account.isCertificateTrusted = (host, port, certificate) => true;
      account.onUntrustedCertificate = (host, port, certificate) {
        untrustedCalls++;
      };

      await connection.openSocket();
      final callback = socket.capturedOnBadCertificate;
      expect(callback, isNotNull);

      final accepted = callback!(_FakeCertificate());

      expect(accepted, isTrue);
      expect(untrustedCalls, 0);
    });

    test('an unset isCertificateTrusted rejects by default (fail closed)',
        () async {
      await connection.openSocket();
      final callback = socket.capturedOnBadCertificate;
      expect(callback, isNotNull);

      expect(callback!(_FakeCertificate()), isFalse);
    });
  });
}
