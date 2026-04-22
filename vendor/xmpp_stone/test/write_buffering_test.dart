import 'dart:async';

import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';

void main() {
  group('Connection write buffering', () {
    test('coalesces back-to-back writes into one socket write', () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..bufferedWritesEnabled = true;
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;
      connection.setState(XmppConnectionState.SocketOpened);

      connection.write('<iq id="1"/>');
      connection.write('<iq id="2"/>');

      await Future<void>.delayed(Duration.zero);

      expect(socket.writes, hasLength(1));
      expect(socket.writes.single, equals('<iq id="1"/><iq id="2"/>'));
    });

    test('can disable buffering and keep one write per element', () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..bufferedWritesEnabled = false;
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;
      connection.setState(XmppConnectionState.SocketOpened);

      connection.write('<iq id="1"/>');
      connection.write('<iq id="2"/>');

      expect(socket.writes, hasLength(2));
      expect(socket.writes[0], equals('<iq id="1"/>'));
      expect(socket.writes[1], equals('<iq id="2"/>'));
    });

    test('handles broken pipe during buffered flush without uncaught error',
        () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..bufferedWritesEnabled = true;
      final connection = Connection(account);
      final socket = _ThrowingSocket();
      connection.socket = socket;
      connection.setState(XmppConnectionState.SocketOpened);

      connection.write('<iq id="1"/>');
      await Future<void>.delayed(Duration.zero);

      expect(connection.state, XmppConnectionState.ForcefullyClosed);
    });
  });
}

class _RecordingSocket extends Stream<String> implements XmppWebSocket {
  final _controller = StreamController<String>.broadcast();
  final writes = <String>[];

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
    return this;
  }

  @override
  void write(Object? message) {
    writes.add(message?.toString() ?? '');
  }

  @override
  void close() {
    _controller.close();
  }
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
    return "<stream:stream to='$domain'/>";
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

class _ThrowingSocket extends _RecordingSocket {
  @override
  void write(Object? message) {
    throw const SocketException('Broken pipe', osError: OSError('Broken pipe'));
  }
}
