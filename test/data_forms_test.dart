import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/xmpp/data_forms.dart';

XmppElement _field({
  String? varName,
  String? label,
  String? type,
  List<String> values = const [],
  List<String> options = const [],
  bool required = false,
}) {
  final field = XmppElement()..name = 'field';
  if (varName != null) field.addAttribute(XmppAttribute('var', varName));
  if (label != null) field.addAttribute(XmppAttribute('label', label));
  if (type != null) field.addAttribute(XmppAttribute('type', type));
  if (required) field.addChild(XmppElement()..name = 'required');
  for (final option in options) {
    final optionEl = XmppElement()..name = 'option';
    optionEl.addChild(XmppElement()..name = 'value'..textValue = option);
    field.addChild(optionEl);
  }
  for (final value in values) {
    field.addChild(XmppElement()..name = 'value'..textValue = value);
  }
  return field;
}

XmppElement _form(List<XmppElement> fields, {String? title, List<String> instructions = const []}) {
  final x = XmppElement()..name = 'x';
  x.addAttribute(XmppAttribute('xmlns', dataFormXmlns));
  x.addAttribute(XmppAttribute('type', 'form'));
  if (title != null) {
    x.addChild(XmppElement()..name = 'title'..textValue = title);
  }
  for (final instruction in instructions) {
    x.addChild(XmppElement()..name = 'instructions'..textValue = instruction);
  }
  for (final field in fields) {
    x.addChild(field);
  }
  return x;
}

void main() {
  group('dataFormFieldTypeFromWire / dataFormFieldTypeToWire', () {
    test('round-trips all known wire values', () {
      const wireValues = [
        'boolean',
        'fixed',
        'hidden',
        'jid-multi',
        'jid-single',
        'list-multi',
        'list-single',
        'text-multi',
        'text-private',
        'text-single',
      ];
      for (final wire in wireValues) {
        final type = dataFormFieldTypeFromWire(wire);
        expect(type, isNotNull);
        expect(dataFormFieldTypeToWire(type!), wire);
      }
    });

    test('returns null for unrecognized or absent wire values', () {
      expect(dataFormFieldTypeFromWire('something-else'), isNull);
      expect(dataFormFieldTypeFromWire(null), isNull);
    });
  });

  group('DataForm.fromElement', () {
    test('parses title, instructions, FORM_TYPE and fields', () {
      final x = _form(
        [
          _field(varName: 'FORM_TYPE', type: 'hidden', values: ['urn:example:config']),
          _field(varName: 'pubsub#title', label: 'Title', type: 'text-single', values: ['hi']),
        ],
        title: 'Node configuration',
        instructions: ['Please configure the node.'],
      );
      final form = DataForm.fromElement(x);
      expect(form, isNotNull);
      expect(form!.formType, 'urn:example:config');
      expect(form.title, 'Node configuration');
      expect(form.instructions, ['Please configure the node.']);
      expect(form.fields, hasLength(1));
      expect(form.fields.single.varName, 'pubsub#title');
      expect(form.fields.single.type, DataFormFieldType.textSingle);
      expect(form.fields.single.values, ['hi']);
    });

    test('parses list-single options and required flag', () {
      final x = _form([
        _field(
          varName: 'pubsub#access_model',
          type: 'list-single',
          values: ['presence'],
          options: ['open', 'presence', 'whitelist'],
          required: true,
        ),
      ]);
      final form = DataForm.fromElement(x)!;
      final field = form.fields.single;
      expect(field.options.map((o) => o.value), ['open', 'presence', 'whitelist']);
      expect(field.required, isTrue);
    });

    test('skips fields with no var attribute', () {
      final x = _form([_field(label: 'Just a header', type: 'fixed')]);
      final form = DataForm.fromElement(x)!;
      expect(form.fields, isEmpty);
    });

    test('returns null for non-data-form elements', () {
      final notAForm = XmppElement()..name = 'x';
      notAForm.addAttribute(XmppAttribute('xmlns', 'something:else'));
      expect(DataForm.fromElement(notAForm), isNull);
      expect(DataForm.fromElement(null), isNull);
    });
  });

  group('DataForm.toSubmitElement', () {
    test('echoes FORM_TYPE and serializes fields with their type/value', () {
      const form = DataForm(
        formType: 'urn:example:config',
        fields: [
          DataFormField(varName: 'pubsub#title', type: DataFormFieldType.textSingle, values: ['hi']),
        ],
      );
      final x = form.toSubmitElement();
      expect(x.name, 'x');
      expect(x.getAttribute('xmlns')?.value, dataFormXmlns);
      expect(x.getAttribute('type')?.value, 'submit');
      final fields = x.children.where((c) => c.name == 'field').toList();
      expect(fields, hasLength(2));
      expect(fields[0].getAttribute('var')?.value, 'FORM_TYPE');
      expect(fields[0].getChild('value')?.textValue, 'urn:example:config');
      expect(fields[1].getAttribute('var')?.value, 'pubsub#title');
      expect(fields[1].getAttribute('type')?.value, 'text-single');
      expect(fields[1].getChild('value')?.textValue, 'hi');
    });

    test('omits fixed fields, since they are read-only and informational-only', () {
      const form = DataForm(
        fields: [
          DataFormField(varName: 'header', type: DataFormFieldType.fixed, values: ['Section']),
          DataFormField(varName: 'pubsub#title', type: DataFormFieldType.textSingle, values: ['hi']),
        ],
      );
      final fields = form
          .toSubmitElement()
          .children
          .where((c) => c.name == 'field')
          .map((c) => c.getAttribute('var')?.value)
          .toList();
      expect(fields, ['pubsub#title']);
    });
  });

  group('DataForm.withFieldValues', () {
    test('replaces only the named field values, preserving the rest', () {
      const form = DataForm(
        fields: [
          DataFormField(varName: 'pubsub#title', type: DataFormFieldType.textSingle, values: ['old']),
          DataFormField(varName: 'pubsub#access_model', type: DataFormFieldType.listSingle, values: ['presence']),
        ],
      );
      final updated = form.withFieldValues({'pubsub#access_model': ['open']});
      expect(updated.fields[0].values, ['old']);
      expect(updated.fields[1].values, ['open']);
    });
  });

  group('dataFormFieldTypeAllowsMultipleValues', () {
    test('is true for list-multi, jid-multi, text-multi and hidden', () {
      expect(dataFormFieldTypeAllowsMultipleValues(DataFormFieldType.listMulti), isTrue);
      expect(dataFormFieldTypeAllowsMultipleValues(DataFormFieldType.jidMulti), isTrue);
      expect(dataFormFieldTypeAllowsMultipleValues(DataFormFieldType.textMulti), isTrue);
      expect(dataFormFieldTypeAllowsMultipleValues(DataFormFieldType.hidden), isTrue);
    });

    test('is false for single-valued field types', () {
      expect(dataFormFieldTypeAllowsMultipleValues(DataFormFieldType.textSingle), isFalse);
      expect(dataFormFieldTypeAllowsMultipleValues(DataFormFieldType.listSingle), isFalse);
      expect(dataFormFieldTypeAllowsMultipleValues(null), isFalse);
    });
  });
}
