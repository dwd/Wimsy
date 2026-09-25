import 'package:xmpp_stone/xmpp_stone.dart';

/// XEP-0258-extension namespace used by the Spiffing Openfire plugin's
/// `PolicyIqHandler` to list and fetch the SPIF (Security Policy
/// Information File) documents currently loaded on the server. Only
/// requests from local entities are served, so this is only ever queried
/// against the user's own server.
const String securityLabelPolicyNamespace = 'urn:xmpp:sec-label:policy:0';

/// A single entry from a `<policy/>` listing response: the id and
/// human-readable name of one loaded SPIF, in server-defined (primary
/// policy first) order.
class SecurityLabelPolicyRef {
  const SecurityLabelPolicyRef({required this.id, required this.name});

  final String id;
  final String name;
}

/// Parses a `<policy/>` listing response (a request with neither an `id`
/// nor a `name` attribute) into its `<item id="..." name="..."/>` entries.
List<SecurityLabelPolicyRef> parseSecurityLabelPolicyList(IqStanza stanza) {
  if (stanza.type != IqStanzaType.RESULT) {
    return const [];
  }
  final policy = _policyElement(stanza);
  if (policy == null) {
    return const [];
  }
  final refs = <SecurityLabelPolicyRef>[];
  for (final item in policy.children.where((child) => child.name == 'item')) {
    final id = item.getAttribute('id')?.value?.trim() ?? '';
    final name = item.getAttribute('name')?.value?.trim() ?? '';
    if (id.isNotEmpty) {
      refs.add(SecurityLabelPolicyRef(id: id, name: name));
    }
  }
  return refs;
}

/// Parses a `<policy/>` document response (a request naming a specific
/// policy via an `id` or `name` attribute) and returns the raw `<SPIF/>`
/// XML text, suitable for `spiffing`'s `Spif.fromXml`, or null if the
/// response doesn't carry one.
String? parseSecurityLabelPolicyDocument(IqStanza stanza) {
  if (stanza.type != IqStanzaType.RESULT) {
    return null;
  }
  final policy = _policyElement(stanza);
  if (policy == null) {
    return null;
  }
  final spif = policy.children.firstWhere(
    (child) => child.name == 'SPIF',
    orElse: () => XmppElement(),
  );
  if (spif.name != 'SPIF') {
    return null;
  }
  return spif.buildXmlString();
}

XmppElement? _policyElement(IqStanza stanza) {
  final policy = stanza.children.firstWhere(
    (child) =>
        child.name == 'policy' &&
        child.getAttribute('xmlns')?.value == securityLabelPolicyNamespace,
    orElse: () => XmppElement(),
  );
  return policy.name == 'policy' ? policy : null;
}
