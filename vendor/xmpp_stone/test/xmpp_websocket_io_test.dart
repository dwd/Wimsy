import 'dart:async';
import 'dart:typed_data';

import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketIo.dart';

class MockSocket extends Mock implements Socket {}

class MockSecureSocket extends Mock implements SecureSocket {}

class MockWebSocketChannel extends Mock implements WebSocketChannel {}

class _FakeCertificate extends Mock implements X509Certificate {}

/// A minimal fake [WebSocketChannel] with a real, observable [sink] and
/// [stream], used to exercise byte-counting behaviour that a bare [Mock]
/// can't support (writing to/reading from a mocked sink/stream throws
/// without extensive stubbing).
class _FakeWebSocketChannel implements WebSocketChannel {
  final List<Object?> sentMessages = [];
  final StreamController<dynamic> _incoming = StreamController.broadcast();

  @override
  WebSocketSink get sink => _FakeWebSocketSink(sentMessages);

  @override
  Stream get stream => _incoming.stream;

  void addIncoming(dynamic data) => _incoming.add(data);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._sentMessages);

  final List<Object?> _sentMessages;

  @override
  void add(data) => _sentMessages.add(data);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A minimal fake [Socket] with observable writes, used to exercise
/// byte-counting for the raw-TCP path.
class _FakeTcpSocket extends Stream<Uint8List> implements Socket {
  final List<Object?> sentMessages = [];
  final StreamController<Uint8List> _incoming = StreamController.broadcast();

  @override
  void add(List<int> data) => sentMessages.add(data);

  @override
  void write(Object? object) => sentMessages.add(object);

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _incoming.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  void addIncoming(List<int> data) => _incoming.add(Uint8List.fromList(data));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  group('XmppWebSocketIo', () {
    test('Uses websocket factory when useWebSocket=true', () async {
      var tcpCalled = false;
      var wsCalled = false;
      final channel = MockWebSocketChannel();
      final addresses = <InternetAddress>[
        InternetAddress('203.0.113.10'),
      ];
      final socket = XmppWebSocketIo(
        hostLookup: (host, {type = InternetAddressType.any}) async => addresses,
        tcpConnect: (address, port, {timeout}) {
          tcpCalled = true;
          return Future.value(MockSocket());
        },
        webSocketConnect: (uri, {protocols}) {
          wsCalled = true;
          return channel;
        },
      );

      await socket.connect(
        'example.com',
        443,
        useWebSocket: true,
        wsUri: Uri.parse('wss://example.com/ws'),
      );

      expect(wsCalled, isTrue);
      expect(tcpCalled, isFalse);
    });

    test('Passes xmpp subprotocol when connecting via WebSocket', () async {
      Iterable<String>? capturedProtocols;
      final channel = MockWebSocketChannel();
      final socket = XmppWebSocketIo(
        webSocketConnect: (uri, {protocols}) {
          capturedProtocols = protocols;
          return channel;
        },
      );

      await socket.connect(
        'example.com',
        443,
        useWebSocket: true,
        wsUri: Uri.parse('wss://example.com/ws'),
      );

      expect(capturedProtocols, contains('xmpp'));
    });

    test('Direct TLS uses tcp + secure factories', () async {
      var tcpCalled = false;
      var secureCalled = false;
      final rawSocket = MockSocket();
      final secureSocket = MockSecureSocket();
      final addresses = <InternetAddress>[
        InternetAddress('203.0.113.20'),
      ];
      final socket = XmppWebSocketIo(
        hostLookup: (host, {type = InternetAddressType.any}) async => addresses,
        tcpConnect: (address, port, {timeout}) {
          tcpCalled = true;
          expect(timeout, const Duration(seconds: 5));
          return Future.value(rawSocket);
        },
        secureSocketFactory: (socket,
            {host, context, onBadCertificate, supportedProtocols}) {
          secureCalled = true;
          return Future.value(secureSocket);
        },
      );

      await socket.connect(
        'example.com',
        5223,
        directTls: true,
      );

      expect(tcpCalled, isTrue);
      expect(secureCalled, isTrue);
    });

    test('Direct TLS forwards onBadCertificate to the secure socket factory',
        () async {
      // Regression test for the TLS trust-on-first-use flow: Direct TLS
      // must let the caller (ultimately Connection._validateCertificateTrust)
      // decide whether an otherwise-invalid certificate should be accepted,
      // rather than always accepting or always rejecting it.
      bool Function(X509Certificate certificate)? capturedCallback;
      final rawSocket = MockSocket();
      final secureSocket = MockSecureSocket();
      final socket = XmppWebSocketIo(
        hostLookup: (host, {type = InternetAddressType.any}) async =>
            <InternetAddress>[InternetAddress('203.0.113.21')],
        tcpConnect: (address, port, {timeout}) => Future.value(rawSocket),
        secureSocketFactory: (socket,
            {host, context, onBadCertificate, supportedProtocols}) {
          capturedCallback = onBadCertificate;
          return Future.value(secureSocket);
        },
      );

      var decisionCalls = 0;
      await socket.connect(
        'example.com',
        5223,
        directTls: true,
        onBadCertificate: (certificate) {
          decisionCalls++;
          return false;
        },
      );

      expect(capturedCallback, isNotNull);
      expect(capturedCallback!(_FakeCertificate()), isFalse);
      expect(decisionCalls, 1);
    });

    test('Happy Eyeballs falls back from IPv6 to IPv4', () async {
      final attempted = <InternetAddressType>[];
      final v6 = InternetAddress('2001:db8::1');
      final v4 = InternetAddress('203.0.113.30');
      final socket = XmppWebSocketIo(
        hostLookup: (host, {type = InternetAddressType.any}) async => [v6, v4],
        tcpConnect: (address, port, {timeout}) {
          attempted.add(address.type);
          if (address.type == InternetAddressType.IPv6) {
            throw const SocketException('IPv6 failed');
          }
          return Future.value(MockSocket());
        },
        happyEyeballsDelay: Duration.zero,
      );

      await socket.connect('example.com', 5222);

      expect(attempted, [InternetAddressType.IPv6, InternetAddressType.IPv4]);
    });

    test('literal IPv4 and IPv6 hosts bypass hostname lookup', () async {
      var lookupCount = 0;
      final attempted = <InternetAddress>[];
      final socket = XmppWebSocketIo(
        hostLookup: (host, {type = InternetAddressType.any}) async {
          lookupCount++;
          return <InternetAddress>[];
        },
        tcpConnect: (address, port, {timeout}) {
          attempted.add(address);
          return Future.value(MockSocket());
        },
        happyEyeballsDelay: Duration.zero,
      );

      await socket.connect('192.0.2.10', 5222);
      await socket.connect('[2001:db8::10]', 5222);

      expect(lookupCount, 0);
      expect(attempted.map((address) => address.address), [
        '192.0.2.10',
        '2001:db8::10',
      ]);
    });

    test('Happy Eyeballs throws after exhausting all addresses', () async {
      final attempted = <InternetAddressType>[];
      final v6 = InternetAddress('2001:db8::2');
      final v4 = InternetAddress('203.0.113.40');
      final socket = XmppWebSocketIo(
        hostLookup: (host, {type = InternetAddressType.any}) async => [v6, v4],
        tcpConnect: (address, port, {timeout}) {
          attempted.add(address.type);
          throw const SocketException('unreachable');
        },
        happyEyeballsDelay: Duration.zero,
      );

      await expectLater(
        socket.connect('example.com', 5222),
        throwsA(isA<SocketException>()),
      );
      expect(attempted, [InternetAddressType.IPv6, InternetAddressType.IPv4]);
    });

    test('bytesSent/bytesReceived track WebSocket traffic', () async {
      final channel = _FakeWebSocketChannel();
      final socket = XmppWebSocketIo(
        webSocketConnect: (uri, {protocols}) => channel,
      );

      await socket.connect(
        'example.com',
        443,
        useWebSocket: true,
        wsUri: Uri.parse('wss://example.com/ws'),
      );

      expect(socket.bytesSent, 0);
      expect(socket.bytesReceived, 0);

      socket.write('<hello/>');
      expect(socket.bytesSent, '<hello/>'.length);

      final received = <String>[];
      socket.listen(received.add);
      channel.addIncoming('<world/>');
      await Future<void>.delayed(Duration.zero);

      expect(received, ['<world/>']);
      expect(socket.bytesReceived, '<world/>'.length);

      socket.write('!');
      expect(socket.bytesSent, '<hello/>!'.length);
    });

    test('bytesSent/bytesReceived track raw TCP traffic', () async {
      final rawSocket = _FakeTcpSocket();
      final socket = XmppWebSocketIo(
        hostLookup: (host, {type = InternetAddressType.any}) async =>
            <InternetAddress>[InternetAddress('203.0.113.50')],
        tcpConnect: (address, port, {timeout}) => Future.value(rawSocket),
      );

      await socket.connect('example.com', 5222);

      expect(socket.bytesSent, 0);
      expect(socket.bytesReceived, 0);

      socket.write('<presence/>');
      expect(socket.bytesSent, '<presence/>'.length);

      final received = <String>[];
      socket.listen(received.add);
      rawSocket.addIncoming('<iq/>'.codeUnits);
      await Future<void>.delayed(Duration.zero);

      expect(received, ['<iq/>']);
      expect(socket.bytesReceived, '<iq/>'.length);
    });
  });
}
