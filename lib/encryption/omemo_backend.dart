import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:omemo_dart/omemo_dart.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import '../storage/storage_service.dart';
import 'encryption_backend.dart';
import 'omemo2_backend.dart' show Omemo2DeviceFingerprint;
import 'omemo2_serialization.dart';
import 'trust_store.dart';

/// The `eu.siacs.conversations.axolotl` namespace used by legacy OMEMO
/// (XEP-0384 v0.3.0, https://xmpp.org/extensions/attic/xep-0384-0.3.0.html),
/// mirrored from `lib/xmpp/omemo_pep.dart` (kept as a local constant here
/// to avoid this file depending on the XMPP-transport-specific `OmemoPep`
/// class, matching the convention in `omemo2_backend.dart`).
const String legacyOmemoNamespace = 'eu.siacs.conversations.axolotl';

/// The subset of `OmemoPep` (see `lib/xmpp/omemo_pep.dart`) that
/// [OmemoBackend] depends on for the legacy (`eu.siacs.conversations.axolotl`)
/// PEP nodes, extracted as an interface so tests can supply an in-memory
/// fake instead of a real `Connection` -- mirrors [Omemo2PepTransport].
abstract class OmemoPepTransport {
  Future<void> publishLegacyDeviceList(List<int> deviceIds);
  Future<List<int>?> fetchLegacyDeviceList(String bareJid);
  void subscribeToLegacyDeviceList(String bareJid);
  Future<void> publishLegacyBundle(OmemoBundle bundle);
  Future<OmemoBundle?> fetchLegacyBundle(String bareJid, int deviceId);
}

/// Legacy OMEMO (XEP-0384 v0.3.0, `eu.siacs.conversations.axolotl`)
/// [EncryptionBackend], for interop with legacy-OMEMO-only clients (e.g.
/// Conversations, Gajim, Dino).
///
/// Shares `omemo_dart`'s X3DH/Double-Ratchet session machinery with
/// [Omemo2Backend] (same `OmemoManager`, same device/bundle/ratchet
/// persistence pattern, same [TrustStore]-backed trust tracking), but:
///
///  * builds/parses the legacy XML envelope shape (`<encrypted
///    xmlns='eu.siacs.conversations.axolotl'>` with a `<header sid='...'>`
///    containing `<key rid='...'>`/`<iv>` children and a base64
///    `<payload>`), which differs from OMEMO2's XEP-0420-style envelope;
///  * is keyed under entirely separate storage (see
///    `StorageService.storeOmemoIdentity`/`loadOmemoDeviceList`/etc.) and a
///    separate [OmemoPepTransport] (the legacy PEP node names), since
///    legacy-OMEMO and OMEMO2 devices for the same contact live in
///    different device lists/namespaces and must be tracked as distinct
///    device-id entries.
///
/// Unlike [Omemo2Backend] (OMEMO2/XEP-0420, which negotiates its own
/// ciphersuite and uses AES-256-CBC + HMAC-SHA-256), XEP-0384 v0.3.0 has no
/// ciphersuite negotiation and mandates AES-128-GCM for the `<payload>`.
/// This backend therefore does not use `OmemoManager.onOutgoingStanza`'s/
/// `onIncomingStanza`'s built-in AES-256-CBC+HMAC-SHA-256 payload cipher;
/// instead it supplies its own AES-128-GCM-encrypted payload and 32 bytes of
/// raw key material (16-byte AES-128 key + 16-byte GCM tag) to be
/// ratchet-wrapped/-unwrapped per-device, via the vendored `omemo_dart`
/// library's `OmemoOutgoingStanza.rawKeyMaterial`/`ciphertext` and
/// `OmemoIncomingStanza.skipPayloadDecryption`/`DecryptionResult.rawKeyMaterial`
/// hooks (see `vendor/omemo_dart/VENDORING.md` for details of that local
/// patch). The random IV used for AES-128-GCM is transported explicitly as
/// an `<iv>` child of `<header>`, matching the wire format used by real
/// legacy-OMEMO clients (Conversations/Gajim/Dino via `python-oldmemo`).
class OmemoBackend implements EncryptionBackend {
  OmemoBackend._(
    this.selfBareJid,
    this.storage,
    this.pep,
    this._omemoManager,
    this._trustManager,
    this.trustStore,
  );

  @override
  String get protocolId => 'omemo';

  final String selfBareJid;
  final StorageService storage;
  final OmemoPepTransport pep;

  /// Generic, protocol-agnostic trust store (see
  /// `lib/encryption/trust_store.dart`), shared with [Omemo2Backend] but
  /// keyed by legacy-OMEMO device ids, which are a distinct namespace from
  /// OMEMO2 device ids for the same contact.
  final TrustStore trustStore;

  final OmemoManager _omemoManager;
  final BlindTrustBeforeVerificationTrustManager _trustManager;

  /// XEP-0384 v0.3.0 mandates AES-128-GCM (with no ciphersuite negotiation)
  /// for the `<payload>`, unlike OMEMO2/XEP-0420's AES-256-CBC+HMAC-SHA-256.
  static final AesGcm _payloadCipher = AesGcm.with128bits();

  /// Length, in bytes, of the AES-128-GCM authentication tag/MAC.
  static const int _gcmMacLength = 16;

  /// Length, in bytes, of the raw AES-128 key.
  static const int _aes128KeyLength = 16;

  /// Creates (or restores, if a device was already persisted) an
  /// [OmemoBackend] for [selfBareJid].
  static Future<OmemoBackend> create({
    required String selfBareJid,
    required StorageService storage,
    required OmemoPepTransport pep,
    TrustStore? trustStore,
  }) async {
    final device = await _loadOrGenerateDevice(selfBareJid, storage);
    final sharedTrustStore = trustStore ?? TrustStore(storage);

    late final BlindTrustBeforeVerificationTrustManager trustManager;
    trustManager = BlindTrustBeforeVerificationTrustManager(
      loadData: (jid) async {
        return [
          for (final trustJson in storage.loadOmemoTrustForJid(jid))
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
        await storage.storeOmemoTrust(data.jid, data.device, {
          'device': data.device,
          'state': data.state.value,
          'enabled': data.enabled,
        });
        await sharedTrustStore.setTrust(
          data.jid,
          '${data.device}',
          _btbvToTrustState(data.state),
        );
      },
      removeTrust: (jid) async {
        await storage.removeOmemoTrustForJid(jid);
      },
    );

    late final OmemoManager omemoManager;
    omemoManager = OmemoManager(
      device,
      trustManager,
      (result, recipientJid) async {},
      (jid) async {
        return storage.loadOmemoDeviceList(jid) ??
            await pep.fetchLegacyDeviceList(jid);
      },
      (jid, id) async {
        final cached = storage.loadOmemoBundle(jid, id);
        if (cached != null) {
          return _bundleFromJson(jid, id, cached);
        }
        final fetched = await pep.fetchLegacyBundle(jid, id);
        if (fetched != null) {
          await storage.storeOmemoBundle(jid, id, await _bundleToJson(fetched));
        }
        return fetched;
      },
      (jid) async => pep.subscribeToLegacyDeviceList(jid),
      (ownDevice) async => pep.publishLegacyBundle(await ownDevice.toBundle()),
      commitDevice: (updatedDevice) async {
        await storage.storeOmemoIdentity(
          selfBareJid,
          await omemoDeviceToJson(updatedDevice),
        );
      },
      commitDeviceList: (jid, devices) async {
        await storage.storeOmemoDeviceList(jid, devices);
      },
      commitRatchets: (ratchets) async {
        for (final entry in ratchets) {
          await storage.storeOmemoRatchet(
            entry.jid,
            entry.id,
            await omemoRatchetToJson(entry.ratchet),
          );
        }
      },
      removeRatchets: (keys) async {
        await storage.removeOmemoRatchets([
          for (final key in keys) MapEntry(key.jid, key.deviceId),
        ]);
      },
      loadRatchets: (jid) async {
        final ratchetsJson = storage.loadOmemoRatchetsForJid(jid);
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
            storage.loadOmemoDeviceList(jid) ?? ratchetsJson.keys.toList();
        return OmemoDataPackage(devices, ratchets);
      },
    );

    return OmemoBackend._(
      selfBareJid,
      storage,
      pep,
      omemoManager,
      trustManager,
      sharedTrustStore,
    );
  }

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
  ) async {
    final storedJson = await storage.loadOmemoIdentity(selfBareJid);
    if (storedJson != null) {
      return omemoDeviceFromJson(storedJson);
    }
    final device = await OmemoDevice.generateNewDevice(selfBareJid);
    await storage.storeOmemoIdentity(
      selfBareJid,
      await omemoDeviceToJson(device),
    );
    return device;
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

  @override
  Future<void> publishIdentity() async {
    final device = await _omemoManager.getDevice();
    await pep.publishLegacyBundle(await device.toBundle());
    final knownDevices = storage.loadOmemoDeviceList(selfBareJid) ?? [];
    final deviceIds = {...knownDevices, device.id}.toList();
    await storage.storeOmemoDeviceList(selfBareJid, deviceIds);
    await pep.publishLegacyDeviceList(deviceIds);
  }

  @override
  Future<EncryptedPayload> encryptForSend(
    String toBareJid,
    String plaintext,
  ) async {
    // XEP-0384 v0.3.0 mandates AES-128-GCM for <payload>. We generate our
    // own random AES-128 key/IV, encrypt with it ourselves, and only hand
    // `OmemoManager` the resulting 32 bytes of raw key material (16-byte
    // key + 16-byte GCM tag) to be ratchet-wrapped per-device alongside the
    // already-encrypted ciphertext -- see the class doc.
    final secretKey = await _payloadCipher.newSecretKey();
    final nonce = _payloadCipher.newNonce();
    final secretBox = await _payloadCipher.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
    );
    final rawKeyMaterial = [
      ...await secretKey.extractBytes(),
      ...secretBox.mac.bytes,
    ];

    final result = await _omemoManager.onOutgoingStanza(
      OmemoOutgoingStanza(
        [toBareJid],
        plaintext,
        rawKeyMaterial: rawKeyMaterial,
        ciphertext: secretBox.cipherText,
      ),
    );

    final encrypted = XmppElement()..name = 'encrypted';
    encrypted.addAttribute(XmppAttribute('xmlns', legacyOmemoNamespace));
    final device = await _omemoManager.getDevice();
    final header = XmppElement()..name = 'header';
    header.addAttribute(XmppAttribute('sid', device.id.toString()));
    final keysForJid = result.encryptedKeys[toBareJid] ?? const [];
    for (final key in keysForJid) {
      final keyElement = XmppElement()..name = 'key';
      keyElement.addAttribute(XmppAttribute('rid', key.rid.toString()));
      if (key.kex) {
        keyElement.addAttribute(XmppAttribute('kex', 'true'));
      }
      keyElement.textValue = key.value;
      header.addChild(keyElement);
    }
    // Legacy OMEMO's <header> transports the AES-128-GCM IV explicitly as
    // an <iv> child, alongside the <key> elements (XEP-0384 v0.3.0).
    final ivElement = XmppElement()..name = 'iv';
    ivElement.textValue = base64Encode(nonce);
    header.addChild(ivElement);
    encrypted.addChild(header);

    if (result.ciphertext != null) {
      final payload = XmppElement()..name = 'payload';
      payload.textValue = base64Encode(result.ciphertext!);
      encrypted.addChild(payload);
    }

    return EncryptedPayload(
      element: encrypted,
      fallbackBody:
          'This message is encrypted with OMEMO '
          '(https://xmpp.org/extensions/attic/xep-0384-0.3.0.html) but '
          'your client does not support it.',
    );
  }

  @override
  Future<DecryptResult> decryptIncoming(XmppElement stanza) async {
    final encrypted = stanza.name == 'encrypted'
        ? stanza
        : stanza.getChild('encrypted');
    if (encrypted == null ||
        encrypted.getAttribute('xmlns')?.value != legacyOmemoNamespace) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: TrustState.untrusted,
        error: 'Stanza does not contain a legacy OMEMO <encrypted/> element',
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
    // Unlike OMEMO2's envelope, legacy OMEMO's <key> elements are direct
    // children of <header>, not nested under a <keys> sub-element.
    final keys = <EncryptedKey>[
      for (final child in header?.children ?? const [])
        if (child.name == 'key')
          EncryptedKey(
            int.tryParse(child.getAttribute('rid')?.value ?? '') ?? -1,
            child.textValue?.trim() ?? '',
            child.getAttribute('kex')?.value == 'true',
          ),
    ]..removeWhere((key) => key.rid == -1 || key.value.isEmpty);
    final payload = encrypted.getChild('payload')?.textValue?.trim();
    final ivBase64 = header?.getChild('iv')?.textValue?.trim();

    // XEP-0384 v0.3.0 mandates AES-128-GCM for <payload>: we don't let
    // `OmemoManager` decrypt the payload itself (it would assume
    // AES-256-CBC+HMAC-SHA-256); instead we get back the raw ratchet-
    // unwrapped key material and decrypt/verify it ourselves -- see the
    // class doc.
    final result = await _omemoManager.onIncomingStanza(
      OmemoIncomingStanza(
        bareSenderJid,
        sid,
        keys,
        payload,
        false,
        skipPayloadDecryption: true,
      ),
    );

    if (result.error != null) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: await trustStateFor(bareSenderJid, deviceOrKeyId: '$sid'),
        error: result.error.toString(),
      );
    }

    final rawKeyMaterial = result.rawKeyMaterial;
    if (payload == null || rawKeyMaterial == null) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: await trustStateFor(bareSenderJid, deviceOrKeyId: '$sid'),
        error: 'Empty legacy OMEMO message',
      );
    }
    if (ivBase64 == null ||
        ivBase64.isEmpty ||
        rawKeyMaterial.length != _aes128KeyLength + _gcmMacLength) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: await trustStateFor(bareSenderJid, deviceOrKeyId: '$sid'),
        error: 'Missing <iv> or malformed key material on legacy OMEMO '
            'message',
      );
    }

    try {
      final rawKey = rawKeyMaterial.sublist(0, _aes128KeyLength);
      final mac = rawKeyMaterial.sublist(_aes128KeyLength);
      final iv = base64Decode(ivBase64);
      final secretBox = SecretBox(
        base64Decode(payload),
        nonce: iv,
        mac: Mac(mac),
      );
      final plaintextBytes = await _payloadCipher.decrypt(
        secretBox,
        secretKey: SecretKey(rawKey),
      );
      return DecryptResult(
        plaintext: utf8.decode(plaintextBytes),
        protocolId: protocolId,
        senderTrust: await trustStateFor(bareSenderJid, deviceOrKeyId: '$sid'),
      );
    } on Exception catch (e) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: await trustStateFor(bareSenderJid, deviceOrKeyId: '$sid'),
        error: 'Failed to decrypt AES-128-GCM payload: $e',
      );
    }
  }

  /// Returns the known legacy-OMEMO device ids for [bareJid] that have an
  /// entry in the internal BTBV trust manager (i.e. a session has been
  /// established at least once), mirroring
  /// `Omemo2Backend.knownDeviceIdsFor`.
  Future<List<int>> knownDeviceIdsFor(String bareJid) async {
    final devicesTrust = await _trustManager.getDevicesTrust(bareJid);
    return devicesTrust.keys.toList();
  }

  /// Our own current device's identity key fingerprint, mirroring
  /// `Omemo2Backend.ownFingerprint`.
  Future<String> ownFingerprint() async {
    final device = await _omemoManager.getDevice();
    return (await device.toBundle()).getFingerprint();
  }

  /// Every known legacy-OMEMO device of [bareJid] with its fingerprint
  /// (when cached) and current [TrustState], mirroring
  /// `Omemo2Backend.deviceFingerprintsFor`.
  Future<List<Omemo2DeviceFingerprint>> deviceFingerprintsFor(
    String bareJid,
  ) async {
    final deviceIds = await knownDeviceIdsFor(bareJid);
    final result = <Omemo2DeviceFingerprint>[];
    for (final deviceId in deviceIds) {
      final cachedBundle = storage.loadOmemoBundle(bareJid, deviceId);
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
    final storedState = state == TrustState.revoked
        ? TrustState.untrusted
        : state;
    await trustStore.setTrust(bareJid, deviceOrKeyId, storedState);
  }
}
