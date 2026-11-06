import 'dart:async';

import 'package:omemo_dart/omemo_dart.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import '../encryption/omemo2_backend.dart';

/// XEP-0384 (OMEMO2) PEP node names.
const String omemo2DeviceListNode = 'urn:xmpp:omemo:2:devices';
const String omemo2BundlesNode = 'urn:xmpp:omemo:2:bundles';
const String omemo2Namespace = 'urn:xmpp:omemo:2';

/// Helpers for publishing/fetching the OMEMO2 (`urn:xmpp:omemo:2`) PEP
/// nodes: the per-account device list (`urn:xmpp:omemo:2:devices`) and the
/// per-device key bundles (`urn:xmpp:omemo:2:bundles`).
///
/// Modeled closely on the `IqStanza`/`pubsub`/`items` XML construction
/// pattern already used by [PepManager] (see `lib/pep/pep_manager.dart`),
/// but exposes a request/response `Future` API (as `VCardManager` does)
/// since `OmemoManager`'s callbacks (`fetchDeviceListImpl`,
/// `fetchDeviceBundleImpl`, ...) expect `Future`-returning functions.
class OmemoPep implements Omemo2PepTransport {
  OmemoPep(this.connection) {
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
        completer.completeError(StateError('OmemoPep disposed'));
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

  /// Publishes [deviceIds] (which must include our own device id) as the
  /// `urn:xmpp:omemo:2:devices` PEP item for our own bare JID.
  @override
  Future<void> publishDeviceList(List<int> deviceIds) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final publish = XmppElement()..name = 'publish';
    publish.addAttribute(XmppAttribute('node', omemo2DeviceListNode));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', 'current'));
    final devices = XmppElement()..name = 'devices';
    devices.addAttribute(XmppAttribute('xmlns', omemo2Namespace));
    for (final deviceId in deviceIds) {
      final device = XmppElement()..name = 'device';
      device.addAttribute(XmppAttribute('id', deviceId.toString()));
      devices.addChild(device);
    }
    item.addChild(devices);
    publish.addChild(item);
    pubsub.addChild(publish);
    iqStanza.addChild(pubsub);
    await _sendIqAndWait(iqStanza);
  }

  /// Fetches the `urn:xmpp:omemo:2:devices` device list for [bareJid], or
  /// `null` if it couldn't be retrieved (no PEP item, error response, ...).
  @override
  Future<List<int>?> fetchDeviceList(String bareJid) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(bareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', omemo2DeviceListNode));
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    final result = await _sendIqAndWait(iqStanza);
    if (result.type != IqStanzaType.RESULT) {
      return null;
    }
    final resultPubsub = result.getChild('pubsub');
    final resultItems = resultPubsub?.getChild('items');
    final item = resultItems?.getChild('item');
    final devicesElement = item?.getChild('devices');
    if (devicesElement == null) {
      return null;
    }
    return devicesElement.children
        .where((child) => child.name == 'device')
        .map((child) => int.tryParse(child.getAttribute('id')?.value ?? ''))
        .whereType<int>()
        .toList();
  }

  /// Subscribes to [bareJid]'s `urn:xmpp:omemo:2:devices` PEP node so we
  /// are notified of device list changes via PEP `<event/>` messages.
  @override
  void subscribeToDeviceList(String bareJid) {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    iqStanza.toJid = Jid.fromFullJid(bareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final subscribe = XmppElement()..name = 'subscribe';
    subscribe.addAttribute(XmppAttribute('node', omemo2DeviceListNode));
    subscribe.addAttribute(
      XmppAttribute('jid', connection.fullJid.userAtDomain),
    );
    pubsub.addChild(subscribe);
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
  }

  /// Publishes [bundle] (our own device's key bundle) to the
  /// `urn:xmpp:omemo:2:bundles` PEP node, using the device id as the item
  /// id, per XEP-0384.
  @override
  Future<void> publishBundle(OmemoBundle bundle) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final publish = XmppElement()..name = 'publish';
    publish.addAttribute(XmppAttribute('node', omemo2BundlesNode));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', bundle.id.toString()));
    item.addChild(_bundleToElement(bundle));
    publish.addChild(item);
    pubsub.addChild(publish);
    iqStanza.addChild(pubsub);
    await _sendIqAndWait(iqStanza);
  }

  /// Fetches the key bundle for [deviceId] of [bareJid] from the
  /// `urn:xmpp:omemo:2:bundles` PEP node, or `null` if unavailable.
  @override
  Future<OmemoBundle?> fetchBundle(String bareJid, int deviceId) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(bareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', omemo2BundlesNode));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', deviceId.toString()));
    items.addChild(item);
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    final result = await _sendIqAndWait(iqStanza);
    if (result.type != IqStanzaType.RESULT) {
      return null;
    }
    final resultPubsub = result.getChild('pubsub');
    final resultItems = resultPubsub?.getChild('items');
    final resultItem = resultItems?.getChild('item');
    final bundleElement = resultItem?.getChild('bundle');
    if (bundleElement == null) {
      return null;
    }
    return _bundleFromElement(bareJid, deviceId, bundleElement);
  }

  XmppElement _bundleToElement(OmemoBundle bundle) {
    final bundleElement = XmppElement()..name = 'bundle';
    bundleElement.addAttribute(XmppAttribute('xmlns', omemo2Namespace));

    final spk = XmppElement()..name = 'spk';
    spk.addAttribute(XmppAttribute('id', bundle.spkId.toString()));
    spk.textValue = bundle.spkEncoded;
    bundleElement.addChild(spk);

    final spks = XmppElement()..name = 'spks';
    spks.textValue = bundle.spkSignatureEncoded;
    bundleElement.addChild(spks);

    final ik = XmppElement()..name = 'ik';
    ik.textValue = bundle.ikEncoded;
    bundleElement.addChild(ik);

    final prekeys = XmppElement()..name = 'prekeys';
    bundle.opksEncoded.forEach((opkId, opkEncoded) {
      final pk = XmppElement()..name = 'pk';
      pk.addAttribute(XmppAttribute('id', opkId.toString()));
      pk.textValue = opkEncoded;
      prekeys.addChild(pk);
    });
    bundleElement.addChild(prekeys);

    return bundleElement;
  }

  OmemoBundle? _bundleFromElement(
    String bareJid,
    int deviceId,
    XmppElement bundleElement,
  ) {
    final spkElement = bundleElement.getChild('spk');
    final spksElement = bundleElement.getChild('spks');
    final ikElement = bundleElement.getChild('ik');
    final prekeysElement = bundleElement.getChild('prekeys');
    if (spkElement == null || spksElement == null || ikElement == null) {
      return null;
    }
    final spkId = int.tryParse(spkElement.getAttribute('id')?.value ?? '');
    final spkEncoded = spkElement.textValue?.trim();
    final spkSignatureEncoded = spksElement.textValue?.trim();
    final ikEncoded = ikElement.textValue?.trim();
    if (spkId == null ||
        spkEncoded == null ||
        spkEncoded.isEmpty ||
        spkSignatureEncoded == null ||
        spkSignatureEncoded.isEmpty ||
        ikEncoded == null ||
        ikEncoded.isEmpty) {
      return null;
    }
    final opksEncoded = <int, String>{};
    if (prekeysElement != null) {
      for (final pk in prekeysElement.children.where((c) => c.name == 'pk')) {
        final opkId = int.tryParse(pk.getAttribute('id')?.value ?? '');
        final opkEncoded = pk.textValue?.trim();
        if (opkId != null && opkEncoded != null && opkEncoded.isNotEmpty) {
          opksEncoded[opkId] = opkEncoded;
        }
      }
    }
    return OmemoBundle(
      bareJid,
      deviceId,
      spkEncoded,
      spkId,
      spkSignatureEncoded,
      ikEncoded,
      opksEncoded,
    );
  }
}
