import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart' as xmlpkg;
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/xmpp/data_forms.dart';

/// Converts a raw XML string into an [XmppElement] tree, for building
/// round-trip test fixtures by hand (mirroring the conversion logic used
/// when parsing XML off the wire elsewhere in the app).
XmppElement _parseXml(String rawXml) {
  return _xmppElementFromXmlNode(xmlpkg.XmlDocument.parse(rawXml).rootElement);
}

XmppElement _xmppElementFromXmlNode(xmlpkg.XmlElement element) {
  final xmppElement = XmppElement()..name = element.name.local;
  for (final attribute in element.attributes) {
    xmppElement.addAttribute(XmppAttribute(attribute.name.local, attribute.value));
  }
  for (final child in element.children) {
    if (child is xmlpkg.XmlElement) {
      xmppElement.addChild(_xmppElementFromXmlNode(child));
    } else if (child is xmlpkg.XmlText) {
      final text = child.value.trim();
      if (text.isNotEmpty) {
        xmppElement.textValue = text;
      }
    }
  }
  return xmppElement;
}

XmppElement _field({
  String? varName,
  String? label,
  String? type,
  List<String> values = const [],
  List<String> options = const [],
  bool required = false,
  XmppElement? validate,
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
  if (validate != null) field.addChild(validate);
  return field;
}

const _validateXmlns = dataFormValidateXmlns;

XmppElement _validate({
  String? datatype,
  XmppElement? method,
  XmppElement? listRange,
}) {
  final validate = XmppElement()..name = 'validate';
  validate.addAttribute(XmppAttribute('xmlns', _validateXmlns));
  if (datatype != null) validate.addAttribute(XmppAttribute('datatype', datatype));
  if (method != null) validate.addChild(method);
  if (listRange != null) validate.addChild(listRange);
  return validate;
}

XmppElement _basic() => XmppElement()..name = 'basic';
XmppElement _open() => XmppElement()..name = 'open';
XmppElement _regex(String pattern) => XmppElement()
  ..name = 'regex'
  ..textValue = pattern;
XmppElement _range({String? min, String? max}) {
  final range = XmppElement()..name = 'range';
  if (min != null) range.addAttribute(XmppAttribute('min', min));
  if (max != null) range.addAttribute(XmppAttribute('max', max));
  return range;
}
XmppElement _listRange({String? min, String? max}) {
  final listRange = XmppElement()..name = 'list-range';
  if (min != null) listRange.addAttribute(XmppAttribute('min', min));
  if (max != null) listRange.addAttribute(XmppAttribute('max', max));
  return listRange;
}

XmppElement _form(
  List<XmppElement> fields, {
  String? title,
  List<String> instructions = const [],
  List<XmppElement> pages = const [],
}) {
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
  for (final page in pages) {
    x.addChild(page);
  }
  return x;
}

const _layoutXmlns = dataFormLayoutXmlns;

XmppElement _page({String? label, List<XmppElement> items = const []}) {
  final page = XmppElement()..name = 'page';
  page.addAttribute(XmppAttribute('xmlns', _layoutXmlns));
  if (label != null) page.addAttribute(XmppAttribute('label', label));
  for (final item in items) {
    page.addChild(item);
  }
  return page;
}

XmppElement _text(String text) => XmppElement()
  ..name = 'text'
  ..textValue = text;

XmppElement _fieldref(String varName) {
  final fieldref = XmppElement()..name = 'fieldref';
  fieldref.addAttribute(XmppAttribute('var', varName));
  return fieldref;
}

XmppElement _section({String? label, List<XmppElement> items = const []}) {
  final section = XmppElement()..name = 'section';
  if (label != null) section.addAttribute(XmppAttribute('label', label));
  for (final item in items) {
    section.addChild(item);
  }
  return section;
}

XmppElement _reportedref() => XmppElement()..name = 'reportedref';

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

  group('XEP-0122 DataFormValidation', () {
    test('parses the basic method', () {
      final x = _form([_field(varName: 'v', validate: _validate(method: _basic()))]);
      final validation = DataForm.fromElement(x)!.fields.single.validation;
      expect(validation, isNotNull);
      expect(validation!.method, DataFormValidationMethod.basic);
      expect(validation.datatype, 'xs:string');
    });

    test('parses the open method', () {
      final x = _form([_field(varName: 'v', validate: _validate(method: _open()))]);
      final validation = DataForm.fromElement(x)!.fields.single.validation;
      expect(validation!.method, DataFormValidationMethod.open);
    });

    test('parses the regex method with its pattern text', () {
      final x = _form([
        _field(varName: 'v', validate: _validate(datatype: 'xs:string', method: _regex(r'^\d{3}$'))),
      ]);
      final validation = DataForm.fromElement(x)!.fields.single.validation;
      expect(validation!.method, DataFormValidationMethod.regex);
      expect(validation.regex, r'^\d{3}$');
    });

    test('parses the range method with both min and max', () {
      final x = _form([
        _field(varName: 'v', validate: _validate(datatype: 'xs:int', method: _range(min: '1', max: '10'))),
      ]);
      final validation = DataForm.fromElement(x)!.fields.single.validation;
      expect(validation!.method, DataFormValidationMethod.range);
      expect(validation.rangeMin, '1');
      expect(validation.rangeMax, '10');
      expect(validation.datatype, 'xs:int');
    });

    test('parses the range method with only min or only max', () {
      final xMinOnly = _form([_field(varName: 'v', validate: _validate(method: _range(min: '5')))]);
      final minOnly = DataForm.fromElement(xMinOnly)!.fields.single.validation!;
      expect(minOnly.rangeMin, '5');
      expect(minOnly.rangeMax, isNull);

      final xMaxOnly = _form([_field(varName: 'v', validate: _validate(method: _range(max: '9')))]);
      final maxOnly = DataForm.fromElement(xMaxOnly)!.fields.single.validation!;
      expect(maxOnly.rangeMin, isNull);
      expect(maxOnly.rangeMax, '9');
    });

    test('defaults datatype to xs:string when absent', () {
      final x = _form([_field(varName: 'v', validate: _validate(method: _basic()))]);
      expect(DataForm.fromElement(x)!.fields.single.validation!.datatype, 'xs:string');
    });

    test('uses the explicit datatype attribute when present', () {
      final x = _form([_field(varName: 'v', validate: _validate(datatype: 'xs:anyURI', method: _basic()))]);
      expect(DataForm.fromElement(x)!.fields.single.validation!.datatype, 'xs:anyURI');
    });

    test('parses a list-range alone (no method)', () {
      final x = _form([
        _field(varName: 'v', validate: _validate(listRange: _listRange(min: '1', max: '3'))),
      ]);
      final validation = DataForm.fromElement(x)!.fields.single.validation!;
      expect(validation.method, isNull);
      expect(validation.listRange, isNotNull);
      expect(validation.listRange!.min, 1);
      expect(validation.listRange!.max, 3);
    });

    test('parses a list-range combined with a method', () {
      final x = _form([
        _field(
          varName: 'v',
          validate: _validate(method: _basic(), listRange: _listRange(min: '2')),
        ),
      ]);
      final validation = DataForm.fromElement(x)!.fields.single.validation!;
      expect(validation.method, DataFormValidationMethod.basic);
      expect(validation.listRange!.min, 2);
      expect(validation.listRange!.max, isNull);
    });

    test('is null for a field with no validate child', () {
      final x = _form([_field(varName: 'v')]);
      expect(DataForm.fromElement(x)!.fields.single.validation, isNull);
    });

    // A <validate/> with no recognized method child (e.g. missing or
    // malformed) is still parsed into a DataFormValidation object (so
    // datatype/list-range are still available), but with a null `method`.
    test('is non-null with a null method for a validate with no recognized method child', () {
      final x = _form([_field(varName: 'v', validate: _validate(datatype: 'xs:int'))]);
      final validation = DataForm.fromElement(x)!.fields.single.validation;
      expect(validation, isNotNull);
      expect(validation!.method, isNull);
      expect(validation.datatype, 'xs:int');
    });

    test('copyWith preserves validation', () {
      final x = _form([_field(varName: 'v', values: ['a'], validate: _validate(method: _basic()))]);
      final field = DataForm.fromElement(x)!.fields.single;
      final updated = field.copyWith(values: ['b']);
      expect(updated.values, ['b']);
      expect(updated.validation, isNotNull);
      expect(updated.validation!.method, DataFormValidationMethod.basic);
    });
  });

  group('XEP-0141 DataFormPage layout', () {
    test('parses a flat list of text/fieldref items in order', () {
      final x = _form(
        [_field(varName: 'name')],
        pages: [
          _page(items: [_text('Please fill in your name.'), _fieldref('name')]),
        ],
      );
      final form = DataForm.fromElement(x)!;
      expect(form.pages, hasLength(1));
      final items = form.pages.single.items;
      expect(items, hasLength(2));
      expect((items[0] as DataFormLayoutText).text, 'Please fill in your name.');
      expect((items[1] as DataFormLayoutFieldRef).varName, 'name');
    });

    test('parses nested sections, including sections within sections', () {
      final x = _form(
        [],
        pages: [
          _page(
            items: [
              _section(
                label: 'Outer',
                items: [
                  _text('outer text'),
                  _section(label: 'Inner', items: [_fieldref('deep')]),
                ],
              ),
            ],
          ),
        ],
      );
      final form = DataForm.fromElement(x)!;
      final outer = form.pages.single.items.single as DataFormLayoutSection;
      expect(outer.label, 'Outer');
      expect(outer.items, hasLength(2));
      expect((outer.items[0] as DataFormLayoutText).text, 'outer text');
      final inner = outer.items[1] as DataFormLayoutSection;
      expect(inner.label, 'Inner');
      expect((inner.items.single as DataFormLayoutFieldRef).varName, 'deep');
    });

    test('parses a page with and without a label', () {
      final x = _form(
        [],
        pages: [_page(label: 'Page One'), _page()],
      );
      final form = DataForm.fromElement(x)!;
      expect(form.pages[0].label, 'Page One');
      expect(form.pages[1].label, isNull);
    });

    test('parses multiple pages on one form', () {
      final x = _form(
        [],
        pages: [
          _page(label: 'First', items: [_text('a')]),
          _page(label: 'Second', items: [_text('b')]),
        ],
      );
      final form = DataForm.fromElement(x)!;
      expect(form.pages, hasLength(2));
      expect(form.pages[0].label, 'First');
      expect(form.pages[1].label, 'Second');
    });

    test('pages is empty (not null) for a form with no pages', () {
      final x = _form([_field(varName: 'v')]);
      final form = DataForm.fromElement(x)!;
      expect(form.pages, isNotNull);
      expect(form.pages, isEmpty);
    });

    test('parses reportedref', () {
      final x = _form(
        [],
        pages: [
          _page(items: [_reportedref(), _text('after')]),
        ],
      );
      final items = DataForm.fromElement(x)!.pages.single.items;
      expect(items[0], isA<DataFormLayoutReportedRef>());
      expect((items[1] as DataFormLayoutText).text, 'after');
    });

    test('withFieldValues preserves pages', () {
      final x = _form(
        [_field(varName: 'v', values: ['old'])],
        pages: [_page(label: 'P', items: [_fieldref('v')])],
      );
      final form = DataForm.fromElement(x)!;
      final updated = form.withFieldValues({'v': ['new']});
      expect(updated.pages, hasLength(1));
      expect(updated.pages.single.label, 'P');
    });
  });

  group('XEP-0004 + XEP-0122 + XEP-0141 round-trip', () {
    test('parses a full form combining validate and layout with ordinary fields', () {
      final xml = '''
<x xmlns="jabber:x:data" type="form">
  <title>Full form</title>
  <instructions>Fill it in.</instructions>
  <field var="FORM_TYPE" type="hidden"><value>urn:example:full</value></field>
  <field var="username" type="text-single" label="Username">
    <validate xmlns="http://jabber.org/protocol/xdata-validate" datatype="xs:string">
      <regex>^[a-z0-9]+\$</regex>
    </validate>
  </field>
  <field var="age" type="text-single" label="Age">
    <validate xmlns="http://jabber.org/protocol/xdata-validate" datatype="xs:int">
      <range min="0" max="120"/>
    </validate>
  </field>
  <field var="tags" type="list-multi" label="Tags">
    <option label="A"><value>a</value></option>
    <option label="B"><value>b</value></option>
    <validate xmlns="http://jabber.org/protocol/xdata-validate">
      <basic/>
      <list-range min="1" max="2"/>
    </validate>
  </field>
  <page xmlns="http://jabber.org/protocol/xdata-layout" label="Main">
    <text>Please fill in the fields below.</text>
    <fieldref var="username"/>
    <section label="Details">
      <fieldref var="age"/>
      <fieldref var="tags"/>
    </section>
  </page>
</x>
''';
      final element = _parseXml(xml);
      final form = DataForm.fromElement(element)!;
      expect(form.formType, 'urn:example:full');
      expect(form.title, 'Full form');
      expect(form.instructions, ['Fill it in.']);
      expect(form.fields, hasLength(3));

      final username = form.fields.firstWhere((f) => f.varName == 'username');
      expect(username.validation!.method, DataFormValidationMethod.regex);
      expect(username.validation!.regex, r'^[a-z0-9]+$');

      final age = form.fields.firstWhere((f) => f.varName == 'age');
      expect(age.validation!.method, DataFormValidationMethod.range);
      expect(age.validation!.rangeMin, '0');
      expect(age.validation!.rangeMax, '120');
      expect(age.validation!.datatype, 'xs:int');

      final tags = form.fields.firstWhere((f) => f.varName == 'tags');
      expect(tags.validation!.method, DataFormValidationMethod.basic);
      expect(tags.validation!.listRange!.min, 1);
      expect(tags.validation!.listRange!.max, 2);

      expect(form.pages, hasLength(1));
      final page = form.pages.single;
      expect(page.label, 'Main');
      expect(page.items, hasLength(3));
      expect((page.items[0] as DataFormLayoutText).text, 'Please fill in the fields below.');
      expect((page.items[1] as DataFormLayoutFieldRef).varName, 'username');
      final section = page.items[2] as DataFormLayoutSection;
      expect(section.label, 'Details');
      expect((section.items[0] as DataFormLayoutFieldRef).varName, 'age');
      expect((section.items[1] as DataFormLayoutFieldRef).varName, 'tags');
    });
  });
}
