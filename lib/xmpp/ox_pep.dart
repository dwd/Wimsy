import 'dart:async';

import 'package:xmpp_stone/xmpp_stone.dart';

import '../encryption/ox_backend.dart' show OxPepTransport;

/// `urn:xmpp:openpgp:0` (XEP-0373 "OpenPGP for XMPP") namespace.
const String oxNamespace = 'urn:xmpp:openpgp:0';

/// PEP node holding the metadata (list of known fingerprints) for our own
/// account, per XEP-0373 §4.2.
const String oxMetadataNode = 'urn:xmpp:openpgp:0:metadata';

/// PEP node (per-fingerprint) holding an armored OpenPGP public key, per
/// XEP-0373 §4.1. The node name is suffixed with the key's hex fingerprint.
String oxPublicKeyNode(String fingerprint) =>
    'urn:xmpp:openpgp:0:public-keys:$fingerprint';

/// Helpers for publishing/fetching the XEP-0373 (OX) PEP nodes: the
/// per-account metadata node (list of fingerprints) and the per-fingerprint
/// public-key nodes.
///
/// Modeled closely on [OmemoPep] (see `lib/xmpp/omemo_pep.dart`) and the
/// `IqStanza`/`pubsub`/`items` XML construction pattern used throughout
/// `lib/pep/pep_manager.dart`.
class OxPep implements OxPepTransport {
  OxPep(this.connection) {
    _subscription = connection.inStanzasStream.listen(_handleStanza);
  }

  final Connection connection;
  StreamSubscription<AbstractStanza?>? _subscription;

  final Map<String, Completer<IqStanza>> _pendingIqs = {};

  /// Stops listening to incoming stanzas. Should be called when the owning
  /// backend/connection is torn down.
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    for (final completer in _pendingIqs.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('OxPep disposed'));
      }
    }
    _pendingIqs.clear();
  }

  void _handleStanza(AbstractStanza? stanza) {
    if (stanza is! IqStanza) {
      return;
    }
    final completer = _pendingIqs.remove(stanza.id);
    completer?.complete(stanza);
  }

  Future<IqStanza> _sendIqAndWait(IqStanza iqStanza) {
    final completer = Completer<IqStanza>();
    _pendingIqs[iqStanza.id!] = completer;
    connection.writeStanza(iqStanza);
    return completer.future;
  }

  @override
  Future<void> publishMetadata(String fingerprint) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final publish = XmppElement()..name = 'publish';
    publish.addAttribute(XmppAttribute('node', oxMetadataNode));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', 'current'));
    final metadata = XmppElement()..name = 'metadata';
    metadata.addAttribute(XmppAttribute('xmlns', oxNamespace));
    final key = XmppElement()..name = 'key';
    key.addAttribute(XmppAttribute('id', fingerprint));
    metadata.addChild(key);
    item.addChild(metadata);
    publish.addChild(item);
    pubsub.addChild(publish);
    iqStanza.addChild(pubsub);
    await _sendIqAndWait(iqStanza);
  }

  @override
  Future<List<String>?> fetchMetadata(String bareJid) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(bareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', oxMetadataNode));
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    final result = await _sendIqAndWait(iqStanza);
    if (result.type != IqStanzaType.RESULT) {
      return null;
    }
    final resultPubsub = result.getChild('pubsub');
    final resultItems = resultPubsub?.getChild('items');
    final item = resultItems?.getChild('item');
    final metadataElement = item?.getChild('metadata');
    if (metadataElement == null) {
      return null;
    }
    return metadataElement.children
        .where((child) => child.name == 'key')
        .map((child) => child.getAttribute('id')?.value)
        .whereType<String>()
        .toList();
  }

  @override
  Future<void> publishPublicKey(
    String fingerprint,
    String base64PublicKey,
  ) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final publish = XmppElement()..name = 'publish';
    publish.addAttribute(XmppAttribute('node', oxPublicKeyNode(fingerprint)));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', 'current'));
    final pubkey = XmppElement()..name = 'pubkey';
    pubkey.addAttribute(XmppAttribute('xmlns', oxNamespace));
    final data = XmppElement()..name = 'data';
    data.textValue = base64PublicKey;
    pubkey.addChild(data);
    item.addChild(pubkey);
    publish.addChild(item);
    pubsub.addChild(publish);
    iqStanza.addChild(pubsub);
    await _sendIqAndWait(iqStanza);
  }

  @override
  Future<String?> fetchPublicKey(String bareJid, String fingerprint) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(bareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', oxPublicKeyNode(fingerprint)));
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    final result = await _sendIqAndWait(iqStanza);
    if (result.type != IqStanzaType.RESULT) {
      return null;
    }
    final resultPubsub = result.getChild('pubsub');
    final resultItems = resultPubsub?.getChild('items');
    final resultItem = resultItems?.getChild('item');
    final pubkeyElement = resultItem?.getChild('pubkey');
    final dataElement = pubkeyElement?.getChild('data');
    return dataElement?.textValue?.trim();
  }
}
