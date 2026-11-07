/// Generic XEP-0004 (Data Forms) support.
///
/// This is a small, reusable "engine" for parsing and building
/// `<x xmlns='jabber:x:data'/>` data forms, independent of whatever XEP
/// embeds them. It currently backs the PEP explorer's XEP-0060
/// `pubsub#owner` node configuration editor, and is intended to be reused
/// for other data-form-carrying extensions (e.g. XEP-0045 MUC room
/// configuration) rather than re-implemented ad hoc each time.
///
/// It also supports two data-forms extensions that servers/field-processing
/// entities may attach to a `form`/`result`-typed form as parsing/rendering
/// hints: XEP-0122 (Data Forms Validation), which lets a `<field/>` declare
/// a `<validate/>` child describing acceptable input (datatype, validation
/// method and/or an allowed-count range for multi-valued fields), and
/// XEP-0141 (Data Forms Layout), which lets a form group its fields into
/// `<page/>`s (and nested `<section/>`s) for improved presentation. Both are
/// purely server->client hints and are never re-serialized when submitting
/// a form back (see [DataForm.toSubmitElement]).
library;

import 'package:xmpp_stone/xmpp_stone.dart';

const String dataFormXmlns = 'jabber:x:data';

/// The XEP-0122 (Data Forms Validation) namespace.
const String dataFormValidateXmlns = 'http://jabber.org/protocol/xdata-validate';

/// The field types defined by XEP-0004 §3.3.
enum DataFormFieldType {
  boolean,
  fixed,
  hidden,
  jidMulti,
  jidSingle,
  listMulti,
  listSingle,
  textMulti,
  textPrivate,
  textSingle,
}

/// Parses a XEP-0004 wire value (e.g. `list-single`) into a
/// [DataFormFieldType], or `null` if [wire] is `null`/unrecognized. Per
/// XEP-0004 §3.2, an absent `type` attribute on a `form`-typed field
/// defaults to `text-single`, but this function intentionally leaves that
/// defaulting to callers since it only matters for `form`/`result` fields.
DataFormFieldType? dataFormFieldTypeFromWire(String? wire) {
  switch (wire) {
    case 'boolean':
      return DataFormFieldType.boolean;
    case 'fixed':
      return DataFormFieldType.fixed;
    case 'hidden':
      return DataFormFieldType.hidden;
    case 'jid-multi':
      return DataFormFieldType.jidMulti;
    case 'jid-single':
      return DataFormFieldType.jidSingle;
    case 'list-multi':
      return DataFormFieldType.listMulti;
    case 'list-single':
      return DataFormFieldType.listSingle;
    case 'text-multi':
      return DataFormFieldType.textMulti;
    case 'text-private':
      return DataFormFieldType.textPrivate;
    case 'text-single':
      return DataFormFieldType.textSingle;
    default:
      return null;
  }
}

/// Serializes a [DataFormFieldType] back to its XEP-0004 wire value.
String dataFormFieldTypeToWire(DataFormFieldType type) {
  switch (type) {
    case DataFormFieldType.boolean:
      return 'boolean';
    case DataFormFieldType.fixed:
      return 'fixed';
    case DataFormFieldType.hidden:
      return 'hidden';
    case DataFormFieldType.jidMulti:
      return 'jid-multi';
    case DataFormFieldType.jidSingle:
      return 'jid-single';
    case DataFormFieldType.listMulti:
      return 'list-multi';
    case DataFormFieldType.listSingle:
      return 'list-single';
    case DataFormFieldType.textMulti:
      return 'text-multi';
    case DataFormFieldType.textPrivate:
      return 'text-private';
    case DataFormFieldType.textSingle:
      return 'text-single';
  }
}

/// Field types that, per XEP-0004 §3.3, may carry more than one `<value/>`
/// child. All other field types MUST NOT contain more than one.
bool dataFormFieldTypeAllowsMultipleValues(DataFormFieldType? type) {
  return type == DataFormFieldType.listMulti ||
      type == DataFormFieldType.jidMulti ||
      type == DataFormFieldType.textMulti ||
      type == DataFormFieldType.hidden;
}

/// A single `<option/>` of a `list-single`/`list-multi` field (XEP-0004
/// §3.3), i.e. one of the values the field-processing entity declared as
/// acceptable.
class DataFormOption {
  const DataFormOption({required this.value, this.label});

  final String value;
  final String? label;
}

/// The validation methods defined by XEP-0122 §3.3, describing how a
/// field's value(s) should be checked against [DataFormValidation.datatype].
enum DataFormValidationMethod {
  /// The value simply needs to be a valid instance of the given datatype.
  basic,

  /// Like [basic], but the field-processing entity declares that it will
  /// also accept values outside the ones listed in the field's `<option/>`
  /// children (for `list-single`/`list-multi` fields).
  open,

  /// The value must match the datatype's lexical space *and* the regular
  /// expression carried in [DataFormValidation.regex].
  regex,

  /// The value must fall within the inclusive numeric range described by
  /// [DataFormValidation.rangeMin]/[DataFormValidation.rangeMax].
  range,
}

/// Parses a XEP-0122 `<validate/>` method child name into a
/// [DataFormValidationMethod], or `null` if unrecognized.
DataFormValidationMethod? _dataFormValidationMethodFromElementName(String name) {
  switch (name) {
    case 'basic':
      return DataFormValidationMethod.basic;
    case 'open':
      return DataFormValidationMethod.open;
    case 'regex':
      return DataFormValidationMethod.regex;
    case 'range':
      return DataFormValidationMethod.range;
    default:
      return null;
  }
}

/// A XEP-0122 `<list-range/>`, constraining the number of values a
/// `list-multi`/`jid-multi`/`text-multi` field may carry. Either bound may
/// be absent, meaning that bound is unconstrained.
class DataFormListRange {
  const DataFormListRange({this.min, this.max});

  final int? min;
  final int? max;

  static DataFormListRange? fromElement(XmppElement? listRangeEl) {
    // Unlike the top-level <validate/> element, <list-range/> is a plain
    // child and doesn't repeat the xmlns attribute (it inherits it from its
    // parent per normal XML namespace rules), so only the element name is
    // checked here.
    if (listRangeEl == null || listRangeEl.name != 'list-range') {
      return null;
    }
    return DataFormListRange(
      min: int.tryParse(listRangeEl.getAttribute('min')?.value ?? ''),
      max: int.tryParse(listRangeEl.getAttribute('max')?.value ?? ''),
    );
  }
}

/// A XEP-0122 (Data Forms Validation) `<validate/>` hint attached to a
/// `<field/>` of a `form`/`result`-typed data form, describing the
/// acceptable input for that field. This is a server->client hint only and
/// is never re-serialized when submitting the form back.
class DataFormValidation {
  const DataFormValidation({
    this.datatype = 'xs:string',
    this.method,
    this.regex,
    this.rangeMin,
    this.rangeMax,
    this.listRange,
  });

  /// The `datatype` attribute, e.g. `xs:string`/`xs:int`. Defaults to
  /// `xs:string` per XEP-0122 §3.2 when the attribute is absent.
  final String datatype;

  /// Which of the mutually-exclusive validation methods applies, or `null`
  /// if `<validate/>` had no recognized method child.
  final DataFormValidationMethod? method;

  /// The pattern text of a `<regex/>` method child, only set when [method]
  /// is [DataFormValidationMethod.regex].
  final String? regex;

  /// The `min`/`max` attributes of a `<range/>` method child, only set when
  /// [method] is [DataFormValidationMethod.range]. Kept as raw strings
  /// (rather than parsed numbers) since [datatype] can be any `xs:` type,
  /// not just numeric ones.
  final String? rangeMin;
  final String? rangeMax;

  /// The optional `<list-range/>`, constraining the number of selected or
  /// entered values for list-multi/jid-multi/text-multi fields. Valid
  /// alongside any [method].
  final DataFormListRange? listRange;

  /// Parses a `<validate xmlns='http://jabber.org/protocol/xdata-validate'/>`
  /// element, or returns `null` if [validateEl] is `null` or isn't that
  /// element.
  static DataFormValidation? fromElement(XmppElement? validateEl) {
    if (validateEl == null ||
        validateEl.name != 'validate' ||
        validateEl.getAttribute('xmlns')?.value != dataFormValidateXmlns) {
      return null;
    }
    final datatype = validateEl.getAttribute('datatype')?.value ?? 'xs:string';
    DataFormValidationMethod? method;
    String? regex;
    String? rangeMin;
    String? rangeMax;
    for (final child in validateEl.children) {
      final parsedMethod = _dataFormValidationMethodFromElementName(child.name ?? '');
      if (parsedMethod == null) {
        continue;
      }
      method = parsedMethod;
      if (parsedMethod == DataFormValidationMethod.regex) {
        regex = child.textValue ?? '';
      } else if (parsedMethod == DataFormValidationMethod.range) {
        rangeMin = child.getAttribute('min')?.value;
        rangeMax = child.getAttribute('max')?.value;
      }
      break;
    }
    return DataFormValidation(
      datatype: datatype,
      method: method,
      regex: regex,
      rangeMin: rangeMin,
      rangeMax: rangeMax,
      listRange: DataFormListRange.fromElement(validateEl.getChild('list-range')),
    );
  }
}

/// A single `<field/>` of a data form.
class DataFormField {
  const DataFormField({
    required this.varName,
    this.label,
    this.type,
    this.values = const [],
    this.options = const [],
    this.required = false,
    this.validation,
  });

  final String varName;
  final String? label;
  final DataFormFieldType? type;
  final List<String> values;

  /// The acceptable values for `list-single`/`list-multi` fields, as
  /// declared by the form-processing entity. Empty for other field types.
  final List<DataFormOption> options;
  final bool required;

  /// The XEP-0122 validation hint for this field, if the field-processing
  /// entity declared one. `null` if the field had no `<validate/>` child.
  final DataFormValidation? validation;

  DataFormField copyWith({List<String>? values}) => DataFormField(
        varName: varName,
        label: label,
        type: type,
        values: values ?? this.values,
        options: options,
        required: required,
        validation: validation,
      );
}

/// The XEP-0141 (Data Forms Layout) namespace.
const String dataFormLayoutXmlns = 'http://jabber.org/protocol/xdata-layout';

/// A single ordered item within a XEP-0141 `<page/>` or `<section/>`: a line
/// of instructional text, a reference to a field to render at this point, a
/// nested grouping of further items, or a reference to a reported/row
/// header. Modeled as a base class with one subclass per item kind, since
/// the XEP-0004 engine doesn't otherwise use sealed-class-style hierarchies.
abstract class DataFormLayoutItem {
  const DataFormLayoutItem();
}

/// A `<text>...</text>` line of instructional text within a page/section.
class DataFormLayoutText extends DataFormLayoutItem {
  const DataFormLayoutText(this.text);

  final String text;
}

/// A `<fieldref var='...'/>`, referencing the field (by its `var`) to render
/// at this point in the layout.
class DataFormLayoutFieldRef extends DataFormLayoutItem {
  const DataFormLayoutFieldRef(this.varName);

  final String varName;
}

/// A `<section label='...'>`, a nested grouping of further layout items.
class DataFormLayoutSection extends DataFormLayoutItem {
  const DataFormLayoutSection({this.label, this.items = const []});

  final String? label;
  final List<DataFormLayoutItem> items;
}

/// A `<reportedref/>`, referencing the reported/row header. Modeled
/// minimally as a marker, since reported items aren't otherwise represented
/// in this generic XEP-0004 engine.
class DataFormLayoutReportedRef extends DataFormLayoutItem {
  const DataFormLayoutReportedRef();
}

/// Parses the ordered `<text/>`/`<fieldref/>`/`<section/>`/`<reportedref/>`
/// children of a XEP-0141 `<page/>` or `<section/>` element into a list of
/// [DataFormLayoutItem], preserving document order.
List<DataFormLayoutItem> _dataFormLayoutItemsFromElement(XmppElement containerEl) {
  final items = <DataFormLayoutItem>[];
  for (final child in containerEl.children) {
    switch (child.name) {
      case 'text':
        items.add(DataFormLayoutText(child.textValue ?? ''));
        break;
      case 'fieldref':
        final varName = child.getAttribute('var')?.value;
        if (varName != null) {
          items.add(DataFormLayoutFieldRef(varName));
        }
        break;
      case 'section':
        items.add(
          DataFormLayoutSection(
            label: child.getAttribute('label')?.value,
            items: _dataFormLayoutItemsFromElement(child),
          ),
        );
        break;
      case 'reportedref':
        items.add(const DataFormLayoutReportedRef());
        break;
    }
  }
  return items;
}

/// A XEP-0141 (Data Forms Layout) `<page/>`, grouping a subset of a form's
/// fields (by reference) together with instructional text and nested
/// sections for improved presentation. This is a server->client rendering
/// hint only and is never re-serialized when submitting the form back.
class DataFormPage {
  const DataFormPage({this.label, this.items = const []});

  final String? label;
  final List<DataFormLayoutItem> items;

  /// Parses a `<page xmlns='http://jabber.org/protocol/xdata-layout'/>`
  /// element into a [DataFormPage].
  static DataFormPage fromElement(XmppElement pageEl) {
    return DataFormPage(
      label: pageEl.getAttribute('label')?.value,
      items: _dataFormLayoutItemsFromElement(pageEl),
    );
  }
}

/// A parsed XEP-0004 data form.
class DataForm {
  const DataForm({
    this.formType,
    this.title,
    this.instructions = const [],
    this.fields = const [],
    this.pages = const [],
  });

  /// The form's `FORM_TYPE` hidden field value, if any. Per XEP-0004 §3.4,
  /// this identifies the form's namespace and MUST be echoed back unchanged
  /// when submitting.
  final String? formType;
  final String? title;
  final List<String> instructions;

  /// All fields other than `FORM_TYPE`, in document order.
  final List<DataFormField> fields;

  /// The XEP-0141 layout pages declared at the top level of the form, if
  /// any. Empty (not `null`) when the form has no layout hints.
  final List<DataFormPage> pages;

  /// Parses an `<x xmlns='jabber:x:data'/>` element into a [DataForm].
  /// Returns `null` if [x] isn't a data form element.
  static DataForm? fromElement(XmppElement? x) {
    if (x == null ||
        x.name != 'x' ||
        x.getAttribute('xmlns')?.value != dataFormXmlns) {
      return null;
    }
    String? formType;
    final fields = <DataFormField>[];
    for (final field in x.children.where((c) => c.name == 'field')) {
      final varName = field.getAttribute('var')?.value;
      final type = dataFormFieldTypeFromWire(field.getAttribute('type')?.value);
      final values = field.children
          .where((c) => c.name == 'value')
          .map((c) => c.textValue ?? '')
          .toList(growable: false);
      if (varName == 'FORM_TYPE') {
        formType = values.isNotEmpty ? values.first : formType;
        continue;
      }
      // A field without a `var` is instructions-only (e.g. a `fixed`
      // section header) and can't be submitted back, so it's not modeled.
      if (varName == null || varName.isEmpty) {
        continue;
      }
      final options = field.children
          .where((c) => c.name == 'option')
          .map(
            (o) => DataFormOption(
              value: o.getChild('value')?.textValue ?? '',
              label: o.getAttribute('label')?.value,
            ),
          )
          .toList(growable: false);
      fields.add(
        DataFormField(
          varName: varName,
          label: field.getAttribute('label')?.value,
          type: type,
          values: values,
          options: options,
          required: field.getChild('required') != null,
          validation: DataFormValidation.fromElement(field.getChild('validate')),
        ),
      );
    }
    final instructions = x.children
        .where((c) => c.name == 'instructions')
        .map((c) => c.textValue ?? '')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final pages = x.children
        .where((c) => c.name == 'page')
        .map(DataFormPage.fromElement)
        .toList(growable: false);
    return DataForm(
      formType: formType,
      title: x.getChild('title')?.textValue,
      instructions: instructions,
      fields: fields,
      pages: pages,
    );
  }

  /// Builds a `<x type='submit'>` element for submitting [fields] back to
  /// the server (XEP-0004 §3.3), echoing [formType] unchanged as required.
  ///
  /// Fields of type `fixed` are always omitted: they are read-only,
  /// informational-only fields (e.g. section headers) that are never
  /// meant to be sent back in a submission.
  ///
  /// Note that a field's XEP-0122 [DataFormField.validation] hint and the
  /// form's XEP-0141 [pages] layout are never re-serialized here: they're
  /// informational server->client hints only, not something the client
  /// echoes back when submitting.
  XmppElement toSubmitElement() {
    final x = XmppElement()..name = 'x';
    x.addAttribute(XmppAttribute('xmlns', dataFormXmlns));
    x.addAttribute(XmppAttribute('type', 'submit'));
    if (formType != null && formType!.isNotEmpty) {
      final formTypeField = XmppElement()..name = 'field';
      formTypeField.addAttribute(XmppAttribute('var', 'FORM_TYPE'));
      formTypeField.addAttribute(XmppAttribute('type', 'hidden'));
      final value = XmppElement()
        ..name = 'value'
        ..textValue = formType;
      formTypeField.addChild(value);
      x.addChild(formTypeField);
    }
    for (final field in fields) {
      if (field.type == DataFormFieldType.fixed) {
        continue;
      }
      final fieldEl = XmppElement()..name = 'field';
      fieldEl.addAttribute(XmppAttribute('var', field.varName));
      if (field.type != null) {
        fieldEl.addAttribute(
          XmppAttribute('type', dataFormFieldTypeToWire(field.type!)),
        );
      }
      for (final value in field.values) {
        final valueEl = XmppElement()
          ..name = 'value'
          ..textValue = value;
        fieldEl.addChild(valueEl);
      }
      x.addChild(fieldEl);
    }
    return x;
  }

  /// Returns a copy of this form with the values of the fields named in
  /// [updates] replaced, leaving all other fields (and their types/options)
  /// untouched.
  DataForm withFieldValues(Map<String, List<String>> updates) {
    return DataForm(
      formType: formType,
      title: title,
      instructions: instructions,
      fields: [
        for (final field in fields)
          updates.containsKey(field.varName)
              ? field.copyWith(values: updates[field.varName])
              : field,
      ],
      pages: pages,
    );
  }
}
