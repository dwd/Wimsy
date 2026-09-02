import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/jid_discovery.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

IqStanza _discoInfoResult({
  List<Map<String, String>> identities = const [],
  List<String> features = const [],
  String? description,
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
  if (description != null) {
    final form = XmppElement()..name = 'x';
    form.addAttribute(XmppAttribute('xmlns', 'jabber:x:data'));
    final field = XmppElement()..name = 'field';
    field.addAttribute(XmppAttribute('var', 'muc#roominfo_description'));
    field.addChild(
      XmppElement()
        ..name = 'value'
        ..textValue = description,
    );
    form.addChild(field);
    query.addChild(form);
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

IqStanza _searchForm({required bool dataForm}) {
  final iq = IqStanza('id-form', IqStanzaType.RESULT);
  final query = XmppElement()..name = 'query';
  query.addAttribute(XmppAttribute('xmlns', jidSearchNamespace));
  if (dataForm) {
    final form = XmppElement()..name = 'x';
    form.addAttribute(XmppAttribute('xmlns', 'jabber:x:data'));
    for (final name in const [
      'FORM_TYPE',
      'jid',
      'nick',
      'email',
      'unsupported',
    ]) {
      form.addChild(
        XmppElement()
          ..name = 'field'
          ..addAttribute(XmppAttribute('var', name)),
      );
    }
    query.addChild(form);
  } else {
    for (final name in const ['first', 'last', 'email']) {
      query.addChild(XmppElement()..name = name);
    }
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

  test(
    'uses room identity, description, then disco item name for bookmarks',
    () {
      final described = classifyJidFromDiscoInfo(
        _discoInfoResult(
          features: const ['http://jabber.org/protocol/muc'],
          description: 'A quiet place',
        ),
      );
      expect(described.description, 'A quiet place');
      expect(
        discoveredRoomName(described, discoItemsName: 'Quiet Room'),
        'A quiet place',
      );
      expect(
        discoveredRoomName(
          const JidDiscoveryResult(kind: DiscoveredJidKind.room),
          discoItemsName: 'Quiet Room',
        ),
        'Quiet Room',
      );
    },
  );

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

  test('parses JID and display name from XEP-0055 data-form results', () {
    final iq = IqStanza('id-data', IqStanzaType.RESULT);
    final query = XmppElement()..name = 'query';
    query.addAttribute(XmppAttribute('xmlns', jidSearchNamespace));
    final form = XmppElement()..name = 'x';
    form.addAttribute(XmppAttribute('xmlns', 'jabber:x:data'));
    final item = XmppElement()..name = 'item';
    for (final entry in const {
      'jid': 'ada@example.com',
      'fn': 'Ada Lovelace',
    }.entries) {
      final field = XmppElement()..name = 'field';
      field.addAttribute(XmppAttribute('var', entry.key));
      field.addChild(
        XmppElement()
          ..name = 'value'
          ..textValue = entry.value,
      );
      item.addChild(field);
    }
    form.addChild(item);
    query.addChild(form);
    iq.addChild(query);

    final results = parseJidSearchResults(iq);
    expect(results.single.jid, 'ada@example.com');
    expect(results.single.name, 'Ada Lovelace');
  });

  test('reads sensible legacy and data-form XEP-0055 search fields', () {
    expect(parseJidSearchFields(_searchForm(dataForm: false)), {
      'first',
      'last',
      'email',
    });
    expect(parseJidSearchFields(_searchForm(dataForm: true)), {
      'jid',
      'nick',
      'email',
    });
    expect(hasJidSearchDataForm(_searchForm(dataForm: false)), isFalse);
    expect(hasJidSearchDataForm(_searchForm(dataForm: true)), isTrue);
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

  test('suggestion matching checks both name and JID case-insensitively', () {
    const suggestion = JidSuggestion(
      jid: 'alice@example.com',
      kind: DiscoveredJidKind.person,
      name: 'Alice Example',
    );

    expect(jidSuggestionMatches(suggestion, 'ALICE@'), isTrue);
    expect(jidSuggestionMatches(suggestion, 'Alice Example'), isTrue);
    expect(jidSuggestionMatches(suggestion, 'missing'), isFalse);
  });

  test('local person completion prefers a search result', () {
    const suggestions = [
      JidSuggestion(
        jid: 'alice@directory.example',
        kind: DiscoveredJidKind.person,
        name: 'Alice',
      ),
    ];
    expect(
      completeLocalPersonJid('ali', 'me@example.com', suggestions),
      'alice@directory.example',
    );
  });

  test('local person completion falls back to the account domain', () {
    expect(
      completeLocalPersonJid('alice', 'me@example.com', const []),
      'alice@example.com',
    );
  });
}
