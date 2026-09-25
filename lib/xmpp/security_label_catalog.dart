import 'package:xmpp_stone/xmpp_stone.dart';

import 'message_intent_builder.dart';
import 'message_stanza_parser.dart';

/// XEP-0258-extension namespace used by the Spiffing Openfire plugin's
/// `CatalogIqHandler` to list the security labels a user is allowed to
/// attach to outgoing messages. Only requests from local entities are
/// served, so this is only ever queried against the user's own server.
///
/// Note: the server also supports an optional `to="<recipient bare
/// jid>"` attribute on the request that additionally filters the
/// catalogue by the recipient's clearance. Wimsy does not currently send
/// that attribute - it fetches the catalogue once per session (on
/// connect), not per-chat, so the returned entries are not filtered by
/// peer clearance. See `doap.xml` for this documented limitation.
const String securityLabelCatalogNamespace = 'urn:xmpp:sec-label:catalog:2';

/// A single entry from a `<catalog/>` listing response: an optional
/// `selector` (a short machine name for the label, e.g. shown in a menu),
/// whether the server marked it as the `default` choice, the label's
/// human-readable display info (see [SecurityLabelInfo]), and the raw
/// `<securitylabel/>` element itself so it can be re-attached verbatim to
/// an outgoing message when the user picks this entry.
class SecurityLabelCatalogEntry {
  const SecurityLabelCatalogEntry({
    required this.selector,
    required this.isDefault,
    required this.info,
    required this.securityLabelElement,
  });

  final String? selector;
  final bool isDefault;
  final SecurityLabelInfo info;
  final XmppElement securityLabelElement;
}

/// Parses a `<catalog/>` listing response into its `<item/>` entries.
/// Items missing a usable `<securitylabel/>` child (absent, or one that
/// fails to yield any display info at all - e.g. bad ESS payload with no
/// `<displaymarking/>` fallback either) are silently skipped rather than
/// failing the whole parse.
List<SecurityLabelCatalogEntry> parseSecurityLabelCatalog(IqStanza stanza) {
  if (stanza.type != IqStanzaType.RESULT) {
    return const [];
  }
  final catalog = _catalogElement(stanza);
  if (catalog == null) {
    return const [];
  }
  final entries = <SecurityLabelCatalogEntry>[];
  for (final item in catalog.children.where((child) => child.name == 'item')) {
    final securityLabel = item.children.firstWhere(
      (child) =>
          child.name == 'securitylabel' &&
          child.getAttribute('xmlns')?.value == 'urn:xmpp:sec-label:0',
      orElse: () => XmppElement(),
    );
    if (securityLabel.name != 'securitylabel') {
      continue;
    }
    final info = parseSecurityLabelElement(securityLabel);
    if (info == null) {
      continue;
    }
    final selector = item.getAttribute('selector')?.value?.trim();
    final isDefault = item.getAttribute('default')?.value?.trim() == 'true';
    entries.add(
      SecurityLabelCatalogEntry(
        selector: (selector == null || selector.isEmpty) ? null : selector,
        isDefault: isDefault,
        info: info,
        securityLabelElement: securityLabel,
      ),
    );
  }
  return entries;
}

XmppElement? _catalogElement(IqStanza stanza) {
  final catalog = stanza.children.firstWhere(
    (child) =>
        child.name == 'catalog' &&
        child.getAttribute('xmlns')?.value == securityLabelCatalogNamespace,
    orElse: () => XmppElement(),
  );
  return catalog.name == 'catalog' ? catalog : null;
}
