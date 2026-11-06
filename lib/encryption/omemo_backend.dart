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
  ///
  /// If no device has been persisted yet and [importedIdentityKeyPem] is
  /// given (e.g. a value the user pasted in from a password manager, as
  /// produced by [exportIdentityKey]), the new device reuses that identity
  /// key instead of generating a fresh one, so it keeps the fingerprint of
  /// a previously backed-up identity. Ignored once a device already exists
  /// in [storage]: importing an identity key doesn't retroactively replace
  /// the currently-active one. Mirrors `Omemo2Backend.create`.
  static Future<OmemoBackend> create({
    required String selfBareJid,
    required StorageService storage,
    required OmemoPepTransport pep,
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
        // Bundles cached before the SPK-signature-message fix (see
        // OmemoBundle.spkSignatureMessageEncoded) don't carry the 'spksMsg'
        // key below, so _bundleFromJson would fall back to verifying the
        // signature against the already-stripped 32-byte key -- which
        // fails with InvalidKeyExchangeSignatureError for any real
        // legacy-OMEMO client whose signature covers the libsignal
        // type-prefixed form. Treat such stale entries as a cache miss so
        // they get refetched (and re-cached with the new field) instead of
        // reproducing that failure forever.
        if (cached != null && cached.containsKey('spksMsg')) {
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
    String? importedIdentityKeyPem,
  ) async {
    final storedJson = await storage.loadOmemoIdentity(selfBareJid);
    if (storedJson != null) {
      return omemoDeviceFromJson(storedJson);
    }
    final device = importedIdentityKeyPem != null
        ? await deviceFromIdentityKeyExport(
            selfBareJid,
            identityKeyPairFromPem(importedIdentityKeyPem, _identityKeyLabel),
          )
        : await OmemoDevice.generateNewDevice(selfBareJid);
    await storage.storeOmemoIdentity(
      selfBareJid,
      await omemoDeviceToJson(device),
    );
    return device;
  }

  /// Label used in the `BEGIN`/`END` markers of this backend's exported
  /// identity key, see [identityKeyPairToPem]/[identityKeyPairFromPem].
  /// Distinct from `Omemo2Backend`'s label so a key exported from one
  /// protocol's backend can't accidentally be imported into the other.
  static const String _identityKeyLabel = 'OMEMO';

  /// Exports our own long-term identity key (not the Double Ratchet's
  /// per-session root key -- see [identityKeyPairToPem]) as a PEM-style
  /// block, so the user can copy it somewhere safe (e.g. a password
  /// manager) and later restore it via [create]'s
  /// `importedIdentityKeyPem` parameter to keep the same legacy-OMEMO
  /// fingerprint across a reinstall. Mirrors `Omemo2Backend.exportIdentityKey`.
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
      'spksMsg': bundle.spkSignatureMessageEncoded,
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
      _stripDjbKeyType(json['spk'] as String),
      json['spkId'] as int,
      json['spks'] as String,
      _stripDjbKeyType(json['ik'] as String),
      {
        for (final entry in opksRaw.entries)
          int.parse(entry.key.toString()): _stripDjbKeyType(
            entry.value as String,
          ),
      },
      spkSignatureMessageEncoded: json['spksMsg'] as String?,
    );
  }

  /// Defensively strips a leading libsignal DJB-type byte (`0x05`) from a
  /// base64-encoded public key, if present (33 bytes -> 32 bytes).
  ///
  /// `lib/xmpp/omemo_pep.dart`'s `fetchLegacyBundle` already strips this
  /// byte before a bundle is cached via `storeOmemoBundle`, but bundles
  /// cached in Hive *before* that fix was applied still carry the raw
  /// 33-byte libsignal-serialized key, and are never re-fetched once
  /// cached -- so loading them here would otherwise keep reproducing the
  /// `Algorithm ed25519 expects a public key with 32 bytes, but got: 33
  /// bytes` encryption failure indefinitely, even after upgrading. This
  /// mirrors `OmemoPep._stripDjbKeyType` so that both freshly-fetched and
  /// previously-cached bundles end up normalized to the raw 32-byte form
  /// `omemo_dart` expects. A no-op for already-32-byte (or otherwise
  /// unexpectedly-shaped) keys.
  static String _stripDjbKeyType(String base64Encoded) {
    final bytes = base64Decode(base64Encoded);
    if (bytes.length == 33) {
      return base64Encode(bytes.sublist(1));
    }
    return base64Encoded;
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
    final keysForJid = (result.encryptedKeys[toBareJid] ?? const [])
        .map(_fixOutgoingKexKey)
        .toList();
    if (keysForJid.isEmpty) {
      // No usable device/bundle was found for toBareJid (e.g. the device
      // list/bundle fetch via PEP failed, or every known device is
      // untrusted/disabled), so `omemo_dart` couldn't wrap any per-device
      // key. Sending the resulting <encrypted/> stanza anyway would
      // silently produce an undecryptable message with no <key> children
      // at all -- throw instead, so the caller's "Failed to encrypt
      // outgoing message" path (see xmpp_service.dart) surfaces this
      // clearly instead of the message being sent (and accepted by the
      // server) with no recipient able to decrypt it.
      throw StateError(await _describeNoUsableKeysReason(toBareJid, result));
    }
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

  /// Builds a specific, actionable explanation for why [encryptForSend]
  /// couldn't wrap any per-device key for [toBareJid] in [result].
  ///
  /// `omemo_dart`'s `onOutgoingStanza` can end up with zero keys for a JID
  /// for several very different reasons, only some of which it records in
  /// `result.encryptionErrors`:
  /// - no device list was ever cached for the JID at all;
  /// - a bundle fetch via PEP failed, or the X3DH key-exchange signature
  ///   was invalid;
  /// - a ratchet session exists but has no matching entry in the
  ///   ratchet map (shouldn't normally happen);
  /// - **the device is known, a ratchet session was even just built for
  ///   it (so "Fetching bundles"/"Building new ratchet" logged fine), but
  ///   `BlindTrustBeforeVerificationTrustManager.isTrusted`/`isEnabled`
  ///   silently skipped it** -- this happens whenever at least one other
  ///   device of the same JID was ever manually marked "verified" via the
  ///   fingerprint screen, since BTBV then refuses blind trust for any
  ///   other (new/unverified) device of that JID. `omemo_dart` doesn't
  ///   log or record this case as an error at all, which is why this was
  ///   previously surfaced as a generic, unexplained failure.
  Future<String> _describeNoUsableKeysReason(
    String toBareJid,
    EncryptionResult result,
  ) async {
    final errors = result.deviceEncryptionErrors[toBareJid];
    if (errors != null && errors.isNotEmpty) {
      final details = errors
          .map((e) => '${e.device ?? '?'}: ${e.error.runtimeType}')
          .join(', ');
      return 'Failed to prepare legacy OMEMO keys for $toBareJid: $details';
    }

    final knownDeviceIds = await knownDeviceIdsFor(toBareJid);
    if (knownDeviceIds.isEmpty) {
      return 'No legacy OMEMO devices/keys available for $toBareJid; '
          'device list or bundle fetch via PEP likely failed (see '
          'omemo_dart/OmemoManager logs above for the underlying cause)';
    }

    final perDevice = <String>[];
    for (final deviceId in knownDeviceIds) {
      final trusted = await _trustManager.isTrusted(toBareJid, deviceId);
      final enabled = await _trustManager.isEnabled(toBareJid, deviceId);
      perDevice.add('$deviceId (trusted=$trusted, enabled=$enabled)');
    }
    return 'Found ${knownDeviceIds.length} known legacy OMEMO device(s) for '
        '$toBareJid, but none are both trusted and enabled: '
        '${perDevice.join(', ')}. This typically happens when another '
        'device of this contact was previously marked "verified" in the '
        'fingerprint screen, which makes BlindTrustBeforeVerification '
        'refuse blind trust for any other (new/unverified) device of '
        'theirs -- verify or manually trust the device above to fix this.';
  }

  /// The libsignal "DJB type" byte (`0x05`, indicating a Curve25519/DJB
  /// public key) that real legacy-OMEMO clients (Conversations/Gajim/Dino)
  /// prepend not only to the public keys in their PEP `<bundle/>` (see
  /// `lib/xmpp/omemo_pep.dart`'s `_addDjbKeyType`/`_stripDjbKeyType`), but
  /// also to the `ik`/`ek` fields of the `OMEMOKeyExchange` protobuf
  /// embedded in a `<key kex='true'>` element used to establish a new
  /// X3DH session. `omemo_dart`'s own schema (shared with OMEMO2, which
  /// never adds this prefix) expects the raw 32-byte form, so we must
  /// strip/add it ourselves on this protobuf too -- see
  /// [_fixIncomingKexKey]/[_fixOutgoingKexKey].
  static const int _djbKeyType = 0x05;

  static List<int> _stripDjbKeyTypeBytes(List<int> bytes) {
    if (bytes.length == 33) {
      return bytes.sublist(1);
    }
    return bytes;
  }

  static List<int> _addDjbKeyTypeBytes(List<int> bytes) {
    if (bytes.length == 32) {
      return [_djbKeyType, ...bytes];
    }
    return bytes;
  }

  /// Prepends the libsignal DJB-type byte to the `ik`/`ek` fields of an
  /// outgoing `<key kex='true'>` element's embedded `OMEMOKeyExchange`
  /// protobuf, so real legacy-OMEMO clients can parse our key exchange
  /// (otherwise they fail to recognise the message as encrypted for their
  /// device, e.g. Conversations' "Message was not encrypted for this
  /// device"). A no-op for non-kex (plain ratchet message) keys, and
  /// defensive against malformed protobuf data (falls back to the
  /// original key unchanged).
  static EncryptedKey _fixOutgoingKexKey(EncryptedKey key) {
    if (!key.kex) {
      return key;
    }
    try {
      final kex = OMEMOKeyExchange.fromBuffer(key.data);
      kex.ik = _addDjbKeyTypeBytes(kex.ik);
      kex.ek = _addDjbKeyTypeBytes(kex.ek);
      return EncryptedKey(key.rid, base64Encode(kex.writeToBuffer()), key.kex);
    } catch (_) {
      return key;
    }
  }

  /// Strips a leading libsignal DJB-type byte from the `ik`/`ek` fields of
  /// an incoming `<key kex='true'>` element's embedded `OMEMOKeyExchange`
  /// protobuf, if present, before handing it to `OmemoManager` (which
  /// expects the raw 32-byte form and otherwise throws "Algorithm ed25519
  /// expects a public key with 32 bytes, but got: 33 bytes"). A no-op for
  /// non-kex keys, and defensive against malformed protobuf data (falls
  /// back to the original key unchanged).
  static EncryptedKey _fixIncomingKexKey(EncryptedKey key) {
    if (!key.kex) {
      return key;
    }
    try {
      final kex = OMEMOKeyExchange.fromBuffer(key.data);
      kex.ik = _stripDjbKeyTypeBytes(kex.ik);
      kex.ek = _stripDjbKeyTypeBytes(kex.ek);
      return EncryptedKey(key.rid, base64Encode(kex.writeToBuffer()), key.kex);
    } catch (_) {
      return key;
    }
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
    final fixedKeys = keys.map(_fixIncomingKexKey).toList();
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
        fixedKeys,
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
