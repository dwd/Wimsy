import 'package:flutter_test/flutter_test.dart';
import 'package:zimpy/xmpp/ws_endpoint.dart';

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
}
