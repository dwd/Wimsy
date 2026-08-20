/// Tests for the generic private PEP publish helpers in lib/xmpp/pep_publish.dart.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/pep_publish.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  group('buildFormField', () {
    test('sets var, value, and no type by default', () {
      final field = buildFormField('pubsub#persist_items', 'true');
      expect(field.name, 'field');
      expect(field.getAttribute('var')?.value, 'pubsub#persist_items');
      expect(field.getAttribute('type'), isNull);
      expect(field.getChild('value')?.textValue, 'true');
    });

    test('sets type attribute when provided', () {
      final field = buildFormField('FORM_TYPE', 'some:uri', type: 'hidden');
      expect(field.getAttribute('type')?.value, 'hidden');
    });
  });

  group('buildPrivatePepPublishOptions', () {
    test('returns publish-options element with correct form fields', () {
      final opts = buildPrivatePepPublishOptions();
      expect(opts.name, 'publish-options');
      final x = opts.getChild('x');
      expect(x, isNotNull);
      expect(x!.getAttribute('xmlns')?.value, 'jabber:x:data');
      expect(x.getAttribute('type')?.value, 'submit');

      final fields = x.children.where((c) => c.name == 'field').toList();
      expect(fields.length, 5);

      final formType =
          fields.firstWhere((f) => f.getAttribute('var')?.value == 'FORM_TYPE');
      expect(formType.getAttribute('type')?.value, 'hidden');
      expect(formType.getChild('value')?.textValue,
          'http://jabber.org/protocol/pubsub#publish-options');

      _expectField(fields, 'pubsub#persist_items', 'true');
      _expectField(fields, 'pubsub#access_model', 'whitelist');
      _expectField(fields, 'pubsub#send_last_published_item', 'never');
      _expectField(fields, 'pubsub#max_items', 'max');
    });
  });

  group('buildPrivatePepConfigureIq', () {
    test('builds a SET IQ to pubsub#owner namespace', () {
      final iq = buildPrivatePepConfigureIq(
        node: 'urn:example:node',
        selfBareJid: 'user@example.com',
      );
      expect(iq.type, IqStanzaType.SET);
      expect(iq.toJid?.userAtDomain, 'user@example.com');
      final pubsub = iq.getChild('pubsub');
      expect(pubsub?.getAttribute('xmlns')?.value,
          'http://jabber.org/protocol/pubsub#owner');
    });

    test('targets the given node name', () {
      final iq = buildPrivatePepConfigureIq(
        node: 'urn:example:mynode',
        selfBareJid: 'user@example.com',
      );
      final configure = iq.getChild('pubsub')?.getChild('configure');
      expect(configure?.getAttribute('node')?.value, 'urn:example:mynode');
    });

    test('configure form has FORM_TYPE set to pubsub node_config', () {
      final iq = buildPrivatePepConfigureIq(
        node: 'urn:example:node',
        selfBareJid: 'user@example.com',
      );
      final configure = iq.getChild('pubsub')?.getChild('configure');
      final x = configure?.getChild('x');
      expect(x?.getAttribute('type')?.value, 'submit');

      final fields = x?.children.where((c) => c.name == 'field').toList() ?? [];
      final formType = fields
          .firstWhere((f) => f.getAttribute('var')?.value == 'FORM_TYPE');
      expect(formType.getChild('value')?.textValue,
          'http://jabber.org/protocol/pubsub#node_config');
    });

    test('configure form includes all required node config fields', () {
      final iq = buildPrivatePepConfigureIq(
        node: 'urn:example:node',
        selfBareJid: 'user@example.com',
      );
      final x =
          iq.getChild('pubsub')?.getChild('configure')?.getChild('x');
      final fields = x?.children.where((c) => c.name == 'field').toList() ?? [];

      _expectField(fields, 'pubsub#persist_items', 'true');
      _expectField(fields, 'pubsub#access_model', 'whitelist');
      _expectField(fields, 'pubsub#send_last_published_item', 'never');
      _expectField(fields, 'pubsub#max_items', 'max');
    });
  });

  group('buildPrivatePepPublishIq', () {
    test('builds a SET IQ addressed to selfBareJid', () {
      final payload = XmppElement()..name = 'data';
      final iq = buildPrivatePepPublishIq(
        node: 'urn:example:node',
        itemId: 'item1',
        payload: payload,
        selfBareJid: 'user@example.com',
      );
      expect(iq.type, IqStanzaType.SET);
      expect(iq.toJid?.userAtDomain, 'user@example.com');
    });

    test('publishes to the given node', () {
      final payload = XmppElement()..name = 'data';
      final iq = buildPrivatePepPublishIq(
        node: 'urn:example:mynode',
        itemId: 'item1',
        payload: payload,
        selfBareJid: 'user@example.com',
      );
      final pubsub = iq.getChild('pubsub');
      expect(pubsub?.getAttribute('xmlns')?.value,
          'http://jabber.org/protocol/pubsub');
      final publish = pubsub?.getChild('publish');
      expect(publish?.getAttribute('node')?.value, 'urn:example:mynode');
    });

    test('item id is set to itemId', () {
      final payload = XmppElement()..name = 'data';
      final iq = buildPrivatePepPublishIq(
        node: 'urn:example:node',
        itemId: 'my-item-id',
        payload: payload,
        selfBareJid: 'user@example.com',
      );
      final item =
          iq.getChild('pubsub')?.getChild('publish')?.getChild('item');
      expect(item?.getAttribute('id')?.value, 'my-item-id');
    });

    test('payload is placed inside the item', () {
      final payload = XmppElement()..name = 'custom-payload';
      payload.addAttribute(XmppAttribute('xmlns', 'urn:example:ns'));
      final iq = buildPrivatePepPublishIq(
        node: 'urn:example:node',
        itemId: 'item1',
        payload: payload,
        selfBareJid: 'user@example.com',
      );
      final item =
          iq.getChild('pubsub')?.getChild('publish')?.getChild('item');
      final child = item?.getChild('custom-payload');
      expect(child, isNotNull);
      expect(child?.getAttribute('xmlns')?.value, 'urn:example:ns');
    });

    test('includes standard private PEP publish-options', () {
      final payload = XmppElement()..name = 'data';
      final iq = buildPrivatePepPublishIq(
        node: 'urn:example:node',
        itemId: 'item1',
        payload: payload,
        selfBareJid: 'user@example.com',
      );
      final publishOptions = iq.getChild('pubsub')?.getChild('publish-options');
      expect(publishOptions, isNotNull);
      final x = publishOptions?.getChild('x');
      final fields = x?.children.where((c) => c.name == 'field').toList() ?? [];
      _expectField(fields, 'pubsub#access_model', 'whitelist');
      _expectField(fields, 'pubsub#persist_items', 'true');
    });

    test('each call produces a different IQ id', () {
      final payload = XmppElement()..name = 'data';
      final iq1 = buildPrivatePepPublishIq(
        node: 'urn:example:node',
        itemId: 'item1',
        payload: payload,
        selfBareJid: 'user@example.com',
      );
      final iq2 = buildPrivatePepPublishIq(
        node: 'urn:example:node',
        itemId: 'item1',
        payload: payload,
        selfBareJid: 'user@example.com',
      );
      expect(iq1.id, isNot(equals(iq2.id)));
    });
  });

  // -----------------------------------------------------------------------
  // MDS-specific wrappers
  // -----------------------------------------------------------------------

  group('buildMdsPublishIq', () {
    test('builds a SET IQ addressed to selfBareJid', () {
      final iq = buildMdsPublishIq(
        chatJid: 'room@conference.example',
        stanzaId: 'stanza-abc',
        byValue: 'room@conference.example',
        selfBareJid: 'user@example.com',
      );
      expect(iq.type, IqStanzaType.SET);
      expect(iq.toJid?.userAtDomain, 'user@example.com');
    });

    test('publishes to urn:xmpp:mds:displayed:0 node', () {
      final iq = buildMdsPublishIq(
        chatJid: 'alice@example.com',
        stanzaId: 'sid1',
        byValue: 'user@example.com',
        selfBareJid: 'user@example.com',
      );
      final publish = iq.getChild('pubsub')?.getChild('publish');
      expect(publish?.getAttribute('node')?.value, 'urn:xmpp:mds:displayed:0');
    });

    test('item id is set to chatJid', () {
      final iq = buildMdsPublishIq(
        chatJid: 'alice@example.com',
        stanzaId: 'sid1',
        byValue: 'user@example.com',
        selfBareJid: 'user@example.com',
      );
      final item =
          iq.getChild('pubsub')?.getChild('publish')?.getChild('item');
      expect(item?.getAttribute('id')?.value, 'alice@example.com');
    });

    test('displayed contains stanza-id with correct id and by', () {
      final iq = buildMdsPublishIq(
        chatJid: 'room@conference.example',
        stanzaId: 'stanza-xyz',
        byValue: 'room@conference.example',
        selfBareJid: 'user@example.com',
      );
      final displayed = iq
          .getChild('pubsub')
          ?.getChild('publish')
          ?.getChild('item')
          ?.getChild('displayed');
      expect(displayed?.getAttribute('xmlns')?.value,
          'urn:xmpp:mds:displayed:0');
      final stanzaId = displayed?.getChild('stanza-id');
      expect(stanzaId?.getAttribute('xmlns')?.value, 'urn:xmpp:sid:0');
      expect(stanzaId?.getAttribute('id')?.value, 'stanza-xyz');
      expect(
          stanzaId?.getAttribute('by')?.value, 'room@conference.example');
    });

    test('omits by attribute when byValue is empty', () {
      final iq = buildMdsPublishIq(
        chatJid: 'alice@example.com',
        stanzaId: 'sid2',
        byValue: '',
        selfBareJid: 'user@example.com',
      );
      final stanzaId = iq
          .getChild('pubsub')
          ?.getChild('publish')
          ?.getChild('item')
          ?.getChild('displayed')
          ?.getChild('stanza-id');
      expect(stanzaId?.getAttribute('by'), isNull);
    });

    test('includes publish-options', () {
      final iq = buildMdsPublishIq(
        chatJid: 'alice@example.com',
        stanzaId: 'sid3',
        byValue: 'user@example.com',
        selfBareJid: 'user@example.com',
      );
      final publishOptions = iq.getChild('pubsub')?.getChild('publish-options');
      expect(publishOptions, isNotNull);
    });
  });

  group('buildMdsNodeConfigureIq', () {
    test('builds a SET IQ to pubsub#owner namespace for MDS node', () {
      final iq = buildMdsNodeConfigureIq(selfBareJid: 'user@example.com');
      expect(iq.type, IqStanzaType.SET);
      expect(iq.toJid?.userAtDomain, 'user@example.com');
      final pubsub = iq.getChild('pubsub');
      expect(pubsub?.getAttribute('xmlns')?.value,
          'http://jabber.org/protocol/pubsub#owner');
    });

    test('targets the urn:xmpp:mds:displayed:0 node', () {
      final iq = buildMdsNodeConfigureIq(selfBareJid: 'user@example.com');
      final configure = iq.getChild('pubsub')?.getChild('configure');
      expect(
          configure?.getAttribute('node')?.value, 'urn:xmpp:mds:displayed:0');
    });
  });
}

void _expectField(
    List<XmppElement> fields, String varName, String expectedValue) {
  final field = fields.firstWhere(
    (f) => f.getAttribute('var')?.value == varName,
    orElse: () => throw TestFailure('Field $varName not found'),
  );
  expect(
    field.getChild('value')?.textValue,
    expectedValue,
    reason: 'Field $varName should have value $expectedValue',
  );
}
