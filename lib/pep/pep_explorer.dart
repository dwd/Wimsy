/// Models and parsing helpers for the PEP explorer: lists all nodes on the
/// logged-in user's PEP (Personal Eventing Protocol, XEP-0163) service via
/// XEP-0030 disco#items, and lets the user inspect a node's configuration
/// (XEP-0060 `pubsub#owner` `configure`) and published items.
library;

import 'package:xmpp_stone/xmpp_stone.dart';

import '../xmpp/data_forms.dart';

export '../xmpp/data_forms.dart' show dataFormXmlns;

const String discoItemsXmlns = 'http://jabber.org/protocol/disco#items';
const String pepPubsubOwnerXmlns = 'http://jabber.org/protocol/pubsub#owner';
const String pepPubsubXmlns = 'http://jabber.org/protocol/pubsub';

/// A single PEP node discovered via disco#items against the account's own
/// bare JID.
class PepNodeSummary {
  const PepNodeSummary({required this.node, this.name});

  final String node;
  final String? name;
}

/// Parses a disco#items IQ result into a list of [PepNodeSummary]s.
///
/// Returns an empty list if [result] isn't a successful disco#items result,
/// or doesn't carry any `node` attributes (plain, non-pubsub disco#items
/// results reference other JIDs rather than nodes and are not relevant
/// here).
List<PepNodeSummary> parsePepNodeSummaries(IqStanza? result) {
  if (result == null || result.type != IqStanzaType.RESULT) {
    return const [];
  }
  final query = result.getChild('query');
  if (query == null ||
      query.getAttribute('xmlns')?.value != discoItemsXmlns) {
    return const [];
  }
  final nodes = <PepNodeSummary>[];
  for (final child in query.children) {
    if (child.name != 'item') {
      continue;
    }
    final node = child.getAttribute('node')?.value?.trim();
    if (node == null || node.isEmpty) {
      continue;
    }
    final name = child.getAttribute('name')?.value?.trim();
    nodes.add(
      PepNodeSummary(node: node, name: name?.isNotEmpty == true ? name : null),
    );
  }
  return nodes;
}

/// A single field from a node's configuration data form.
class PepNodeConfigField {
  const PepNodeConfigField({
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

/// Extracts the `pubsub#owner` `configure` form result's underlying
/// [DataForm], or `null` if [result] isn't a valid configuration form
/// result.
DataForm? _pepNodeConfigDataForm(IqStanza? result) {
  if (result == null || result.type != IqStanzaType.RESULT) {
    return null;
  }
  final pubsub = result.getChild('pubsub');
  if (pubsub == null ||
      pubsub.getAttribute('xmlns')?.value != pepPubsubOwnerXmlns) {
    return null;
  }
  final configure = pubsub.getChild('configure');
  if (configure == null) {
    return null;
  }
  final form = configure.children.where(
    (c) => c.name == 'x' && c.getAttribute('xmlns')?.value == dataFormXmlns,
  );
  if (form.isEmpty) {
    return null;
  }
  return DataForm.fromElement(form.first);
}

/// Parses the `<x xmlns='jabber:x:data'>` configuration form carried in a
/// `pubsub#owner` `configure` IQ result into a list of [PepNodeConfigField]s,
/// using the generic XEP-0004 [DataForm] engine.
///
/// The `FORM_TYPE` field is omitted since it's just the form's namespace
/// marker, not a user-relevant configuration value.
List<PepNodeConfigField> parsePepNodeConfig(IqStanza? result) {
  final form = _pepNodeConfigDataForm(result);
  if (form == null) {
    return const [];
  }
  return [
    for (final field in form.fields)
      PepNodeConfigField(
        varName: field.varName,
        label: field.label,
        type: field.type != null ? dataFormFieldTypeToWire(field.type!) : null,
        values: field.values,
        options: field.options,
      ),
  ];
}

/// A single item published to a PEP node.
class PepNodeItem {
  const PepNodeItem({required this.id, required this.xml});

  /// The item's `id` attribute (may be empty for nodes that don't set one).
  final String id;

  /// The raw serialized XML of the item's payload (its children), for
  /// display purposes.
  final String xml;
}

/// Parses the `<items/>` element from a `pubsub` `items` IQ result into a
/// list of [PepNodeItem]s, keeping each item's raw payload XML for display.
List<PepNodeItem> parsePepNodeItems(IqStanza? result) {
  if (result == null || result.type != IqStanzaType.RESULT) {
    return const [];
  }
  final pubsub = result.getChild('pubsub');
  if (pubsub == null ||
      pubsub.getAttribute('xmlns')?.value != pepPubsubXmlns) {
    return const [];
  }
  final items = pubsub.getChild('items');
  if (items == null) {
    return const [];
  }
  final result2 = <PepNodeItem>[];
  for (final item in items.children.where((c) => c.name == 'item')) {
    final id = item.getAttribute('id')?.value ?? '';
    final xml = item.children.map((c) => c.buildXmlString()).join('\n');
    result2.add(PepNodeItem(id: id, xml: xml));
  }
  return result2;
}

/// Extracts the `FORM_TYPE` value from a node's configuration data form
/// result (e.g. `http://jabber.org/protocol/pubsub#node_config`), which
/// must be echoed back unchanged when submitting an edited configuration.
///
/// Returns `null` if [result] isn't a valid configuration form result, or
/// doesn't carry a `FORM_TYPE` field.
String? parsePepNodeConfigFormType(IqStanza? result) {
  return _pepNodeConfigDataForm(result)?.formType;
}

/// Builds the `<x xmlns='jabber:x:data' type='submit'>` data form to submit
/// an edited node configuration (XEP-0060 §8.2.4 "Form Submission" /
/// XEP-0004).
///
/// [formType] (if non-null) is echoed back as the hidden `FORM_TYPE` field,
/// as required for the submission to be recognized by the server.
XmppElement buildPepNodeConfigSubmitForm(
  String? formType,
  List<PepNodeConfigField> fields,
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

/// Extracts a human-readable error condition (e.g. `item-not-found`,
/// `forbidden`) from a failed IQ [result], or `null` if [result] is a
/// success or carries no recognizable error element.
String? pepIqErrorCondition(IqStanza? result) {
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
String? pepIqErrorText(IqStanza? result) {
  if (result == null || result.type == IqStanzaType.RESULT) {
    return null;
  }
  final error = result.getChild('error');
  final text = error?.getChild('text')?.textValue;
  return text?.isNotEmpty == true ? text : null;
}
