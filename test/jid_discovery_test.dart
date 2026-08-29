import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/jid_discovery.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

IqStanza _discoInfoResult({
  List<Map<String, String>> identities = const [],
  List<String> features = const [],
}) {
  final iq = IqStanza('id-1', IqStanzaType.RESULT);
  final query = XmppElement()..name = 'query';
  query.addAttribute(
    XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'),
  );
  for (final identity in identities) {
    final child = XmppElement()..name = 'identity';
    for (final entry in identity.entries) {
      child.addAttribute(XmppAttribute(entry.key, entry.value));
    }
    query.addChild(child);
  }
  for (final feature in features) {
    final child = XmppElement()..name = 'feature';
    child.addAttribute(XmppAttribute('var', feature));
    query.addChild(child);
  }
  iq.addChild(query);
  return iq;
}

IqStanza _searchResult(List<Map<String, String>> entries) {
  final iq = IqStanza('id-1', IqStanzaType.RESULT);
  final query = XmppElement()..name = 'query';
  query.addAttribute(XmppAttribute('xmlns', jidSearchNamespace));
  for (final entry in entries) {
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('jid', entry['jid'] ?? ''));
    for (final field in const ['nick', 'first', 'last']) {
      final value = entry[field];
      if (value != null) {
        item.addChild(
          XmppElement()
            ..name = field
            ..textValue = value,
        );
      }
    }
    query.addChild(item);
  }
  iq.addChild(query);
  return iq;
}

void main() {
  test('classifies conference identity as room', () {
    final result = classifyJidFromDiscoInfo(
      _discoInfoResult(
        identities: const [
          {'category': 'conference', 'type': 'text'},
        ],
      ),
    );
    expect(result.kind, DiscoveredJidKind.room);
  });

  test('classifies account identity as person', () {
    final result = classifyJidFromDiscoInfo(
      _discoInfoResult(
        identities: const [
          {'category': 'account', 'type': 'registered'},
        ],
      ),
    );
    expect(result.kind, DiscoveredJidKind.person);
  });

  test('classifies client identity as person', () {
    final result = classifyJidFromDiscoInfo(
      _discoInfoResult(
        identities: const [
          {'category': 'client', 'type': 'pc'},
        ],
      ),
    );
    expect(result.kind, DiscoveredJidKind.person);
  });

  test('classifies im server identity as person', () {
    final result = classifyJidFromDiscoInfo(
      _discoInfoResult(
        identities: const [
          {'category': 'server', 'type': 'im'},
        ],
      ),
    );
    expect(result.kind, DiscoveredJidKind.person);
  });

  test('classifies muc feature as room without identity', () {
    final result = classifyJidFromDiscoInfo(
      _discoInfoResult(features: const ['http://jabber.org/protocol/muc']),
    );
    expect(result.kind, DiscoveredJidKind.room);
  });

  test('returns unknown for empty disco info', () {
    final result = classifyJidFromDiscoInfo(_discoInfoResult());
    expect(result.kind, DiscoveredJidKind.unknown);
  });

  test('returns unknown for non-result stanza', () {
    final iq = IqStanza('id-1', IqStanzaType.GET);
    final result = classifyJidFromDiscoInfo(iq);
    expect(result.kind, DiscoveredJidKind.unknown);
  });

  test('exposes identity name when present', () {
    final result = classifyJidFromDiscoInfo(
      _discoInfoResult(
        identities: const [
          {'category': 'client', 'type': 'pc', 'name': 'Alice Laptop'},
        ],
      ),
    );
    expect(result.identityName, 'Alice Laptop');
  });

  test('parses and names legacy XEP-0055 results', () {
    final results = parseJidSearchResults(
      _searchResult(const [
        {'jid': 'alice@example.com', 'first': 'Alice', 'last': 'Example'},
      ]),
    );

    expect(results, hasLength(1));
    expect(results.single.jid, 'alice@example.com');
    expect(results.single.name, 'Alice Example');
    expect(results.single.kind, DiscoveredJidKind.person);
  });

  test('ignores duplicate and malformed XEP-0055 results', () {
    final results = parseJidSearchResults(
      _searchResult(const [
        {'jid': 'alice@example.com'},
        {'jid': 'ALICE@example.com'},
        {'jid': ''},
      ]),
    );

    expect(results.map((result) => result.jid), ['alice@example.com']);
  });
}
