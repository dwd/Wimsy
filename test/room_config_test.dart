import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/xmpp/room_config.dart';

IqStanza _buildOwnerConfigResult(String id, List<XmppElement> fields) {
  final stanza = IqStanza(id, IqStanzaType.RESULT);
  final query = XmppElement()..name = 'query';
  query.addAttribute(XmppAttribute('xmlns', mucOwnerXmlns));
  final form = XmppElement()..name = 'x';
  form.addAttribute(XmppAttribute('xmlns', dataFormXmlns));
  for (final field in fields) {
    form.addChild(field);
  }
  query.addChild(form);
  stanza.addChild(query);
  return stanza;
}

XmppElement _field(
  String varName, {
  String? label,
  String? type,
  List<String> values = const [],
  List<String> options = const [],
}) {
  final field = XmppElement()..name = 'field';
  field.addAttribute(XmppAttribute('var', varName));
  if (label != null) field.addAttribute(XmppAttribute('label', label));
  if (type != null) field.addAttribute(XmppAttribute('type', type));
  for (final option in options) {
    final optionEl = XmppElement()..name = 'option';
    final optionValue = XmppElement()
      ..name = 'value'
      ..textValue = option;
    optionEl.addChild(optionValue);
    field.addChild(optionEl);
  }
  for (final value in values) {
    final v = XmppElement()
      ..name = 'value'
      ..textValue = value;
    field.addChild(v);
  }
  return field;
}

void main() {
  group('parseRoomConfig', () {
    test('parses fields and omits FORM_TYPE', () {
      final result = _buildOwnerConfigResult('1', [
        _field(
          'FORM_TYPE',
          type: 'hidden',
          values: ['http://jabber.org/protocol/muc#roomconfig'],
        ),
        _field('muc#roomconfig_roomname', label: 'Room name', values: ['Lounge']),
        _field('muc#roomconfig_moderatedroom', type: 'boolean', values: ['0']),
      ]);
      final fields = parseRoomConfig(result);
      expect(fields, hasLength(2));
      expect(fields[0].varName, 'muc#roomconfig_roomname');
      expect(fields[0].label, 'Room name');
      expect(fields[0].values, ['Lounge']);
      expect(fields[1].varName, 'muc#roomconfig_moderatedroom');
      expect(fields[1].type, 'boolean');
      expect(fields[1].values, ['0']);
    });

    test('returns empty when no configuration form is present', () {
      final stanza = IqStanza('1', IqStanzaType.RESULT);
      final query = XmppElement()..name = 'query';
      query.addAttribute(XmppAttribute('xmlns', mucOwnerXmlns));
      stanza.addChild(query);
      expect(parseRoomConfig(stanza), isEmpty);
    });

    test('returns empty for non-result or wrong namespace', () {
      final error = IqStanza('1', IqStanzaType.ERROR);
      expect(parseRoomConfig(error), isEmpty);
      expect(parseRoomConfig(null), isEmpty);
    });

    test('parses the declared options of a list-single field', () {
      final result = _buildOwnerConfigResult('1', [
        _field(
          'muc#roomconfig_whois',
          type: 'list-single',
          values: ['moderators'],
          options: ['anyone', 'moderators'],
        ),
      ]);
      final fields = parseRoomConfig(result);
      expect(fields, hasLength(1));
      expect(fields[0].options.map((o) => o.value), ['anyone', 'moderators']);
    });
  });

  group('parseRoomConfigFormType', () {
    test('extracts the FORM_TYPE value', () {
      final result = _buildOwnerConfigResult('1', [
        _field(
          'FORM_TYPE',
          type: 'hidden',
          values: ['http://jabber.org/protocol/muc#roomconfig'],
        ),
        _field('muc#roomconfig_roomname', values: ['Lounge']),
      ]);
      expect(
        parseRoomConfigFormType(result),
        'http://jabber.org/protocol/muc#roomconfig',
      );
    });

    test('returns null when there is no FORM_TYPE field', () {
      final result = _buildOwnerConfigResult('1', [
        _field('muc#roomconfig_roomname', values: ['Lounge']),
      ]);
      expect(parseRoomConfigFormType(result), isNull);
    });

    test('returns null for non-result or wrong namespace', () {
      final error = IqStanza('1', IqStanzaType.ERROR);
      expect(parseRoomConfigFormType(error), isNull);
      expect(parseRoomConfigFormType(null), isNull);
    });
  });

  group('buildRoomConfigSubmitForm', () {
    test('builds a submit form with FORM_TYPE and fields', () {
      final form = buildRoomConfigSubmitForm(
        'http://jabber.org/protocol/muc#roomconfig',
        const [
          RoomConfigField(
            varName: 'muc#roomconfig_moderatedroom',
            type: 'boolean',
            values: ['1'],
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
        'http://jabber.org/protocol/muc#roomconfig',
      );
      expect(fields[1].getAttribute('var')?.value, 'muc#roomconfig_moderatedroom');
      expect(fields[1].getChild('value')?.textValue, '1');
    });

    test('omits FORM_TYPE field when formType is null', () {
      final form = buildRoomConfigSubmitForm(null, const []);
      expect(form.children.where((c) => c.name == 'field'), isEmpty);
    });

    test('omits fixed fields, which are informational-only (XEP-0004 §3.3)', () {
      final form = buildRoomConfigSubmitForm('urn:example', const [
        RoomConfigField(varName: 'instructions-header', type: 'fixed', values: ['Section']),
        RoomConfigField(varName: 'muc#roomconfig_roomname', type: 'text-single', values: ['hi']),
      ]);
      final fields = form.children
          .where((c) => c.name == 'field')
          .map((c) => c.getAttribute('var')?.value)
          .toList();
      expect(fields, ['FORM_TYPE', 'muc#roomconfig_roomname']);
    });
  });

  group('buildRoomConfigCancelForm', () {
    test('builds a cancel form with no fields', () {
      final form = buildRoomConfigCancelForm();
      expect(form.name, 'x');
      expect(form.getAttribute('xmlns')?.value, dataFormXmlns);
      expect(form.getAttribute('type')?.value, 'cancel');
      expect(form.children, isEmpty);
    });
  });

  group('roomConfigIqErrorCondition', () {
    test('returns null on success', () {
      final result = IqStanza('1', IqStanzaType.RESULT);
      expect(roomConfigIqErrorCondition(result), isNull);
    });

    test('returns timeout for null result', () {
      expect(roomConfigIqErrorCondition(null), 'timeout');
    });

    test('extracts the error condition element name', () {
      final stanza = IqStanza('1', IqStanzaType.ERROR);
      final error = XmppElement()..name = 'error';
      error.addChild(XmppElement()..name = 'forbidden');
      stanza.addChild(error);
      expect(roomConfigIqErrorCondition(stanza), 'forbidden');
    });
  });

  group('roomConfigIqErrorText', () {
    test('extracts the error text when present', () {
      final stanza = IqStanza('1', IqStanzaType.ERROR);
      final error = XmppElement()..name = 'error';
      error.addChild(XmppElement()..name = 'forbidden');
      final text = XmppElement()
        ..name = 'text'
        ..textValue = 'Only owners may configure this room';
      error.addChild(text);
      stanza.addChild(error);
      expect(roomConfigIqErrorText(stanza), 'Only owners may configure this room');
    });

    test('returns null when there is no text element', () {
      final stanza = IqStanza('1', IqStanzaType.ERROR);
      final error = XmppElement()..name = 'error';
      error.addChild(XmppElement()..name = 'forbidden');
      stanza.addChild(error);
      expect(roomConfigIqErrorText(stanza), isNull);
    });

    test('returns null on success or null result', () {
      expect(roomConfigIqErrorText(IqStanza('1', IqStanzaType.RESULT)), isNull);
      expect(roomConfigIqErrorText(null), isNull);
    });
  });
}
