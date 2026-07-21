/// Helpers for building MDS (XEP-0490 Message Displayed Synchronization)
/// pubsub publish and node-configuration stanzas.
library;

import 'package:xmpp_stone/xmpp_stone.dart';

const _mdsNodeName = 'urn:xmpp:mds:displayed:0';
const _pubsubXmlns = 'http://jabber.org/protocol/pubsub';
const _pubsubOwnerXmlns = 'http://jabber.org/protocol/pubsub#owner';
const _pubsubPublishOptionsFormType =
    'http://jabber.org/protocol/pubsub#publish-options';
const _pubsubMetaDataFormType = 'http://jabber.org/protocol/pubsub#meta-data';

/// Builds a data-form field element.
XmppElement buildFormField(String varName, String value, {String? type}) {
  final f = XmppElement()..name = 'field';
  f.addAttribute(XmppAttribute('var', varName));
  if (type != null) f.addAttribute(XmppAttribute('type', type));
  final v = XmppElement()..name = 'value';
  v.textValue = value;
  f.addChild(v);
  return f;
}

/// Builds the `<publish-options>` data form that must match the MDS node
/// configuration (XEP-0490 §4).
XmppElement buildMdsPublishOptions() {
  final publishOptions = XmppElement()..name = 'publish-options';
  final optForm = XmppElement()..name = 'x';
  optForm.addAttribute(XmppAttribute('xmlns', 'jabber:x:data'));
  optForm.addAttribute(XmppAttribute('type', 'submit'));
  optForm.addChild(buildFormField(
    'FORM_TYPE',
    _pubsubPublishOptionsFormType,
    type: 'hidden',
  ));
  optForm.addChild(buildFormField('pubsub#persist_items', 'true'));
  optForm.addChild(buildFormField('pubsub#access_model', 'whitelist'));
  optForm.addChild(buildFormField('pubsub#send_last_published_item', 'never'));
  optForm.addChild(buildFormField('pubsub#max_items', 'max'));
  publishOptions.addChild(optForm);
  return publishOptions;
}

/// Builds the IQ stanza that publishes an MDS displayed marker for [chatJid]
/// with the given [stanzaId].  [byValue] is the 'by' attribute on the
/// `<stanza-id>` element (the bare JID of the chat for rooms, or the user's
/// own bare JID for 1:1 chats).
IqStanza buildMdsPublishIq({
  required String chatJid,
  required String stanzaId,
  required String byValue,
  required String selfBareJid,
}) {
  final id = AbstractStanza.getRandomId();
  final iqStanza = IqStanza(id, IqStanzaType.SET);
  iqStanza.toJid = Jid.fromFullJid(selfBareJid);
  final pubsub = XmppElement()..name = 'pubsub';
  pubsub.addAttribute(XmppAttribute('xmlns', _pubsubXmlns));
  final publish = XmppElement()..name = 'publish';
  publish.addAttribute(XmppAttribute('node', _mdsNodeName));
  final item = XmppElement()..name = 'item';
  item.addAttribute(XmppAttribute('id', chatJid));
  final displayed = XmppElement()..name = 'displayed';
  displayed.addAttribute(XmppAttribute('xmlns', _mdsNodeName));
  final stanzaIdElement = XmppElement()..name = 'stanza-id';
  stanzaIdElement.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sid:0'));
  stanzaIdElement.addAttribute(XmppAttribute('id', stanzaId));
  if (byValue.isNotEmpty) {
    stanzaIdElement.addAttribute(XmppAttribute('by', byValue));
  }
  displayed.addChild(stanzaIdElement);
  item.addChild(displayed);
  publish.addChild(item);
  pubsub.addChild(publish);
  // publish-options: set max_items=max so the server retains one item per
  // chat JID rather than overwriting a single global item (XEP-0490 §4).
  pubsub.addChild(buildMdsPublishOptions());
  iqStanza.addChild(pubsub);
  return iqStanza;
}

/// Builds a pubsub node-configuration IQ to fix the MDS node settings.
/// Called when the server responds with `<precondition-not-met/>` (XEP-0060
/// §7.1.3.3), meaning the node exists but its configuration doesn't match our
/// `<publish-options>`.
IqStanza buildMdsNodeConfigureIq({required String selfBareJid}) {
  final id = AbstractStanza.getRandomId();
  final iq = IqStanza(id, IqStanzaType.SET);
  iq.toJid = Jid.fromFullJid(selfBareJid);
  final pubsub = XmppElement()..name = 'pubsub';
  pubsub.addAttribute(XmppAttribute('xmlns', _pubsubOwnerXmlns));
  final configure = XmppElement()..name = 'configure';
  configure.addAttribute(XmppAttribute('node', _mdsNodeName));
  final configForm = XmppElement()..name = 'x';
  configForm.addAttribute(XmppAttribute('xmlns', 'jabber:x:data'));
  configForm.addAttribute(XmppAttribute('type', 'submit'));
  configForm.addChild(buildFormField(
    'FORM_TYPE',
    _pubsubMetaDataFormType,
    type: 'hidden',
  ));
  configForm.addChild(buildFormField('pubsub#persist_items', 'true'));
  configForm.addChild(buildFormField('pubsub#access_model', 'whitelist'));
  configForm.addChild(
      buildFormField('pubsub#send_last_published_item', 'never'));
  configForm.addChild(buildFormField('pubsub#max_items', 'max'));
  configure.addChild(configForm);
  pubsub.addChild(configure);
  iq.addChild(pubsub);
  return iq;
}
