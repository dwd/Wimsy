/// Generic helpers for building private PEP (Personal Eventing Protocol)
/// pubsub publish and node-configuration stanzas.
///
/// All private PEP nodes in Wimsy use the same "whitelist" node configuration:
///   - persist_items = true
///   - access_model = whitelist
///   - send_last_published_item = never
///   - max_items = max
///
/// When a publish returns `<precondition-not-met/>` (XEP-0060 §7.1.3.3),
/// the server node must be reconfigured before retrying. The helper
/// [buildPrivatePepConfigureIq] produces the corrective configure IQ.
library;

import 'package:xmpp_stone/xmpp_stone.dart';

const pubsubXmlns = 'http://jabber.org/protocol/pubsub';
const pubsubOwnerXmlns = 'http://jabber.org/protocol/pubsub#owner';
const pubsubPublishOptionsFormType =
    'http://jabber.org/protocol/pubsub#publish-options';
const pubsubNodeConfigFormType = 'http://jabber.org/protocol/pubsub#node_config';

/// The disco#info feature a pubsub service advertises (XEP-0060 Registrar)
/// when it honors the literal string `"max"` as a value for
/// `pubsub#max_items`, `pubsub#item_expire` and `pubsub#children_max`.
///
/// Support for `max` is OPTIONAL in XEP-0060: a server that doesn't
/// advertise this feature may reject or silently clamp a `max_items = max`
/// request, which causes reconfiguration/publish-options preconditions to
/// loop forever. Callers should check for this feature (e.g. via
/// `connection.getSupportedFeatures()`) before assuming `max` will work.
const pubsubConfigNodeMaxFeature =
    'http://jabber.org/protocol/pubsub#config-node-max';

/// Fallback value used for `pubsub#max_items` when the server does not
/// advertise [pubsubConfigNodeMaxFeature]. A generously high, but finite,
/// number so nodes like MDS and bookmarks effectively never lose items on
/// servers that don't support the `max` keyword.
const pubsubMaxItemsFallback = '50';

/// Resolves the value to use for `pubsub#max_items` (and similarly-typed
/// fields) based on whether the server advertises [pubsubConfigNodeMaxFeature].
String resolveMaxItemsValue({required bool serverSupportsConfigNodeMax}) =>
    serverSupportsConfigNodeMax ? 'max' : pubsubMaxItemsFallback;

/// Builds a data-form `<field>` element with [varName] and [value].
/// Optionally sets a [type] attribute (e.g. `'hidden'`).
XmppElement buildFormField(String varName, String value, {String? type}) {
  final f = XmppElement()..name = 'field';
  f.addAttribute(XmppAttribute('var', varName));
  if (type != null) f.addAttribute(XmppAttribute('type', type));
  final v = XmppElement()..name = 'value';
  v.textValue = value;
  f.addChild(v);
  return f;
}

/// Builds the standard `<publish-options>` data form for a private PEP node.
///
/// The resulting form sets:
///   - `FORM_TYPE` → `http://jabber.org/protocol/pubsub#publish-options`
///   - `pubsub#persist_items` → `true`
///   - `pubsub#access_model` → `whitelist`
///   - `pubsub#send_last_published_item` → `never`
///   - `pubsub#max_items` → `max` when [serverSupportsConfigNodeMax] is true,
///     otherwise [pubsubMaxItemsFallback] (see [resolveMaxItemsValue]).
///
/// [serverSupportsConfigNodeMax] should reflect whether the target server
/// advertises [pubsubConfigNodeMaxFeature] via disco#info; it defaults to
/// `true` so callers that haven't performed the discovery check yet keep the
/// previous optimistic behavior.
XmppElement buildPrivatePepPublishOptions({
  bool serverSupportsConfigNodeMax = true,
}) {
  final publishOptions = XmppElement()..name = 'publish-options';
  final optForm = XmppElement()..name = 'x';
  optForm.addAttribute(XmppAttribute('xmlns', 'jabber:x:data'));
  optForm.addAttribute(XmppAttribute('type', 'submit'));
  optForm.addChild(buildFormField(
    'FORM_TYPE',
    pubsubPublishOptionsFormType,
    type: 'hidden',
  ));
  optForm.addChild(buildFormField('pubsub#persist_items', 'true'));
  optForm.addChild(buildFormField('pubsub#access_model', 'whitelist'));
  optForm.addChild(buildFormField('pubsub#send_last_published_item', 'never'));
  optForm.addChild(buildFormField(
    'pubsub#max_items',
    resolveMaxItemsValue(serverSupportsConfigNodeMax: serverSupportsConfigNodeMax),
  ));
  publishOptions.addChild(optForm);
  return publishOptions;
}

/// Builds a pubsub `owner` configure IQ that sets a private PEP [node] to the
/// standard whitelist configuration.
///
/// Called when the server responds with `<precondition-not-met/>` (XEP-0060
/// §7.1.3.3), meaning the node's current configuration doesn't match the
/// `<publish-options>` we sent. After calling this, retry the original publish.
IqStanza buildPrivatePepConfigureIq({
  required String node,
  required String selfBareJid,
  bool serverSupportsConfigNodeMax = true,
}) {
  final id = AbstractStanza.getRandomId();
  final iq = IqStanza(id, IqStanzaType.SET);
  iq.toJid = Jid.fromFullJid(selfBareJid);
  final pubsub = XmppElement()..name = 'pubsub';
  pubsub.addAttribute(XmppAttribute('xmlns', pubsubOwnerXmlns));
  final configure = XmppElement()..name = 'configure';
  configure.addAttribute(XmppAttribute('node', node));
  final configForm = XmppElement()..name = 'x';
  configForm.addAttribute(XmppAttribute('xmlns', 'jabber:x:data'));
  configForm.addAttribute(XmppAttribute('type', 'submit'));
  configForm.addChild(buildFormField(
    'FORM_TYPE',
    pubsubNodeConfigFormType,
    type: 'hidden',
  ));
  configForm.addChild(buildFormField('pubsub#persist_items', 'true'));
  configForm.addChild(buildFormField('pubsub#access_model', 'whitelist'));
  configForm.addChild(buildFormField('pubsub#send_last_published_item', 'never'));
  configForm.addChild(buildFormField(
    'pubsub#max_items',
    resolveMaxItemsValue(serverSupportsConfigNodeMax: serverSupportsConfigNodeMax),
  ));
  configure.addChild(configForm);
  pubsub.addChild(configure);
  iq.addChild(pubsub);
  return iq;
}

/// Builds a generic pubsub publish IQ for a private PEP [node] addressed to
/// [selfBareJid]. The [itemId] becomes the `id` attribute of the `<item>`
/// element, and [payload] is added as the item's content.
///
/// The resulting IQ includes the standard private PEP `<publish-options>`.
IqStanza buildPrivatePepPublishIq({
  required String node,
  required String itemId,
  required XmppElement payload,
  required String selfBareJid,
  bool serverSupportsConfigNodeMax = true,
}) {
  final id = AbstractStanza.getRandomId();
  final iqStanza = IqStanza(id, IqStanzaType.SET);
  iqStanza.toJid = Jid.fromFullJid(selfBareJid);
  final pubsub = XmppElement()..name = 'pubsub';
  pubsub.addAttribute(XmppAttribute('xmlns', pubsubXmlns));
  final publish = XmppElement()..name = 'publish';
  publish.addAttribute(XmppAttribute('node', node));
  final item = XmppElement()..name = 'item';
  item.addAttribute(XmppAttribute('id', itemId));
  item.addChild(payload);
  publish.addChild(item);
  pubsub.addChild(publish);
  pubsub.addChild(buildPrivatePepPublishOptions(
    serverSupportsConfigNodeMax: serverSupportsConfigNodeMax,
  ));
  iqStanza.addChild(pubsub);
  return iqStanza;
}

// ---------------------------------------------------------------------------
// MDS-specific helpers (XEP-0490 Message Displayed Synchronization)
// ---------------------------------------------------------------------------

const mdsNodeName = 'urn:xmpp:mds:displayed:0';

/// Builds the IQ stanza that publishes an MDS displayed marker for [chatJid]
/// with the given [stanzaId].  [byValue] is the `by` attribute on the
/// `<stanza-id>` element (the bare JID of the chat for rooms, or the user's
/// own bare JID for 1:1 chats).
IqStanza buildMdsPublishIq({
  required String chatJid,
  required String stanzaId,
  required String byValue,
  required String selfBareJid,
  bool serverSupportsConfigNodeMax = true,
}) {
  final displayed = XmppElement()..name = 'displayed';
  displayed.addAttribute(XmppAttribute('xmlns', mdsNodeName));
  final stanzaIdElement = XmppElement()..name = 'stanza-id';
  stanzaIdElement.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sid:0'));
  stanzaIdElement.addAttribute(XmppAttribute('id', stanzaId));
  if (byValue.isNotEmpty) {
    stanzaIdElement.addAttribute(XmppAttribute('by', byValue));
  }
  displayed.addChild(stanzaIdElement);
  return buildPrivatePepPublishIq(
    node: mdsNodeName,
    itemId: chatJid,
    payload: displayed,
    selfBareJid: selfBareJid,
    serverSupportsConfigNodeMax: serverSupportsConfigNodeMax,
  );
}

/// Builds a node-configuration IQ to fix the MDS node settings.
/// This is a convenience wrapper around [buildPrivatePepConfigureIq].
IqStanza buildMdsNodeConfigureIq({
  required String selfBareJid,
  bool serverSupportsConfigNodeMax = true,
}) =>
    buildPrivatePepConfigureIq(
      node: mdsNodeName,
      selfBareJid: selfBareJid,
      serverSupportsConfigNodeMax: serverSupportsConfigNodeMax,
    );

// ---------------------------------------------------------------------------
// Backward-compatibility aliases (previously exported from mds_publish.dart)
// ---------------------------------------------------------------------------

/// Alias for [buildPrivatePepPublishOptions].
XmppElement buildMdsPublishOptions({bool serverSupportsConfigNodeMax = true}) =>
    buildPrivatePepPublishOptions(
      serverSupportsConfigNodeMax: serverSupportsConfigNodeMax,
    );
