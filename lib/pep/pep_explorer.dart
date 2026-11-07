/// Models and parsing helpers for the PEP explorer: lists all nodes on the
/// logged-in user's PEP (Personal Eventing Protocol, XEP-0163) service via
/// XEP-0030 disco#items, and lets the user inspect a node's configuration
/// (XEP-0060 `pubsub#owner` `configure`) and published items.
library;

import 'package:xmpp_stone/xmpp_stone.dart';

const String discoItemsXmlns = 'http://jabber.org/protocol/disco#items';
const String pepPubsubOwnerXmlns = 'http://jabber.org/protocol/pubsub#owner';
const String pepPubsubXmlns = 'http://jabber.org/protocol/pubsub';
const String dataFormXmlns = 'jabber:x:data';

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
  });

  final String varName;
  final String? label;
  final String? type;
  final List<String> values;
}

/// Parses the `<x xmlns='jabber:x:data'>` configuration form carried in a
/// `pubsub#owner` `configure` IQ result into a list of [PepNodeConfigField]s.
///
/// The `FORM_TYPE` field is omitted since it's just the form's namespace
/// marker, not a user-relevant configuration value.
List<PepNodeConfigField> parsePepNodeConfig(IqStanza? result) {
  if (result == null || result.type != IqStanzaType.RESULT) {
    return const [];
  }
  final pubsub = result.getChild('pubsub');
  if (pubsub == null ||
      pubsub.getAttribute('xmlns')?.value != pepPubsubOwnerXmlns) {
    return const [];
  }
  final configure = pubsub.getChild('configure');
  if (configure == null) {
    return const [];
  }
  final form = configure.children.where(
    (c) => c.name == 'x' && c.getAttribute('xmlns')?.value == dataFormXmlns,
  );
  if (form.isEmpty) {
    return const [];
  }
  final fields = <PepNodeConfigField>[];
  for (final field in form.first.children.where((c) => c.name == 'field')) {
    final varName = field.getAttribute('var')?.value;
    if (varName == null || varName.isEmpty || varName == 'FORM_TYPE') {
      continue;
    }
    final label = field.getAttribute('label')?.value;
    final type = field.getAttribute('type')?.value;
    final values = field.children
        .where((c) => c.name == 'value')
        .map((c) => c.textValue ?? '')
        .toList(growable: false);
    fields.add(
      PepNodeConfigField(varName: varName, label: label, type: type, values: values),
    );
  }
  return fields;
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
    if (name != null && name.isNotEmpty) {
      return name;
    }
  }
  return 'error';
}
