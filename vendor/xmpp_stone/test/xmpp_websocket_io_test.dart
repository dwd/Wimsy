import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketIo.dart';

class MockSocket extends Mock implements Socket {}

class MockSecureSocket extends Mock implements SecureSocket {}

class MockWebSocketChannel extends Mock implements WebSocketChannel {}

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
  });
}
