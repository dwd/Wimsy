import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/mds_publish.dart';
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

  group('buildMdsPublishOptions', () {
    test('returns publish-options element with correct form fields', () {
      final opts = buildMdsPublishOptions();
      expect(opts.name, 'publish-options');
      final x = opts.getChild('x');
      expect(x, isNotNull);
      expect(x!.getAttribute('xmlns')?.value, 'jabber:x:data');
      expect(x.getAttribute('type')?.value, 'submit');

      final fields = x.children.where((c) => c.name == 'field').toList();
      expect(fields.length, 5);

      final formType = fields.firstWhere(
          (f) => f.getAttribute('var')?.value == 'FORM_TYPE');
      expect(formType.getAttribute('type')?.value, 'hidden');
      expect(formType.getChild('value')?.textValue,
          'http://jabber.org/protocol/pubsub#publish-options');

      _expectField(fields, 'pubsub#persist_items', 'true');
      _expectField(fields, 'pubsub#access_model', 'whitelist');
      _expectField(fields, 'pubsub#send_last_published_item', 'never');
      _expectField(fields, 'pubsub#max_items', 'max');
    });
  });

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
      final pubsub = iq.getChild('pubsub');
      expect(pubsub?.getAttribute('xmlns')?.value,
          'http://jabber.org/protocol/pubsub');
      final publish = pubsub?.getChild('publish');
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
      expect(stanzaId?.getAttribute('by')?.value, 'room@conference.example');
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
    test('builds a SET IQ to pubsub#owner namespace', () {
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
      expect(configure?.getAttribute('node')?.value, 'urn:xmpp:mds:displayed:0');
    });

    test('configure form has FORM_TYPE set to pubsub node_config', () {
      final iq = buildMdsNodeConfigureIq(selfBareJid: 'user@example.com');
      final configure = iq.getChild('pubsub')?.getChild('configure');
      final x = configure?.getChild('x');
      expect(x?.getAttribute('type')?.value, 'submit');

      final fields = x?.children.where((c) => c.name == 'field').toList() ?? [];
      final formType = fields.firstWhere(
          (f) => f.getAttribute('var')?.value == 'FORM_TYPE');
      expect(formType.getChild('value')?.textValue,
          'http://jabber.org/protocol/pubsub#node_config');
    });

    test('configure form includes all required node config fields', () {
      final iq = buildMdsNodeConfigureIq(selfBareJid: 'user@example.com');
      final x = iq
          .getChild('pubsub')
          ?.getChild('configure')
          ?.getChild('x');
      final fields = x?.children.where((c) => c.name == 'field').toList() ?? [];

      _expectField(fields, 'pubsub#persist_items', 'true');
      _expectField(fields, 'pubsub#access_model', 'whitelist');
      _expectField(fields, 'pubsub#send_last_published_item', 'never');
      _expectField(fields, 'pubsub#max_items', 'max');
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
