import 'dart:convert';

import 'package:omemo_dart/omemo_dart.dart';
import 'package:xml/xml.dart' as xml;
import 'package:xmpp_stone/xmpp_stone.dart';

import '../storage/storage_service.dart';
import 'encryption_backend.dart';
import 'omemo2_serialization.dart';
import 'trust_store.dart';

/// The `urn:xmpp:omemo:2` namespace, mirrored from
/// `lib/xmpp/omemo_pep.dart` (kept as a local constant here to avoid this
/// file depending on the XMPP-transport-specific `OmemoPep` class).
const String omemo2Namespace = 'urn:xmpp:omemo:2';

/// The subset of [OmemoPep] (see `lib/xmpp/omemo_pep.dart`) that
/// [Omemo2Backend] depends on, extracted as an interface so tests can
/// supply an in-memory fake instead of a real `Connection`.
abstract class Omemo2PepTransport {
  Future<void> publishDeviceList(List<int> deviceIds);
  Future<List<int>?> fetchDeviceList(String bareJid);
  void subscribeToDeviceList(String bareJid);
  Future<void> publishBundle(OmemoBundle bundle);
  Future<OmemoBundle?> fetchBundle(String bareJid, int deviceId);
}

/// A single OMEMO2 device belonging to a contact, as surfaced to the
/// fingerprint verification UI (see
/// `lib/widgets/fingerprint_verification_screen.dart`): its device id, the
/// human-readable hex fingerprint of its identity public key (`null` if
/// the device's bundle hasn't been fetched/cached yet), and its current
/// [TrustState].
class Omemo2DeviceFingerprint {
  Omemo2DeviceFingerprint({
    required this.deviceId,
    required this.fingerprint,
    required this.trust,
  });

  final int deviceId;
  final String? fingerprint;
  final TrustState trust;
}

/// `urn:xmpp:omemo:2` (XEP-0384 "OMEMO2") [EncryptionBackend], wrapping
/// `omemo_dart`'s [OmemoManager] (X3DH + Double Ratchet session
/// management) and persisting its state via [StorageService] (Hive for
/// session/bundle/device-list data) and the platform secure store (for the
/// local identity key), through the OMEMO2 PEP nodes published/fetched by
/// [Omemo2PepTransport].
class Omemo2Backend implements EncryptionBackend {
  Omemo2Backend._(
    this.selfBareJid,
    this.storage,
    this.pep,
    this._omemoManager,
    this._trustManager,
    this.trustStore,
  );

  @override
  String get protocolId => 'omemo2';

  final String selfBareJid;
  final StorageService storage;
  final Omemo2PepTransport pep;

  /// Generic, protocol-agnostic trust store (see
  /// `lib/encryption/trust_store.dart`) that backs this backend's public
  /// [trustStateFor]/[setTrust]. The internal [_trustManager] below is
  /// kept purely for `omemo_dart`'s own session-enablement mechanics
  /// (whether to encrypt for a given device), and is bridged to
  /// [trustStore] via its `commit` callback so both stay in sync, e.g.
  /// when `omemo_dart` auto-blind-trusts a freshly seen device.
  final TrustStore trustStore;

  final OmemoManager _omemoManager;
  final BlindTrustBeforeVerificationTrustManager _trustManager;

  /// Creates (or restores, if a device was already persisted) an
  /// [Omemo2Backend] for [selfBareJid].
  ///
  /// If no device has been persisted yet and [importedIdentityKeyPem] is
  /// given (e.g. a value the user pasted in from a password manager, as
  /// produced by [exportIdentityKey]), the new device reuses that identity
  /// key instead of generating a fresh one, so it keeps the fingerprint of
  /// a previously backed-up identity. Ignored once a device already exists
  /// in [storage]: importing an identity key doesn't retroactively replace
  /// the currently-active one.
  static Future<Omemo2Backend> create({
    required String selfBareJid,
    required StorageService storage,
    required Omemo2PepTransport pep,
    TrustStore? trustStore,
    String? importedIdentityKeyPem,
  }) async {
    final device = await _loadOrGenerateDevice(
      selfBareJid,
      storage,
      importedIdentityKeyPem,
    );
    final sharedTrustStore = trustStore ?? TrustStore(storage);

    late final BlindTrustBeforeVerificationTrustManager trustManager;
    trustManager = BlindTrustBeforeVerificationTrustManager(
      loadData: (jid) async {
        return [
          for (final trustJson in storage.loadOmemo2TrustForJid(jid))
            BTBVTrustData(
              jid,
              trustJson['device'] as int,
              BTBVTrustState.fromInt(trustJson['state'] as int),
              trustJson['enabled'] as bool,
              false,
            ),
        ];
      },
      commit: (data) async {
        await storage.storeOmemo2Trust(data.jid, data.device, {
          'device': data.device,
          'state': data.state.value,
          'enabled': data.enabled,
        });
        // Mirror into the shared TrustStore so UI-facing trust state (e.g.
        // the fingerprint verification screen) reflects decisions made
        // internally by omemo_dart (such as auto-blind-trusting a newly
        // seen device), not just ones made through [setTrust].
        await sharedTrustStore.setTrust(
          data.jid,
          '${data.device}',
          _btbvToTrustState(data.state),
        );
      },
      removeTrust: (jid) async {
        await storage.removeOmemo2TrustForJid(jid);
      },
    );

    late final OmemoManager omemoManager;
    omemoManager = OmemoManager(
      device,
      trustManager,
      // Heartbeat messages are only required for liveness pings on
      // freshly-created ratchets; Step 1 doesn't send proactive heartbeats.
      (result, recipientJid) async {},
      (jid) async {
        // Always prefer a live PEP fetch over any cached device list; see
        // the identical comment in `OmemoBackend.create` for why -- in
        // short, `OmemoManager` only calls this once per JID per process
        // lifetime, so preferring the cache would mean a newly-added
        // device of a contact is never discovered until the app restarts.
        return await pep.fetchDeviceList(jid) ?? storage.loadOmemo2DeviceList(jid);
      },
      (jid, id) async {
        // Like fetchDeviceListImpl above, always try a live PEP fetch
        // first rather than preferring whatever is cached in Hive; see
        // the identical comment in `OmemoBackend.create` for why --
        // `OmemoManager` only calls this once per (jid, device) for the
        // process's lifetime, so a stale cached bundle would otherwise
        // never be refreshed without an app restart, and no bundle-fetch
        // IQ would ever be sent for that device again. Fall back to the
        // cache only if the live fetch itself fails (e.g. we're offline).
        final fetched = await pep.fetchBundle(jid, id);
        if (fetched != null) {
          await storage.storeOmemo2Bundle(jid, id, await _bundleToJson(fetched));
          return fetched;
        }
        final cached = storage.loadOmemo2Bundle(jid, id);
        if (cached != null) {
          return _bundleFromJson(jid, id, cached);
        }
        return null;
      },
      (jid) async => pep.subscribeToDeviceList(jid),
      (ownDevice) async => pep.publishBundle(await ownDevice.toBundle()),
      commitDevice: (updatedDevice) async {
        await storage.storeOmemo2Identity(
          selfBareJid,
          await omemoDeviceToJson(updatedDevice),
        );
      },
      commitDeviceList: (jid, devices) async {
        await storage.storeOmemo2DeviceList(jid, devices);
      },
      commitRatchets: (ratchets) async {
        for (final entry in ratchets) {
          await storage.storeOmemo2Ratchet(
            entry.jid,
            entry.id,
            await omemoRatchetToJson(entry.ratchet),
          );
        }
      },
      removeRatchets: (keys) async {
        await storage.removeOmemo2Ratchets([
          for (final key in keys) MapEntry(key.jid, key.deviceId),
        ]);
      },
      loadRatchets: (jid) async {
        final ratchetsJson = storage.loadOmemo2RatchetsForJid(jid);
        if (ratchetsJson.isEmpty) {
          return null;
        }
        final ratchets = <RatchetMapKey, OmemoDoubleRatchet>{};
        for (final entry in ratchetsJson.entries) {
          ratchets[RatchetMapKey(jid, entry.key)] = await omemoRatchetFromJson(
            entry.value,
          );
        }
        final devices =
            storage.loadOmemo2DeviceList(jid) ?? ratchetsJson.keys.toList();
        return OmemoDataPackage(devices, ratchets);
      },
    );

    return Omemo2Backend._(
      selfBareJid,
      storage,
      pep,
      omemoManager,
      trustManager,
      sharedTrustStore,
    );
  }

  /// Maps `omemo_dart`'s internal [BTBVTrustState] to the generic
  /// [TrustState] used by [TrustStore], for bridging BTBV's `commit`
  /// callback into the shared trust store.
  static TrustState _btbvToTrustState(BTBVTrustState state) {
    switch (state) {
      case BTBVTrustState.verified:
        return TrustState.verified;
      case BTBVTrustState.blindTrust:
        return TrustState.tofu;
      case BTBVTrustState.notTrusted:
        return TrustState.untrusted;
    }
  }

  static Future<OmemoDevice> _loadOrGenerateDevice(
    String selfBareJid,
    StorageService storage,
    String? importedIdentityKeyPem,
  ) async {
    final storedJson = await storage.loadOmemo2Identity(selfBareJid);
    if (storedJson != null) {
      return omemoDeviceFromJson(storedJson);
    }
    final device = importedIdentityKeyPem != null
        ? await deviceFromIdentityKeyExport(
            selfBareJid,
            identityKeyPairFromPem(importedIdentityKeyPem, _identityKeyLabel),
          )
        : await OmemoDevice.generateNewDevice(selfBareJid);
    await storage.storeOmemo2Identity(
      selfBareJid,
      await omemoDeviceToJson(device),
    );
    return device;
  }

  /// Label used in the `BEGIN`/`END` markers of this backend's exported
  /// identity key, see [identityKeyPairToPem]/[identityKeyPairFromPem].
  static const String _identityKeyLabel = 'OMEMO2';

  /// Exports our own long-term identity key (not the Double Ratchet's
  /// per-session root key -- see [identityKeyPairToPem]) as a PEM-style
  /// block, so the user can copy it somewhere safe (e.g. a password
  /// manager) and later restore it via [create]'s
  /// `importedIdentityKeyPem` parameter to keep the same OMEMO2
  /// fingerprint across a reinstall.
  Future<String> exportIdentityKey() async {
    final device = await _omemoManager.getDevice();
    return identityKeyPairToPem(device.ik, _identityKeyLabel);
  }

  static Future<Map<String, dynamic>> _bundleToJson(
    OmemoBundle bundle,
  ) async {
    return {
      'jid': bundle.jid,
      'id': bundle.id,
      'spk': bundle.spkEncoded,
      'spkId': bundle.spkId,
      'spks': bundle.spkSignatureEncoded,
      'ik': bundle.ikEncoded,
      'opks': bundle.opksEncoded,
    };
  }

  static OmemoBundle _bundleFromJson(
    String jid,
    int deviceId,
    Map<String, dynamic> json,
  ) {
    final opksRaw = (json['opks'] as Map).cast<dynamic, dynamic>();
    return OmemoBundle(
      jid,
      deviceId,
      json['spk'] as String,
      json['spkId'] as int,
      json['spks'] as String,
      json['ik'] as String,
      {
        for (final entry in opksRaw.entries)
          int.parse(entry.key.toString()): entry.value as String,
      },
    );
  }

  /// Publishes our own device bundle and device list via PEP so contacts
  /// can discover us and build OMEMO2 sessions with us.
  @override
  Future<void> publishIdentity() async {
    final device = await _omemoManager.getDevice();
    await pep.publishBundle(await device.toBundle());
    // Wimsy only ever runs a single OMEMO2 device per account (no
    // multi-install/multi-device support), so our own published
    // device-list must contain *only* our current device id, never a
    // union with whatever was previously cached -- see the identical fix
    // (and its rationale) in `OmemoBackend.publishIdentity`.
    final deviceIds = [device.id];
    await storage.storeOmemo2DeviceList(selfBareJid, deviceIds);
    await pep.publishDeviceList(deviceIds);
  }

  @override
  Future<EncryptedPayload> encryptForSend(
    String toBareJid,
    String plaintext,
  ) async {
    // XEP-0420 (Stanza Content Encryption) wraps the actual payload in an
    // <envelope/>; Step 1 encrypts a minimal envelope carrying just the
    // plaintext <body/>, matching the shape omemo_dart's own example uses.
    final envelope = XmppElement()..name = 'envelope';
    envelope.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sce:1'));
    final content = XmppElement()..name = 'content';
    final body = XmppElement()..name = 'body';
    body.textValue = plaintext;
    content.addChild(body);
    envelope.addChild(content);

    final result = await _omemoManager.onOutgoingStanza(
      OmemoOutgoingStanza([toBareJid], envelope.buildXmlString()),
    );

    final encrypted = XmppElement()..name = 'encrypted';
    encrypted.addAttribute(XmppAttribute('xmlns', omemo2Namespace));
    final device = await _omemoManager.getDevice();
    final header = XmppElement()..name = 'header';
    header.addAttribute(XmppAttribute('sid', device.id.toString()));
    final keysForJid = result.encryptedKeys[toBareJid] ?? const [];
    final keysElement = XmppElement()..name = 'keys';
    keysElement.addAttribute(XmppAttribute('jid', toBareJid));
    for (final key in keysForJid) {
      final keyElement = XmppElement()..name = 'key';
      keyElement.addAttribute(XmppAttribute('rid', key.rid.toString()));
      if (key.kex) {
        keyElement.addAttribute(XmppAttribute('kex', 'true'));
      }
      keyElement.textValue = key.value;
      keysElement.addChild(keyElement);
    }
    header.addChild(keysElement);
    encrypted.addChild(header);
    if (result.ciphertext != null) {
      final payload = XmppElement()..name = 'payload';
      payload.textValue = base64Encode(result.ciphertext!);
      encrypted.addChild(payload);
    }

    return EncryptedPayload(
      element: encrypted,
      fallbackBody:
          'This message is encrypted with OMEMO2 '
          '(https://xmpp.org/extensions/xep-0384.html) but your client '
          'does not support it.',
    );
  }

  @override
  Future<DecryptResult> decryptIncoming(XmppElement stanza) async {
    final encrypted = stanza.name == 'encrypted'
        ? stanza
        : stanza.getChild('encrypted');
    if (encrypted == null ||
        encrypted.getAttribute('xmlns')?.value != omemo2Namespace) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: TrustState.untrusted,
        error: 'Stanza does not contain an OMEMO2 <encrypted/> element',
      );
    }
    final fromJid = stanza.getAttribute('from')?.value;
    final bareSenderJid = fromJid == null
        ? null
        : Jid.fromFullJid(fromJid).userAtDomain;
    final header = encrypted.getChild('header');
    final sid = int.tryParse(header?.getAttribute('sid')?.value ?? '');
    if (bareSenderJid == null || sid == null) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: TrustState.untrusted,
        error: 'Missing sender JID or device id (sid) on <encrypted/>',
      );
    }
    final keysElement = header?.getChild('keys');
    final keys = <EncryptedKey>[
      for (final keyElement in keysElement?.children ?? const [])
        if (keyElement.name == 'key')
          EncryptedKey(
            int.tryParse(keyElement.getAttribute('rid')?.value ?? '') ?? -1,
            keyElement.textValue?.trim() ?? '',
            keyElement.getAttribute('kex')?.value == 'true',
          ),
    ]..removeWhere((key) => key.rid == -1 || key.value.isEmpty);
    final payload = encrypted.getChild('payload')?.textValue?.trim();

    final result = await _omemoManager.onIncomingStanza(
      OmemoIncomingStanza(
        bareSenderJid,
        sid,
        keys,
        payload,
        false,
      ),
    );

    if (result.error != null || result.payload == null) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: await trustStateFor(bareSenderJid, deviceOrKeyId: '$sid'),
        error: result.error?.toString() ?? 'Empty OMEMO2 message',
      );
    }

    // The decrypted payload is the serialised XEP-0420 <envelope/>; Step 1
    // only needs the <body/> text carried within it.
    final plaintext = _extractEnvelopeBody(result.payload!);

    return DecryptResult(
      plaintext: plaintext,
      protocolId: protocolId,
      senderTrust: await trustStateFor(bareSenderJid, deviceOrKeyId: '$sid'),
    );
  }

  /// Extracts the plaintext `<body/>` text from a serialised XEP-0420
  /// `<envelope/>` (see [encryptForSend]), or `null` if the payload isn't
  /// in the expected shape.
  String? _extractEnvelopeBody(String envelopeXml) {
    try {
      final document = xml.XmlDocument.parse(envelopeXml);
      final body = document.rootElement
          .findElements('content')
          .firstOrNull
          ?.findElements('body')
          .firstOrNull;
      return body?.innerText.trim();
    } catch (_) {
      return null;
    }
  }

  /// Returns the known OMEMO2 device ids for [bareJid] that have an entry
  /// in the internal BTBV trust manager (i.e. a session has been
  /// established at least once), used to discover which devices to
  /// aggregate over in [trustStateFor] when no specific [deviceOrKeyId]
  /// is given, and by the fingerprint verification UI.
  Future<List<int>> knownDeviceIdsFor(String bareJid) async {
    final devicesTrust = await _trustManager.getDevicesTrust(bareJid);
    return devicesTrust.keys.toList();
  }

  /// Returns the human-readable hex fingerprint
  /// (https://xmpp.org/extensions/xep-0384.html#security § 2) of our own
  /// current device's identity key, for display (e.g. as a QR code) so a
  /// contact can visually compare it against what their client shows for
  /// us.
  Future<String> ownFingerprint() async {
    final device = await _omemoManager.getDevice();
    return (await device.toBundle()).getFingerprint();
  }

  /// Our own current OMEMO2 device id, needed (together with
  /// [ownFingerprint]) to build a proper `xmpp:`-URI QR code (see
  /// `lib/widgets/fingerprint_verification_screen.dart`) -- scanning a
  /// bare fingerprint hex string is not understood by other clients such
  /// as Conversations, which expect `xmpp:<jid>?omemo-sid-<id>=<fp>`.
  Future<int> ownDeviceId() async {
    final device = await _omemoManager.getDevice();
    return device.id;
  }

  /// Proactively fetches/refreshes [bareJid]'s `urn:xmpp:omemo:2:devices`
  /// device list and any not-yet-known device bundles, and subscribes to
  /// the device-list PEP node -- all three of which `omemo_dart` would
  /// otherwise only do as a side effect of actually encrypting a message
  /// to [bareJid] (see `OmemoManager._fetchNewOmemoBundles`/
  /// `onOutgoingStanza`). Without this, a contact's devices never show up
  /// in the fingerprint verification screen (and no bundle/devicelist IQs
  /// or PEP subscribe requests are ever sent) until the user has already
  /// sent them at least one encrypted message.
  ///
  /// Implemented via [OmemoManager.sendOmemoHeartbeat], which runs through
  /// the exact same device-list-fetch/bundle-fetch/subscribe logic as a
  /// real encrypt, but the heartbeat "send" itself is wired to a no-op
  /// (see `create()` above), so nothing is written to the wire.
  Future<void> ensureDevicesKnown(String bareJid) async {
    try {
      await _omemoManager.sendOmemoHeartbeat(bareJid);
    } catch (e) {
      Log.w(
        'Omemo2Backend',
        'Failed to proactively fetch OMEMO2 devices for $bareJid: $e',
      );
    }
  }

  /// Returns every known OMEMO2 device of [bareJid] (that a session has
  /// been established with at least once) together with its fingerprint
  /// (when the device's bundle is cached) and current [TrustState], for
  /// the fingerprint verification screen.
  Future<List<Omemo2DeviceFingerprint>> deviceFingerprintsFor(
    String bareJid,
  ) async {
    final deviceIds = await knownDeviceIdsFor(bareJid);
    final result = <Omemo2DeviceFingerprint>[];
    for (final deviceId in deviceIds) {
      final cachedBundle = storage.loadOmemo2Bundle(bareJid, deviceId);
      String? fingerprint;
      if (cachedBundle != null) {
        fingerprint = await _bundleFromJson(
          bareJid,
          deviceId,
          cachedBundle,
        ).getFingerprint();
      }
      final trust = await trustStateFor(bareJid, deviceOrKeyId: '$deviceId');
      result.add(
        Omemo2DeviceFingerprint(
          deviceId: deviceId,
          fingerprint: fingerprint,
          trust: trust,
        ),
      );
    }
    return result;
  }

  @override
  Future<TrustState> trustStateFor(
    String bareJid, {
    String? deviceOrKeyId,
  }) async {
    if (deviceOrKeyId != null) {
      return trustStore.trustStateFor(bareJid, deviceOrKeyId);
    }
    final deviceIds = await knownDeviceIdsFor(bareJid);
    if (deviceIds.isEmpty) {
      return TrustState.untrusted;
    }
    final states = [
      for (final deviceId in deviceIds)
        await trustStore.trustStateFor(bareJid, '$deviceId'),
    ];
    if (states.any((state) => state == TrustState.verified)) {
      return TrustState.verified;
    }
    return TrustState.tofu;
  }

  @override
  Future<void> setTrust(
    String bareJid,
    String deviceOrKeyId,
    TrustState state,
  ) async {
    final deviceId = int.parse(deviceOrKeyId);
    final btbvState = switch (state) {
      TrustState.verified => BTBVTrustState.verified,
      TrustState.tofu => BTBVTrustState.blindTrust,
      TrustState.untrusted => BTBVTrustState.notTrusted,
      TrustState.revoked => BTBVTrustState.notTrusted,
    };
    await _trustManager.setDeviceTrust(bareJid, deviceId, btbvState);
    if (state == TrustState.revoked) {
      await _trustManager.setEnabled(bareJid, deviceId, false);
    }
    // A revoked device is surfaced to the UI/TrustStore as simply
    // untrusted (mirroring the BTBV mapping above); [TrustState.revoked]
    // itself is not a state TrustStore needs to distinguish from
    // [TrustState.untrusted] for OMEMO2's purposes.
    final storedState = state == TrustState.revoked
        ? TrustState.untrusted
        : state;
    await trustStore.setTrust(bareJid, deviceOrKeyId, storedState);
  }
}
