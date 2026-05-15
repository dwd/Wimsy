import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/ws_endpoint.dart';

void main() {
  test('parses full wss endpoint', () {
    final config = parseWsEndpoint('wss://example.com/xmpp-websocket');
    expect(config, isNotNull);
    expect(config!.scheme, 'wss');
    expect(config.host, 'example.com');
    expect(config.port, 443);
    expect(config.path, '/xmpp-websocket');
  });

  test('defaults scheme and path', () {
    final config = parseWsEndpoint('example.com');
    expect(config, isNotNull);
    expect(config!.scheme, 'wss');
    expect(config.host, 'example.com');
    expect(config.port, 443);
    expect(config.path, '/xmpp-websocket');
  });

  test('preserves ws port', () {
    final config = parseWsEndpoint('ws://example.com:5280/xmpp-websocket');
    expect(config, isNotNull);
    expect(config!.scheme, 'ws');
    expect(config.host, 'example.com');
    expect(config.port, 5280);
    expect(config.path, '/xmpp-websocket');
  });

  test('rejects empty input', () {
    final config = parseWsEndpoint(' ');
    expect(config, isNull);
  });

  test('rejects unknown scheme', () {
    final config = parseWsEndpoint('ftp://example.com/xmpp');
    expect(config, isNull);
  });

  test('parses https WebTransport URL', () {
    final config = parseWsEndpoint('https://example.com/xmpp-webtransport');
    expect(config, isNotNull);
    expect(config!.scheme, 'https');
    expect(config.host, 'example.com');
    expect(config.port, 443);
    expect(config.path, '/xmpp-webtransport');
    expect(config.isWebTransport, isTrue);
  });

  test('parses http WebTransport URL with custom port', () {
    final config = parseWsEndpoint('http://example.com:4433/xmpp-webtransport');
    expect(config, isNotNull);
    expect(config!.scheme, 'http');
    expect(config.port, 4433);
    expect(config.isWebTransport, isTrue);
  });

  test('defaults path for https when missing', () {
    final config = parseWsEndpoint('https://example.com');
    expect(config, isNotNull);
    expect(config!.path, '/xmpp-webtransport');
  });

  test('isWebTransport is false for wss', () {
    final config = parseWsEndpoint('wss://example.com/xmpp-websocket');
    expect(config, isNotNull);
    expect(config!.isWebTransport, isFalse);
  });
}
