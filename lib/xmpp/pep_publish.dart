/// Generic helpers for building private PEP (Personal Eventing Protocol)
/// pubsub publish and node-configuration stanzas.
///
/// All private PEP nodes in Wimsy use the same "whitelist" node configuration:
///   - persist_items = true
///   - access_model = whitelist
///   - send_last_published_item = never (only when the node supports it;
///     see [pubsubSendLastPublishedItemField])
///   - max_items = max
///
/// When a publish returns `<precondition-not-met/>` (XEP-0060 §7.1.3.3),
/// the server node must be reconfigured before retrying. The helper
/// [buildPrivatePepConfigureIq] produces the corrective configure IQ.
library;

import 'dart:async';

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

/// The `var` name of the `pubsub#send_last_published_item` config field.
///
/// Support for this field is OPTIONAL per a node's advertised configuration
/// form (XEP-0060 §4.3): some pubsub nodes (observed in the wild for
/// XEP-0490 MDS nodes) simply don't expose it at all. When that happens the
/// field is *unknown* to the node rather than merely mismatched, so
/// including it in `<publish-options>`/`<configure>` forms makes the server
/// reject the request with `<precondition-not-met/>` on every attempt, even
/// after reconfiguring — there's nothing to reconfigure. Callers should omit
/// this field whenever the node's own configuration form (received via a
/// `#configuration` PEP event or a `pubsub#owner get configure` request)
/// doesn't list it; see [extractNodeConfigFieldVars].
const pubsubSendLastPublishedItemField = 'pubsub#send_last_published_item';

/// Extracts the set of `var` names declared in a node-configuration data
/// form [configForm] (the `<x xmlns='jabber:x:data'>` child of a `#configuration`
/// PEP event, or of a `pubsub#owner configure` IQ result).
///
/// Used to learn which config fields a given pubsub node actually supports,
/// so callers can avoid asserting preconditions for fields the node doesn't
/// expose at all (see [pubsubSendLastPublishedItemField]).
Set<String> extractNodeConfigFieldVars(XmppElement configForm) {
  final result = <String>{};
  for (final field in configForm.children.where((c) => c.name == 'field')) {
    final varName = field.getAttribute('var')?.value;
    if (varName != null && varName.isNotEmpty) {
      result.add(varName);
    }
  }
  return result;
}

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
///
/// [supportedConfigFields], when known (see [extractNodeConfigFieldVars]),
/// is the set of `var` names the target node's own configuration form
/// advertises. When it is non-null and doesn't contain
/// [pubsubSendLastPublishedItemField], that field is omitted entirely rather
/// than asserted as a precondition the node can never satisfy. When `null`
/// (field support not yet known), the field is included optimistically, as
/// before.
XmppElement buildPrivatePepPublishOptions({
  bool serverSupportsConfigNodeMax = true,
  Set<String>? supportedConfigFields,
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
  if (supportedConfigFields == null ||
      supportedConfigFields.contains(pubsubSendLastPublishedItemField)) {
    optForm.addChild(buildFormField(pubsubSendLastPublishedItemField, 'never'));
  }
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
///
/// [supportedConfigFields], when known (see [extractNodeConfigFieldVars]),
/// is the set of `var` names the target node's own configuration form
/// advertises. When it is non-null and doesn't contain
/// [pubsubSendLastPublishedItemField], that field is omitted entirely, since
/// asserting a value for a field the node doesn't support would just trigger
/// another `precondition-not-met` loop. When `null` (field support not yet
/// known), the field is included optimistically, as before.
IqStanza buildPrivatePepConfigureIq({
  required String node,
  required String selfBareJid,
  bool serverSupportsConfigNodeMax = true,
  Set<String>? supportedConfigFields,
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
  if (supportedConfigFields == null ||
      supportedConfigFields.contains(pubsubSendLastPublishedItemField)) {
    configForm.addChild(buildFormField(pubsubSendLastPublishedItemField, 'never'));
  }
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
  Set<String>? supportedConfigFields,
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
    supportedConfigFields: supportedConfigFields,
  ));
  iqStanza.addChild(pubsub);
  return iqStanza;
}

/// Extracts the set of `var` names a node advertises from a PEP
/// `#configuration` event [stanza], if it is one for [node]; returns `null`
/// if [stanza] isn't a matching `#configuration` event, or the event's form
/// has no fields (i.e. field support for the node is still unknown).
///
/// This is a convenience wrapper around [extractNodeConfigFieldVars] for
/// callers (like [BookmarksManager]-style publishers outside
/// `xmpp_service.dart`) that only listen for events relevant to a single
/// node and don't maintain a per-node cache keyed by node name.
Set<String>? extractConfigFieldsFromConfigurationEvent(
  AbstractStanza stanza,
  String node,
) {
  if (stanza is! MessageStanza) {
    return null;
  }
  final event = stanza.children.firstWhere(
    (child) =>
        child.name == 'event' &&
        child.getAttribute('xmlns')?.value ==
            'http://jabber.org/protocol/pubsub#event',
    orElse: () => XmppElement(),
  );
  if (event.name != 'event') {
    return null;
  }
  final configuration = event.getChild('configuration');
  if (configuration == null ||
      configuration.getAttribute('node')?.value != node) {
    return null;
  }
  final configForm = configuration.getChild('x');
  if (configForm == null) {
    return null;
  }
  final fields = extractNodeConfigFieldVars(configForm);
  return fields.isEmpty ? null : fields;
}

/// Sends [stanza] via [connection] and awaits a matching response through
/// [IqRouter], resolving to `null` on timeout or if [stanza] has no `id`.
Future<IqStanza?> sendIqAndAwaitResponse(
  Connection connection,
  IqStanza stanza, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final id = stanza.id;
  if (id == null || id.isEmpty) {
    return null;
  }
  final router = IqRouter.getInstance(connection);
  final completer = Completer<IqStanza?>();
  Timer? timer;
  timer = Timer(timeout, () {
    router.unregisterResponseHandler(id);
    if (!completer.isCompleted) {
      completer.complete(null);
    }
  });
  router.registerResponseHandler(id, (response) {
    timer?.cancel();
    if (!completer.isCompleted) {
      completer.complete(response);
    }
  });
  connection.writeStanza(stanza);
  return completer.future;
}

/// Extracts the `urn:ietf:params:xml:ns:xmpp-stanzas` error condition name
/// from an error [stanza] (e.g. `'conflict'`), or `null` if none is present.
String? iqErrorCondition(IqStanza stanza) {
  final error = stanza.getChild('error');
  if (error == null) {
    return null;
  }
  for (final child in error.children) {
    if (child.getAttribute('xmlns')?.value ==
        'urn:ietf:params:xml:ns:xmpp-stanzas') {
      return child.name;
    }
  }
  return null;
}

/// Extracts the `http://jabber.org/protocol/pubsub#errors` error condition
/// name from an error [stanza] (e.g. `'precondition-not-met'`), or `null`
/// if none is present.
String? iqPubsubErrorCondition(IqStanza stanza) {
  final error = stanza.getChild('error');
  if (error == null) {
    return null;
  }
  for (final child in error.children) {
    if (child.getAttribute('xmlns')?.value ==
        'http://jabber.org/protocol/pubsub#errors') {
      return child.name;
    }
  }
  return null;
}

/// Publishes to a private PEP [node] via [publishIqBuilder] and
/// automatically recovers from a `<precondition-not-met/>` error (XEP-0060
/// §7.1.3.3) by reconfiguring the node (see [buildPrivatePepConfigureIq])
/// and retrying once - the same pattern `XmppService._doPrivatePepPublish`
/// implements, factored out here so simpler callers (that don't need its
/// in-flight-reconfigure de-duplication across concurrent publishes) can
/// reuse it instead of hand-rolling their own publish/no-retry logic.
///
/// [publishIqBuilder] is called twice (initial attempt + retry) so it must
/// produce a fresh IQ each time (with a new stanza id). It must use the same
/// `pubsub#max_items` value and [supportedConfigFields] as this call, so
/// that the retry matches the `<configure/>` IQ sent on `precondition-not-met`.
///
/// [onWarning], when provided, is invoked with a human-readable message for
/// every failure (including the final failure after a retry), mirroring
/// `XmppService._doPrivatePepPublish`'s logging.
Future<bool> publishToPrivatePepNodeWithRetry({
  required Connection connection,
  required IqStanza Function() publishIqBuilder,
  required String node,
  required String selfBareJid,
  bool serverSupportsConfigNodeMax = true,
  Set<String>? supportedConfigFields,
  void Function(String message)? onWarning,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final result = await sendIqAndAwaitResponse(
    connection,
    publishIqBuilder(),
    timeout: timeout,
  );
  if (result == null) {
    return false;
  }
  if (result.type != IqStanzaType.ERROR) {
    return true;
  }
  final condition = iqErrorCondition(result);
  final pubsubError = iqPubsubErrorCondition(result);
  if (pubsubError != 'precondition-not-met') {
    onWarning?.call('PEP publish to $node failed: $condition / $pubsubError');
    return false;
  }
  // The node exists but its configuration does not match our publish-options.
  // Reconfigure the node to the required settings, then retry once.
  onWarning?.call(
    'PEP node $node misconfigured (precondition-not-met); reconfiguring and retrying',
  );
  await sendIqAndAwaitResponse(
    connection,
    buildPrivatePepConfigureIq(
      node: node,
      selfBareJid: selfBareJid,
      serverSupportsConfigNodeMax: serverSupportsConfigNodeMax,
      supportedConfigFields: supportedConfigFields,
    ),
    timeout: timeout,
  );
  final retryResult = await sendIqAndAwaitResponse(
    connection,
    publishIqBuilder(),
    timeout: timeout,
  );
  if (retryResult != null && retryResult.type == IqStanzaType.ERROR) {
    final retryCondition = iqErrorCondition(retryResult);
    final retryPubsubError = iqPubsubErrorCondition(retryResult);
    onWarning?.call(
      'PEP publish to $node still failed after reconfiguring: '
      '$retryCondition / $retryPubsubError',
    );
    return false;
  }
  return retryResult != null;
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
  Set<String>? supportedConfigFields,
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
    supportedConfigFields: supportedConfigFields,
  );
}

/// Builds a node-configuration IQ to fix the MDS node settings.
/// This is a convenience wrapper around [buildPrivatePepConfigureIq].
IqStanza buildMdsNodeConfigureIq({
  required String selfBareJid,
  bool serverSupportsConfigNodeMax = true,
  Set<String>? supportedConfigFields,
}) =>
    buildPrivatePepConfigureIq(
      node: mdsNodeName,
      selfBareJid: selfBareJid,
      serverSupportsConfigNodeMax: serverSupportsConfigNodeMax,
      supportedConfigFields: supportedConfigFields,
    );

// ---------------------------------------------------------------------------
// Backward-compatibility aliases (previously exported from mds_publish.dart)
// ---------------------------------------------------------------------------

/// Alias for [buildPrivatePepPublishOptions].
XmppElement buildMdsPublishOptions({
  bool serverSupportsConfigNodeMax = true,
  Set<String>? supportedConfigFields,
}) =>
    buildPrivatePepPublishOptions(
      serverSupportsConfigNodeMax: serverSupportsConfigNodeMax,
      supportedConfigFields: supportedConfigFields,
    );
