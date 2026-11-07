import 'dart:async';
import 'dart:convert';

import 'package:omemo_dart/omemo_dart.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import '../encryption/omemo2_backend.dart';
import '../encryption/omemo_backend.dart' show OmemoPepTransport;
import 'pep_publish.dart'
    show buildOpenPepConfigureIq, buildOpenPepPublishOptions, iqPubsubErrorCondition;

/// XEP-0384 (OMEMO2) PEP node names.
const String omemo2DeviceListNode = 'urn:xmpp:omemo:2:devices';
const String omemo2BundlesNode = 'urn:xmpp:omemo:2:bundles';
const String omemo2Namespace = 'urn:xmpp:omemo:2';

/// Legacy OMEMO (XEP-0384 v0.3.0, `eu.siacs.conversations.axolotl`) PEP
/// node names, matching the naming convention used by real-world
/// implementations such as Conversations/Gajim/Dino: a single
/// `eu.siacs.conversations.axolotl.devicelist` node for the device list,
/// and a `eu.siacs.conversations.axolotl.bundles:<deviceid>` node per
/// device bundle.
const String legacyOmemoNamespace = 'eu.siacs.conversations.axolotl';
const String legacyOmemoDeviceListNode =
    'eu.siacs.conversations.axolotl.devicelist';
String legacyOmemoBundlesNode(int deviceId) =>
    'eu.siacs.conversations.axolotl.bundles:$deviceId';

/// Helpers for publishing/fetching the OMEMO2 (`urn:xmpp:omemo:2`) PEP
/// nodes: the per-account device list (`urn:xmpp:omemo:2:devices`) and the
/// per-device key bundles (`urn:xmpp:omemo:2:bundles`).
///
/// Also implements [OmemoPepTransport] for legacy OMEMO
/// (`eu.siacs.conversations.axolotl`, see
/// `lib/encryption/omemo_backend.dart`), sharing the same
/// IQ/pubsub plumbing parameterized by namespace/node-name, since both
/// protocols use the same PEP-based publish/fetch/subscribe shape and
/// only differ in node names and the inner `<devices/>`/`<bundle/>`
/// element's `xmlns` and (for legacy bundles) per-device node naming.
///
/// Modeled closely on the `IqStanza`/`pubsub`/`items` XML construction
/// pattern already used by [PepManager] (see `lib/pep/pep_manager.dart`),
/// but exposes a request/response `Future` API (as `VCardManager` does)
/// since `OmemoManager`'s callbacks (`fetchDeviceListImpl`,
/// `fetchDeviceBundleImpl`, ...) expect `Future`-returning functions.
class OmemoPep implements Omemo2PepTransport, OmemoPepTransport {
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

  /// Publishes [item] to [node] with `<publish-options>` asserting
  /// `pubsub#access_model = open` (see [buildOpenPepPublishOptions]).
  ///
  /// XEP-0384's OMEMO/OMEMO2 device-list and bundle nodes must be readable
  /// by any contact without a prior subscription or whitelist entry --
  /// that's exactly the scenario in which a session is first established
  /// with someone. Without forcing `open` here, these nodes end up with
  /// whatever access model the server happens to default newly
  /// auto-created PEP nodes to, which is implementation-defined per
  /// XEP-0060 §7.1.4 and may be as restrictive as `whitelist` -- silently
  /// making our device list/bundles unreadable to everyone.
  ///
  /// If the node already exists with a different access model, the
  /// server replies `<precondition-not-met/>` (XEP-0060 §7.1.3.3); in
  /// that case we explicitly reconfigure the node to `open` via a
  /// `pubsub#owner` `<configure/>` IQ and retry the publish once, the
  /// same recovery pattern used for whitelist nodes elsewhere (see
  /// `lib/xmpp/pep_publish.dart`'s `publishToPrivatePepNodeWithRetry`).
  Future<void> _publishWithOpenAccess({
    required String node,
    required XmppElement Function() buildItem,
  }) async {
    final result = await _sendIqAndWait(
      _buildOpenPublishIq(node: node, item: buildItem()),
    );
    if (result.type != IqStanzaType.RESULT &&
        iqPubsubErrorCondition(result) == 'precondition-not-met') {
      await _sendIqAndWait(
        buildOpenPepConfigureIq(
          node: node,
          selfBareJid: connection.fullJid.userAtDomain,
        ),
      );
      await _sendIqAndWait(
        _buildOpenPublishIq(node: node, item: buildItem()),
      );
    }
  }

  IqStanza _buildOpenPublishIq({
    required String node,
    required XmppElement item,
  }) {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final publish = XmppElement()..name = 'publish';
    publish.addAttribute(XmppAttribute('node', node));
    publish.addChild(item);
    pubsub.addChild(publish);
    pubsub.addChild(buildOpenPepPublishOptions());
    iqStanza.addChild(pubsub);
    return iqStanza;
  }

  /// Publishes [deviceIds] (which must include our own device id) as the
  /// `urn:xmpp:omemo:2:devices` PEP item for our own bare JID.
  ///
  /// Forces the node's `pubsub#access_model` to `open` (see
  /// [_publishWithOpenAccess]), since contacts must be able to fetch our
  /// device list without a prior subscription/whitelist entry.
  @override
  Future<void> publishDeviceList(List<int> deviceIds) async {
    await _publishWithOpenAccess(
      node: omemo2DeviceListNode,
      buildItem: () {
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
        return item;
      },
    );
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
  ///
  /// Forces the node's `pubsub#access_model` to `open` (see
  /// [_publishWithOpenAccess]), since contacts must be able to fetch our
  /// bundle without a prior subscription/whitelist entry.
  @override
  Future<void> publishBundle(OmemoBundle bundle) async {
    await _publishWithOpenAccess(
      node: omemo2BundlesNode,
      buildItem: () {
        final item = XmppElement()..name = 'item';
        item.addAttribute(XmppAttribute('id', bundle.id.toString()));
        item.addChild(_bundleToElement(bundle));
        return item;
      },
    );
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

  // -------------------------------------------------------------------
  // Legacy OMEMO (eu.siacs.conversations.axolotl, XEP-0384 v0.3.0).
  //
  // Same IQ/pubsub shape as the OMEMO2 methods above, but using the
  // legacy node names/namespace (see [legacyOmemoNamespace]).
  // -------------------------------------------------------------------

  /// Publishes [deviceIds] as the legacy OMEMO device list. Forces the
  /// node's `pubsub#access_model` to `open` (see [_publishWithOpenAccess]),
  /// since contacts must be able to fetch our device list without a prior
  /// subscription/whitelist entry.
  @override
  Future<void> publishLegacyDeviceList(List<int> deviceIds) async {
    await _publishWithOpenAccess(
      node: legacyOmemoDeviceListNode,
      buildItem: () {
        final item = XmppElement()..name = 'item';
        item.addAttribute(XmppAttribute('id', 'current'));
        final list = XmppElement()..name = 'list';
        list.addAttribute(XmppAttribute('xmlns', legacyOmemoNamespace));
        for (final deviceId in deviceIds) {
          final device = XmppElement()..name = 'device';
          device.addAttribute(XmppAttribute('id', deviceId.toString()));
          list.addChild(device);
        }
        item.addChild(list);
        return item;
      },
    );
  }

  @override
  Future<List<int>?> fetchLegacyDeviceList(String bareJid) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(bareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', legacyOmemoDeviceListNode));
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    final result = await _sendIqAndWait(iqStanza);
    if (result.type != IqStanzaType.RESULT) {
      return null;
    }
    final resultPubsub = result.getChild('pubsub');
    final resultItems = resultPubsub?.getChild('items');
    final item = resultItems?.getChild('item');
    final listElement = item?.getChild('list');
    if (listElement == null) {
      return null;
    }
    return listElement.children
        .where((child) => child.name == 'device')
        .map((child) => int.tryParse(child.getAttribute('id')?.value ?? ''))
        .whereType<int>()
        .toList();
  }

  @override
  void subscribeToLegacyDeviceList(String bareJid) {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    iqStanza.toJid = Jid.fromFullJid(bareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final subscribe = XmppElement()..name = 'subscribe';
    subscribe.addAttribute(XmppAttribute('node', legacyOmemoDeviceListNode));
    subscribe.addAttribute(
      XmppAttribute('jid', connection.fullJid.userAtDomain),
    );
    pubsub.addChild(subscribe);
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
  }

  /// Publishes [bundle] (our own device's key bundle) to the
  /// `eu.siacs.conversations.axolotl.bundles:<deviceid>` PEP node, per
  /// XEP-0384 v0.3.0.
  ///
  /// Forces the node's `pubsub#access_model` to `open` (see
  /// [_publishWithOpenAccess]), since contacts must be able to fetch our
  /// bundle without a prior subscription/whitelist entry.
  @override
  Future<void> publishLegacyBundle(OmemoBundle bundle) async {
    await _publishWithOpenAccess(
      node: legacyOmemoBundlesNode(bundle.id),
      buildItem: () {
        final item = XmppElement()..name = 'item';
        item.addAttribute(XmppAttribute('id', 'current'));
        item.addChild(_legacyBundleToElement(bundle));
        return item;
      },
    );
  }

  @override
  Future<OmemoBundle?> fetchLegacyBundle(String bareJid, int deviceId) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(bareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', legacyOmemoBundlesNode(deviceId)));
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
    return _legacyBundleFromElement(bareJid, deviceId, bundleElement);
  }

  /// XEP-0384 v0.3.0's legacy `<bundle/>` shape: a `<signedPreKeyPublic/>`
  /// (with a `signedPreKeyId` attribute), a `<signedPreKeySignature/>`, an
  /// `<identityKey/>`, and a `<prekeys/>` list of `<preKeyPublic/>`
  /// elements (each with a `preKeyId` attribute) -- distinct element names
  /// from OMEMO2's `<spk/>`/`<spks/>`/`<ik/>`/`<prekeys>/<pk/>` shape.
  ///
  /// Real-world legacy-OMEMO clients (Conversations/Gajim/Dino) serialize
  /// each public key here using libsignal's DJB-keytype-prefixed format:
  /// a leading `0x05` byte followed by the raw 32-byte Curve25519 key, so
  /// 33 bytes total. We must do the same when publishing our own bundle,
  /// or those clients will fail to parse/mis-parse our keys. See
  /// [_addDjbKeyType]/[_stripDjbKeyType].
  XmppElement _legacyBundleToElement(OmemoBundle bundle) {
    final bundleElement = XmppElement()..name = 'bundle';
    bundleElement.addAttribute(XmppAttribute('xmlns', legacyOmemoNamespace));

    final spk = XmppElement()..name = 'signedPreKeyPublic';
    spk.addAttribute(XmppAttribute('signedPreKeyId', bundle.spkId.toString()));
    spk.textValue = _addDjbKeyType(bundle.spkEncoded);
    bundleElement.addChild(spk);

    final spks = XmppElement()..name = 'signedPreKeySignature';
    spks.textValue = bundle.spkSignatureEncoded;
    bundleElement.addChild(spks);

    final ik = XmppElement()..name = 'identityKey';
    ik.textValue = _addDjbKeyType(bundle.ikEncoded);
    bundleElement.addChild(ik);

    final prekeys = XmppElement()..name = 'prekeys';
    bundle.opksEncoded.forEach((opkId, opkEncoded) {
      final pk = XmppElement()..name = 'preKeyPublic';
      pk.addAttribute(XmppAttribute('preKeyId', opkId.toString()));
      pk.textValue = _addDjbKeyType(opkEncoded);
      prekeys.addChild(pk);
    });
    bundleElement.addChild(prekeys);

    return bundleElement;
  }

  /// The libsignal "DJB type" byte (`0x05`, indicating a Curve25519/DJB
  /// public key) that real legacy-OMEMO clients prepend to every public
  /// key (identity key, signed prekey, one-time prekeys) in their
  /// `<bundle/>` publications. See [_addDjbKeyType]/[_stripDjbKeyType].
  static const int _djbKeyType = 0x05;

  /// Prepends the libsignal DJB-type byte to a base64-encoded raw 32-byte
  /// public key, matching what Conversations/Gajim/Dino expect to parse.
  /// Leaves the input unchanged if it's not exactly 32 bytes once decoded
  /// (defensive: never make already-33-byte or otherwise-shaped data
  /// worse).
  static String _addDjbKeyType(String base64Encoded) {
    final bytes = base64Decode(base64Encoded);
    if (bytes.length != 32) {
      return base64Encoded;
    }
    return base64Encode([_djbKeyType, ...bytes]);
  }

  /// Strips a leading libsignal DJB-type byte (`0x05`) from a
  /// base64-encoded public key if present, so that keys published by
  /// real-world legacy-OMEMO clients (33 bytes: 1-byte type + 32-byte
  /// key) can be consumed by `omemo_dart`, which expects the raw 32-byte
  /// key. Leaves 32-byte (already-raw) keys, as published by our own
  /// `_legacyBundleToElement` prior to this fix or by other
  /// non-type-prefixing clients, unchanged.
  static String _stripDjbKeyType(String base64Encoded) {
    final bytes = base64Decode(base64Encoded);
    if (bytes.length == 33) {
      return base64Encode(bytes.sublist(1));
    }
    return base64Encoded;
  }

  OmemoBundle? _legacyBundleFromElement(
    String bareJid,
    int deviceId,
    XmppElement bundleElement,
  ) {
    final spkElement = bundleElement.getChild('signedPreKeyPublic');
    final spksElement = bundleElement.getChild('signedPreKeySignature');
    final ikElement = bundleElement.getChild('identityKey');
    final prekeysElement = bundleElement.getChild('prekeys');
    if (spkElement == null || spksElement == null || ikElement == null) {
      return null;
    }
    final spkId = int.tryParse(
      spkElement.getAttribute('signedPreKeyId')?.value ?? '',
    );
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
      for (final pk in prekeysElement.children.where(
        (c) => c.name == 'preKeyPublic',
      )) {
        final opkId = int.tryParse(pk.getAttribute('preKeyId')?.value ?? '');
        final opkEncoded = pk.textValue?.trim();
        if (opkId != null && opkEncoded != null && opkEncoded.isNotEmpty) {
          opksEncoded[opkId] = _stripDjbKeyType(opkEncoded);
        }
      }
    }
    return OmemoBundle(
      bareJid,
      deviceId,
      _stripDjbKeyType(spkEncoded),
      spkId,
      spkSignatureEncoded,
      _stripDjbKeyType(ikEncoded),
      opksEncoded,
      // Real legacy-OMEMO clients sign the libsignal-serialized (DJB-type
      // -prefixed) form of the SPK, not the raw 32-byte key we store in
      // spkEncoded above (see OmemoBundle.spkSignatureMessageEncoded) --
      // keep the exact bytes as received on the wire so signature
      // verification checks against what was actually signed.
      spkSignatureMessageEncoded: spkEncoded,
      // Real legacy-OMEMO clients' identity key is a raw X25519 (not
      // Ed25519) public key, signed via XEdDSA -- see
      // `lib/encryption/xeddsa.dart` and `vendor/omemo_dart/VENDORING.md`
      // -- so `OmemoBundle.ik` must apply the Montgomery->Edwards
      // conversion before it's used for Ed25519-signature
      // verification/ECDH.
      ikIsX25519: true,
    );
  }
}
