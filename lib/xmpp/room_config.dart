/// Models and parsing helpers for chatroom (MUC, XEP-0045) administration:
/// lets a room owner/admin inspect and edit the room's configuration form
/// (XEP-0045 §10.2 "Subsequent Room Configuration", carried via the
/// `http://jabber.org/protocol/muc#owner` namespace) using the generic
/// XEP-0004 [DataForm] engine.
library;

import 'package:xmpp_stone/xmpp_stone.dart';

import 'data_forms.dart';

export 'data_forms.dart' show dataFormXmlns;

const String mucOwnerXmlns = 'http://jabber.org/protocol/muc#owner';

/// A single field from a room's `muc#owner` configuration data form.
class RoomConfigField {
  const RoomConfigField({
    required this.varName,
    this.label,
    this.type,
    this.values = const [],
    this.options = const [],
  });

  final String varName;
  final String? label;
  final String? type;
  final List<String> values;

  /// The acceptable values for `list-single`/`list-multi` fields, as
  /// declared by the server (XEP-0004 §3.3). Empty for other field types.
  final List<DataFormOption> options;
}

/// Extracts the `muc#owner` `<query/>` form result's underlying [DataForm],
/// or `null` if [result] isn't a valid configuration form result.
DataForm? _roomConfigDataForm(IqStanza? result) {
  if (result == null || result.type != IqStanzaType.RESULT) {
    return null;
  }
  final query = result.getChild('query');
  if (query == null || query.getAttribute('xmlns')?.value != mucOwnerXmlns) {
    return null;
  }
  final form = query.children.where(
    (c) => c.name == 'x' && c.getAttribute('xmlns')?.value == dataFormXmlns,
  );
  if (form.isEmpty) {
    return null;
  }
  return DataForm.fromElement(form.first);
}

/// Parses the `<x xmlns='jabber:x:data'>` configuration form carried in a
/// `muc#owner` `<query/>` IQ result into a list of [RoomConfigField]s, using
/// the generic XEP-0004 [DataForm] engine.
///
/// The `FORM_TYPE` field is omitted since it's just the form's namespace
/// marker, not a user-relevant configuration value.
List<RoomConfigField> parseRoomConfig(IqStanza? result) {
  final form = _roomConfigDataForm(result);
  if (form == null) {
    return const [];
  }
  return [
    for (final field in form.fields)
      RoomConfigField(
        varName: field.varName,
        label: field.label,
        type: field.type != null ? dataFormFieldTypeToWire(field.type!) : null,
        values: field.values,
        options: field.options,
      ),
  ];
}

/// Extracts the `FORM_TYPE` value from a room's configuration data form
/// result (always `http://jabber.org/protocol/muc#roomconfig` per
/// XEP-0045), which must be echoed back unchanged when submitting an
/// edited configuration.
///
/// Returns `null` if [result] isn't a valid configuration form result, or
/// doesn't carry a `FORM_TYPE` field.
String? parseRoomConfigFormType(IqStanza? result) {
  return _roomConfigDataForm(result)?.formType;
}

/// Builds the `<x xmlns='jabber:x:data' type='submit'>` data form to submit
/// an edited room configuration (XEP-0045 §10.2 / XEP-0004).
///
/// [formType] (if non-null) is echoed back as the hidden `FORM_TYPE` field,
/// as required for the submission to be recognized by the server.
XmppElement buildRoomConfigSubmitForm(
  String? formType,
  List<RoomConfigField> fields,
) {
  final form = DataForm(
    formType: formType,
    fields: [
      for (final field in fields)
        DataFormField(
          varName: field.varName,
          label: field.label,
          type: dataFormFieldTypeFromWire(field.type),
          values: field.values,
          options: field.options,
        ),
    ],
  );
  return form.toSubmitElement();
}

/// Builds the `<x xmlns='jabber:x:data' type='cancel'/>` form used to cancel
/// a room configuration dialog (XEP-0045 §10.2), without applying any
/// changes.
XmppElement buildRoomConfigCancelForm() {
  final form = XmppElement()..name = 'x';
  form.addAttribute(XmppAttribute('xmlns', dataFormXmlns));
  form.addAttribute(XmppAttribute('type', 'cancel'));
  return form;
}

/// Extracts a human-readable error condition (e.g. `item-not-found`,
/// `forbidden`) from a failed IQ [result], or `null` if [result] is a
/// success or carries no recognizable error element.
String? roomConfigIqErrorCondition(IqStanza? result) {
  if (result == null) {
    return 'timeout';
  }
  if (result.type == IqStanzaType.RESULT) {
    return null;
  }
  final error = result.getChild('error');
  if (error == null) {
    return result.type.toString();
  }
  for (final child in error.children) {
    final name = child.name;
    if (name != null && name.isNotEmpty && name != 'text') {
      return name;
    }
  }
  return 'error';
}

/// Extracts the human-readable `<error><text/></error>` explanation (RFC
/// 6120 §8.3.2) from a failed IQ [result], if the server included one.
/// Returns `null` if there is none (most servers omit it).
String? roomConfigIqErrorText(IqStanza? result) {
  if (result == null || result.type == IqStanzaType.RESULT) {
    return null;
  }
  final error = result.getChild('error');
  final text = error?.getChild('text')?.textValue;
  return text?.isNotEmpty == true ? text : null;
}
