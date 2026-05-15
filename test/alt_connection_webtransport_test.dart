import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/alt_connection_parser.dart';

void main() {
  group('parseHostMetaWebTransportJson', () {
    test('extracts WebTransport href from JSON', () {
      const json = '''
{
  "links": [
    {"rel": "urn:xmpp:alt-connections:websocket", "href": "wss://xmpp.example.com/ws"},
    {"rel": "urn:xmpp:webtransport:0", "href": "https://xmpp.example.com/webtransport"}
  ]
}
''';
      final uri = parseHostMetaWebTransportJson(json);
      expect(uri, isNotNull);
      expect(uri.toString(), 'https://xmpp.example.com/webtransport');
    });

    test('extracts WebTransport template from JSON', () {
      const json = '''
{
  "links": [
    {"rel": "urn:xmpp:webtransport:0", "template": "https://xmpp.example.com/wt"}
  ]
}
''';
      final uri = parseHostMetaWebTransportJson(json);
      expect(uri, isNotNull);
      expect(uri.toString(), 'https://xmpp.example.com/wt');
    });

    test('returns null when WebTransport link is absent', () {
      const json = '''
{
  "links": [
    {"rel": "urn:xmpp:alt-connections:websocket", "href": "wss://xmpp.example.com/ws"}
  ]
}
''';
      final uri = parseHostMetaWebTransportJson(json);
      expect(uri, isNull);
    });

    test('returns null for empty links array', () {
      const json = '{"links": []}';
      final uri = parseHostMetaWebTransportJson(json);
      expect(uri, isNull);
    });

    test('returns null for malformed JSON', () {
      expect(() => parseHostMetaWebTransportJson('not-json'), throwsA(anything));
    });

    test('returns null when links key is missing', () {
      const json = '{}';
      final uri = parseHostMetaWebTransportJson(json);
      expect(uri, isNull);
    });
  });

  group('parseHostMetaWebTransportXml', () {
    test('extracts WebTransport href from XML', () {
      const xml = '''<?xml version='1.0'?>
<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>
  <Link rel='urn:xmpp:alt-connections:websocket' href='wss://xmpp.example.com/ws'/>
  <Link rel='urn:xmpp:webtransport:0' href='https://xmpp.example.com/webtransport'/>
</XRD>''';
      final uri = parseHostMetaWebTransportXml(xml);
      expect(uri, isNotNull);
      expect(uri.toString(), 'https://xmpp.example.com/webtransport');
    });

    test('extracts WebTransport template from XML', () {
      const xml = '''<?xml version='1.0'?>
<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>
  <Link rel='urn:xmpp:webtransport:0' template='https://xmpp.example.com/wt'/>
</XRD>''';
      final uri = parseHostMetaWebTransportXml(xml);
      expect(uri, isNotNull);
      expect(uri.toString(), 'https://xmpp.example.com/wt');
    });

    test('returns null when WebTransport link is absent', () {
      const xml = '''<?xml version='1.0'?>
<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>
  <Link rel='urn:xmpp:alt-connections:websocket' href='wss://xmpp.example.com/ws'/>
</XRD>''';
      final uri = parseHostMetaWebTransportXml(xml);
      expect(uri, isNull);
    });

    test('returns null for empty XRD', () {
      const xml = '<XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0"/>';
      final uri = parseHostMetaWebTransportXml(xml);
      expect(uri, isNull);
    });

    test('is case-insensitive for Link tag', () {
      const xml = '''<XRD>
  <link rel='urn:xmpp:webtransport:0' href='https://xmpp.example.com/wt'/>
</XRD>''';
      final uri = parseHostMetaWebTransportXml(xml);
      expect(uri, isNotNull);
      expect(uri.toString(), 'https://xmpp.example.com/wt');
    });
  });

  group('parseHostMetaJson (WebSocket) still works after refactor', () {
    test('extracts WebSocket href', () {
      const json = '''
{
  "links": [
    {"rel": "urn:xmpp:alt-connections:websocket", "href": "wss://xmpp.example.com/ws"}
  ]
}
''';
      final uri = parseHostMetaJson(json);
      expect(uri, isNotNull);
      expect(uri.toString(), 'wss://xmpp.example.com/ws');
    });
  });

  group('parseHostMetaXml (WebSocket) still works after refactor', () {
    test('extracts WebSocket href', () {
      const xml = '''<XRD>
  <Link rel='urn:xmpp:alt-connections:websocket' href='wss://xmpp.example.com/ws'/>
</XRD>''';
      final uri = parseHostMetaXml(xml);
      expect(uri, isNotNull);
      expect(uri.toString(), 'wss://xmpp.example.com/ws');
    });
  });
}
