import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/pep/pep_explorer.dart';

IqStanza _buildDiscoItemsResult(String id, List<Map<String, String>> items) {
  final stanza = IqStanza(id, IqStanzaType.RESULT);
  final query = XmppElement()..name = 'query';
  query.addAttribute(XmppAttribute('xmlns', discoItemsXmlns));
  for (final item in items) {
    final el = XmppElement()..name = 'item';
    item.forEach((key, value) => el.addAttribute(XmppAttribute(key, value)));
    query.addChild(el);
  }
  stanza.addChild(query);
  return stanza;
}

IqStanza _buildConfigureResult(String id, String node, List<XmppElement> fields) {
  final stanza = IqStanza(id, IqStanzaType.RESULT);
  final pubsub = XmppElement()..name = 'pubsub';
  pubsub.addAttribute(XmppAttribute('xmlns', pepPubsubOwnerXmlns));
  final configure = XmppElement()..name = 'configure';
  configure.addAttribute(XmppAttribute('node', node));
  final form = XmppElement()..name = 'x';
  form.addAttribute(XmppAttribute('xmlns', dataFormXmlns));
  for (final field in fields) {
    form.addChild(field);
  }
  configure.addChild(form);
  pubsub.addChild(configure);
  stanza.addChild(pubsub);
  return stanza;
}

XmppElement _field(String varName, {String? label, String? type, List<String> values = const []}) {
  final field = XmppElement()..name = 'field';
  field.addAttribute(XmppAttribute('var', varName));
  if (label != null) field.addAttribute(XmppAttribute('label', label));
  if (type != null) field.addAttribute(XmppAttribute('type', type));
  for (final value in values) {
    final v = XmppElement()
      ..name = 'value'
      ..textValue = value;
    field.addChild(v);
  }
  return field;
}

IqStanza _buildItemsResult(String id, String node, List<MapEntry<String, String>> items) {
  final stanza = IqStanza(id, IqStanzaType.RESULT);
  final pubsub = XmppElement()..name = 'pubsub';
  pubsub.addAttribute(XmppAttribute('xmlns', pepPubsubXmlns));
  final itemsEl = XmppElement()..name = 'items';
  itemsEl.addAttribute(XmppAttribute('node', node));
  for (final entry in items) {
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', entry.key));
    final payload = XmppElement()..name = 'payload';
    payload.addAttribute(XmppAttribute('xmlns', 'urn:example:test'));
    payload.textValue = entry.value;
    item.addChild(payload);
    itemsEl.addChild(item);
  }
  pubsub.addChild(itemsEl);
  stanza.addChild(pubsub);
  return stanza;
}

void main() {
  group('parsePepNodeSummaries', () {
    test('parses nodes with node and name attributes', () {
      final result = _buildDiscoItemsResult('1', [
        {'jid': 'alice@example.com', 'node': 'urn:xmpp:avatar:metadata', 'name': 'Avatar'},
        {'jid': 'alice@example.com', 'node': 'urn:xmpp:bookmarks:1'},
      ]);
      final nodes = parsePepNodeSummaries(result);
      expect(nodes, hasLength(2));
      expect(nodes[0].node, 'urn:xmpp:avatar:metadata');
      expect(nodes[0].name, 'Avatar');
      expect(nodes[1].node, 'urn:xmpp:bookmarks:1');
      expect(nodes[1].name, isNull);
    });

    test('skips items without a node attribute', () {
      final result = _buildDiscoItemsResult('1', [
        {'jid': 'muc.example.com'},
      ]);
      expect(parsePepNodeSummaries(result), isEmpty);
    });

    test('returns empty for non-result or wrong namespace', () {
      final error = IqStanza('1', IqStanzaType.ERROR);
      expect(parsePepNodeSummaries(error), isEmpty);
      expect(parsePepNodeSummaries(null), isEmpty);
    });
  });

  group('parsePepNodeConfig', () {
    test('parses fields and omits FORM_TYPE', () {
      final result = _buildConfigureResult('1', 'urn:xmpp:bookmarks:1', [
        _field('FORM_TYPE', type: 'hidden', values: ['http://jabber.org/protocol/pubsub#node_config']),
        _field('pubsub#access_model', label: 'Access model', values: ['whitelist']),
        _field('pubsub#max_items', values: ['max']),
      ]);
      final fields = parsePepNodeConfig(result);
      expect(fields, hasLength(2));
      expect(fields[0].varName, 'pubsub#access_model');
      expect(fields[0].label, 'Access model');
      expect(fields[0].values, ['whitelist']);
      expect(fields[1].varName, 'pubsub#max_items');
      expect(fields[1].values, ['max']);
    });

    test('returns empty when no configuration form is present', () {
      final stanza = IqStanza('1', IqStanzaType.RESULT);
      final pubsub = XmppElement()..name = 'pubsub';
      pubsub.addAttribute(XmppAttribute('xmlns', pepPubsubOwnerXmlns));
      stanza.addChild(pubsub);
      expect(parsePepNodeConfig(stanza), isEmpty);
    });
  });

  group('parsePepNodeItems', () {
    test('parses items with id and payload xml', () {
      final result = _buildItemsResult('1', 'urn:xmpp:bookmarks:1', [
        const MapEntry('item1', 'hello'),
        const MapEntry('item2', 'world'),
      ]);
      final items = parsePepNodeItems(result);
      expect(items, hasLength(2));
      expect(items[0].id, 'item1');
      expect(items[0].xml, contains('hello'));
      expect(items[1].id, 'item2');
      expect(items[1].xml, contains('world'));
    });

    test('returns empty when no items element is present', () {
      final stanza = IqStanza('1', IqStanzaType.RESULT);
      final pubsub = XmppElement()..name = 'pubsub';
      pubsub.addAttribute(XmppAttribute('xmlns', pepPubsubXmlns));
      stanza.addChild(pubsub);
      expect(parsePepNodeItems(stanza), isEmpty);
    });
  });

  group('parsePepNodeConfigFormType', () {
    test('extracts the FORM_TYPE value', () {
      final result = _buildConfigureResult('1', 'urn:xmpp:bookmarks:1', [
        _field('FORM_TYPE', type: 'hidden', values: ['http://jabber.org/protocol/pubsub#node_config']),
        _field('pubsub#access_model', values: ['whitelist']),
      ]);
      expect(
        parsePepNodeConfigFormType(result),
        'http://jabber.org/protocol/pubsub#node_config',
      );
    });

    test('returns null when there is no FORM_TYPE field', () {
      final result = _buildConfigureResult('1', 'urn:xmpp:bookmarks:1', [
        _field('pubsub#access_model', values: ['whitelist']),
      ]);
      expect(parsePepNodeConfigFormType(result), isNull);
    });

    test('returns null for non-result or wrong namespace', () {
      final error = IqStanza('1', IqStanzaType.ERROR);
      expect(parsePepNodeConfigFormType(error), isNull);
      expect(parsePepNodeConfigFormType(null), isNull);
    });
  });

  group('buildPepNodeConfigSubmitForm', () {
    test('builds a submit form with FORM_TYPE and fields', () {
      final form = buildPepNodeConfigSubmitForm(
        'http://jabber.org/protocol/pubsub#node_config',
        const [
          PepNodeConfigField(
            varName: 'pubsub#access_model',
            type: 'list-single',
            values: ['open'],
          ),
        ],
      );
      expect(form.name, 'x');
      expect(form.getAttribute('xmlns')?.value, dataFormXmlns);
      expect(form.getAttribute('type')?.value, 'submit');
      final fields = form.children.where((c) => c.name == 'field').toList();
      expect(fields, hasLength(2));
      expect(fields[0].getAttribute('var')?.value, 'FORM_TYPE');
      expect(
        fields[0].getChild('value')?.textValue,
        'http://jabber.org/protocol/pubsub#node_config',
      );
      expect(fields[1].getAttribute('var')?.value, 'pubsub#access_model');
      expect(fields[1].getChild('value')?.textValue, 'open');
    });

    test('omits FORM_TYPE field when formType is null', () {
      final form = buildPepNodeConfigSubmitForm(null, const []);
      expect(form.children.where((c) => c.name == 'field'), isEmpty);
    });
  });

  group('pepIqErrorCondition', () {
    test('returns null on success', () {
      final result = IqStanza('1', IqStanzaType.RESULT);
      expect(pepIqErrorCondition(result), isNull);
    });

    test('returns timeout for null result', () {
      expect(pepIqErrorCondition(null), 'timeout');
    });

    test('extracts the error condition element name', () {
      final stanza = IqStanza('1', IqStanzaType.ERROR);
      final error = XmppElement()..name = 'error';
      error.addChild(XmppElement()..name = 'item-not-found');
      stanza.addChild(error);
      expect(pepIqErrorCondition(stanza), 'item-not-found');
    });
  });
}
