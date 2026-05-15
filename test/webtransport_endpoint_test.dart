import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/alt_connection_parser.dart';
import 'package:wimsy/xmpp/ws_endpoint.dart';

/// Tests for WebTransport endpoint URI handling and the fallback logic that
/// selects WebTransport over WebSocket when both are advertised.

void main() {
  group('WebTransport URI construction', () {
    test('https:// URI is preserved as-is', () {
      const raw = 'https://xmpp.example.com/webtransport';
      final uri = Uri.parse(raw);
      expect(uri.scheme, 'https');
      expect(uri.host, 'xmpp.example.com');
      expect(uri.path, '/webtransport');
    });

    test('wss:// URI is rewritten to https://', () {
      final wss = Uri.parse('wss://xmpp.example.com/webtransport');
      final https = wss.replace(scheme: 'https');
      expect(https.scheme, 'https');
      expect(https.host, 'xmpp.example.com');
      expect(https.path, '/webtransport');
    });

    test('default port is 443 when no port specified', () {
      final uri = Uri.parse('https://xmpp.example.com/webtransport');
      final port = uri.hasPort ? uri.port : 443;
      expect(port, 443);
    });

    test('explicit port is preserved', () {
      final uri = Uri.parse('https://xmpp.example.com:4433/webtransport');
      final port = uri.hasPort ? uri.port : 443;
      expect(port, 4433);
    });

    test('empty path falls back to /webtransport', () {
      final uri = Uri.parse('https://xmpp.example.com');
      final path = uri.path.isEmpty ? '/webtransport' : uri.path;
      expect(path, '/webtransport');
    });
  });

  group('WebTransport discovery takes priority over WebSocket', () {
    /// Simulates the selection logic in xmpp_service.dart:
    /// if a WebTransport URI is discovered, it is preferred over WebSocket.
    Uri? selectEndpoint({Uri? wtUri, Uri? wsUri}) {
      if (wtUri != null) return wtUri;
      return wsUri;
    }

    test('WebTransport URI is selected when both are present', () {
      final wt = Uri.parse('https://xmpp.example.com/webtransport');
      final ws = Uri.parse('wss://xmpp.example.com/ws');
      final selected = selectEndpoint(wtUri: wt, wsUri: ws);
      expect(selected, wt);
    });

    test('WebSocket URI is selected when WebTransport is absent', () {
      final ws = Uri.parse('wss://xmpp.example.com/ws');
      final selected = selectEndpoint(wtUri: null, wsUri: ws);
      expect(selected, ws);
    });

    test('null is returned when neither is present', () {
      final selected = selectEndpoint(wtUri: null, wsUri: null);
      expect(selected, isNull);
    });
  });

  group('parseWsEndpoint rejects https:// (WebTransport URIs bypass it)', () {
    test('parseWsEndpoint returns null for https:// URI', () {
      final result = parseWsEndpoint('https://xmpp.example.com/webtransport');
      expect(result, isNull);
    });

    test('parseWsEndpoint accepts wss:// URI', () {
      final result = parseWsEndpoint('wss://xmpp.example.com/ws');
      expect(result, isNotNull);
      expect(result!.scheme, 'wss');
    });
  });

  group('WebTransport JSON parser integration', () {
    test('prefers first matching WebTransport link', () {
      const json = '''
{
  "links": [
    {"rel": "urn:xmpp:webtransport:0", "href": "https://primary.example.com/wt"},
    {"rel": "urn:xmpp:webtransport:0", "href": "https://secondary.example.com/wt"}
  ]
}
''';
      final uri = parseHostMetaWebTransportJson(json);
      expect(uri.toString(), 'https://primary.example.com/wt');
    });

    test('ignores entries with empty href and template', () {
      const json = '''
{
  "links": [
    {"rel": "urn:xmpp:webtransport:0", "href": ""},
    {"rel": "urn:xmpp:webtransport:0", "href": "https://xmpp.example.com/wt"}
  ]
}
''';
      final uri = parseHostMetaWebTransportJson(json);
      expect(uri.toString(), 'https://xmpp.example.com/wt');
    });
  });

  group('WebTransport XML parser integration', () {
    test('prefers first matching WebTransport Link', () {
      const xml = '''<XRD>
  <Link rel='urn:xmpp:webtransport:0' href='https://primary.example.com/wt'/>
  <Link rel='urn:xmpp:webtransport:0' href='https://secondary.example.com/wt'/>
</XRD>''';
      final uri = parseHostMetaWebTransportXml(xml);
      expect(uri.toString(), 'https://primary.example.com/wt');
    });

    test('does not confuse WebSocket and WebTransport link relations', () {
      const xml = '''<XRD>
  <Link rel='urn:xmpp:alt-connections:websocket' href='wss://xmpp.example.com/ws'/>
</XRD>''';
      final wtUri = parseHostMetaWebTransportXml(xml);
      final wsUri = parseHostMetaXml(xml);
      expect(wtUri, isNull);
      expect(wsUri, isNotNull);
    });
  });
}
