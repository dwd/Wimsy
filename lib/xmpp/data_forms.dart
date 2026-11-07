/// Generic XEP-0004 (Data Forms) support.
///
/// This is a small, reusable "engine" for parsing and building
/// `<x xmlns='jabber:x:data'/>` data forms, independent of whatever XEP
/// embeds them. It currently backs the PEP explorer's XEP-0060
/// `pubsub#owner` node configuration editor, and is intended to be reused
/// for other data-form-carrying extensions (e.g. XEP-0045 MUC room
/// configuration) rather than re-implemented ad hoc each time.
library;

import 'package:xmpp_stone/xmpp_stone.dart';

const String dataFormXmlns = 'jabber:x:data';

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

/// A single `<field/>` of a data form.
class DataFormField {
  const DataFormField({
    required this.varName,
    this.label,
    this.type,
    this.values = const [],
    this.options = const [],
    this.required = false,
  });

  final String varName;
  final String? label;
  final DataFormFieldType? type;
  final List<String> values;

  /// The acceptable values for `list-single`/`list-multi` fields, as
  /// declared by the form-processing entity. Empty for other field types.
  final List<DataFormOption> options;
  final bool required;

  DataFormField copyWith({List<String>? values}) => DataFormField(
        varName: varName,
        label: label,
        type: type,
        values: values ?? this.values,
        options: options,
        required: required,
      );
}

/// A parsed XEP-0004 data form.
class DataForm {
  const DataForm({
    this.formType,
    this.title,
    this.instructions = const [],
    this.fields = const [],
  });

  /// The form's `FORM_TYPE` hidden field value, if any. Per XEP-0004 §3.4,
  /// this identifies the form's namespace and MUST be echoed back unchanged
  /// when submitting.
  final String? formType;
  final String? title;
  final List<String> instructions;

  /// All fields other than `FORM_TYPE`, in document order.
  final List<DataFormField> fields;

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
        ),
      );
    }
    final instructions = x.children
        .where((c) => c.name == 'instructions')
        .map((c) => c.textValue ?? '')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return DataForm(
      formType: formType,
      title: x.getChild('title')?.textValue,
      instructions: instructions,
      fields: fields,
    );
  }

  /// Builds a `<x type='submit'>` element for submitting [fields] back to
  /// the server (XEP-0004 §3.3), echoing [formType] unchanged as required.
  ///
  /// Fields of type `fixed` are always omitted: they are read-only,
  /// informational-only fields (e.g. section headers) that are never
  /// meant to be sent back in a submission.
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
    );
  }
}
