import 'dart:convert';
import 'dart:typed_data';

// ignore_for_file: implementation_imports
import 'package:dart_pg/dart_pg.dart';
import 'package:dart_pg/src/type/key.dart';
import 'package:xml/xml.dart' as xml;
import 'package:xmpp_stone/xmpp_stone.dart';

import '../storage/storage_service.dart';
import 'encryption_backend.dart';
import 'trust_store.dart';

/// The `urn:xmpp:openpgp:0` namespace, mirrored from `lib/xmpp/ox_pep.dart`
/// (kept as a local constant here to avoid this file depending on the
/// XMPP-transport-specific [OxPep] class), matching the convention used by
/// `lib/encryption/omemo2_backend.dart`.
const String oxNamespace = 'urn:xmpp:openpgp:0';

/// The subset of `OxPep` (see `lib/xmpp/ox_pep.dart`) that [OxBackend]
/// depends on, extracted as an interface so tests can supply an in-memory
/// fake instead of a real `Connection`, mirroring
/// `Omemo2PepTransport`/`OmemoPepTransport`.
abstract class OxPepTransport {
  Future<void> publishMetadata(String fingerprint);
  Future<List<String>?> fetchMetadata(String bareJid);
  Future<void> publishPublicKey(String fingerprint, String base64PublicKey);
  Future<String?> fetchPublicKey(String bareJid, String fingerprint);
}

/// A single OX (OpenPGP) public key belonging to a contact, as surfaced to
/// the fingerprint verification UI (see
/// `lib/widgets/fingerprint_verification_screen.dart`): its hex
/// fingerprint and current [TrustState].
class OxKeyFingerprint {
  OxKeyFingerprint({required this.fingerprint, required this.trust});

  final String fingerprint;
  final TrustState trust;
}

/// `urn:xmpp:openpgp:0` (XEP-0373 "OpenPGP for XMPP" / XEP-0374 "OpenPGP for
/// XMPP: Instant Messaging") [EncryptionBackend], wrapping `dart_pg`'s pure
/// Dart OpenPGP implementation for key generation/encryption/signing, and
/// persisting state via [StorageService] (Hive for cached peer public
/// keys/fingerprint lists) and the platform secure store (for the local
/// private key), through the OX PEP nodes published/fetched by
/// [OxPepTransport].
///
/// Per XEP-0374, an outgoing message wraps an `openpgp` element (in the
/// `urn:xmpp:openpgp:0` namespace) whose text content is the base64
/// encoding of an OpenPGP encrypted-and-signed message. The plaintext
/// inside that OpenPGP message is itself an XML `envelope` document
/// (`urn:xmpp:openpgp:0` namespace) wrapping a `payload` element containing
/// a `body` (`jabber:client` namespace) element (XEP-0373 §3, XEP-0374 §3).
class OxBackend implements EncryptionBackend {
  OxBackend._(
    this.selfBareJid,
    this.storage,
    this.pep,
    this._privateKey,
    this.trustStore,
  );

  @override
  String get protocolId => 'ox';

  final String selfBareJid;
  final StorageService storage;
  final OxPepTransport pep;

  /// Generic, protocol-agnostic trust store (see
  /// `lib/encryption/trust_store.dart`), keyed by bareJid + OpenPGP key
  /// fingerprint (as the "device/key id"), consistent with how
  /// [Omemo2Backend]/`OmemoBackend` key trust by device id.
  final TrustStore trustStore;

  final PrivateKeyInterface _privateKey;

  /// Our own key's hex fingerprint, used as the trust-store/PEP-node key.
  String get ownFingerprint => _privateKey.fingerprint.toHexadecimal();

  /// Creates (or restores, if a key was already persisted) an [OxBackend]
  /// for [selfBareJid]. If no key has been generated/imported yet, a new
  /// 4096-bit RSA key pair is generated (matching the key size/type many
  /// existing OX deployments use for broad client compatibility).
  static Future<OxBackend> create({
    required String selfBareJid,
    required StorageService storage,
    required OxPepTransport pep,
    TrustStore? trustStore,
    // Exposed mainly so tests can request a cheaper key type (e.g.
    // [KeyType.ecc] with [Ecc.curve25519]) than the RSA default, since RSA
    // key generation is comparatively slow.
    KeyType keyType = KeyType.rsa,
    RSAKeySize rsaKeySize = RSAKeySize.normal,
    Ecc curve = Ecc.secp521r1,
  }) async {
    final privateKey = await _loadOrGenerateKey(
      selfBareJid,
      storage,
      keyType: keyType,
      rsaKeySize: rsaKeySize,
      curve: curve,
    );
    final sharedTrustStore = trustStore ?? TrustStore(storage);
    return OxBackend._(
      selfBareJid,
      storage,
      pep,
      privateKey,
      sharedTrustStore,
    );
  }

  static Future<PrivateKeyInterface> _loadOrGenerateKey(
    String selfBareJid,
    StorageService storage, {
    required KeyType keyType,
    required RSAKeySize rsaKeySize,
    required Ecc curve,
  }) async {
    final armored = await storage.loadOxIdentity(selfBareJid);
    if (armored != null) {
      return OpenPGP.readPrivateKey(armored);
    }
    // dart_pg requires a non-empty passphrase to generate a key (the
    // freshly generated key is locked with it); since the resulting
    // private key is persisted in the platform secure store (which already
    // protects it at rest), we immediately unlock it with that same
    // one-off passphrase and persist the unlocked form, matching how
    // [Omemo2Backend]/`OmemoBackend` persist their identity keys unlocked.
    const generationPassphrase = 'wimsy-ox-key-generation';
    final generated = OpenPGP.generateKey(
      [selfBareJid],
      generationPassphrase,
      type: keyType,
      rsaKeySize: rsaKeySize,
      curve: curve,
    );
    final key = generated.decrypt(generationPassphrase);
    await storage.storeOxIdentity(selfBareJid, key.armor());
    return key;
  }

  /// Imports [armoredPrivateKey] (optionally protected by [passphrase]) as
  /// the local OX identity for [selfBareJid], replacing any previously
  /// generated/imported key. Returns the resulting [OxBackend].
  static Future<OxBackend> importKey({
    required String selfBareJid,
    required StorageService storage,
    required OxPepTransport pep,
    required String armoredPrivateKey,
    String passphrase = '',
    TrustStore? trustStore,
  }) async {
    var privateKey = OpenPGP.readPrivateKey(armoredPrivateKey);
    if (passphrase.isNotEmpty) {
      privateKey = privateKey.decrypt(passphrase);
    }
    await storage.storeOxIdentity(selfBareJid, privateKey.armor());
    return OxBackend._(
      selfBareJid,
      storage,
      pep,
      privateKey,
      trustStore ?? TrustStore(storage),
    );
  }

  /// Publishes our own public key via PEP per XEP-0373: the
  /// `urn:xmpp:openpgp:0:public-keys:<fingerprint>` node (the armored
  /// public key, base64-encoded), plus the `urn:xmpp:openpgp:0:metadata`
  /// node listing our current fingerprint.
  @override
  Future<void> publishIdentity() async {
    final publicKey = _privateKey.publicKey;
    final base64PublicKey = base64Encode(utf8.encode(publicKey.armor()));
    await pep.publishPublicKey(ownFingerprint, base64PublicKey);
    await pep.publishMetadata(ownFingerprint);
  }

  /// Fetches (and caches) [bareJid]'s current OX public key(s) via the
  /// `urn:xmpp:openpgp:0:metadata` and `urn:xmpp:openpgp:0:public-keys:*`
  /// PEP nodes. Returns the fetched [KeyInterface]s (empty if none could be
  /// retrieved).
  Future<List<KeyInterface>> fetchPublicKeys(String bareJid) async {
    final cachedFingerprints = storage.loadOxFingerprintList(bareJid);
    final fingerprints = await pep.fetchMetadata(bareJid) ?? cachedFingerprints;
    if (fingerprints == null || fingerprints.isEmpty) {
      return const [];
    }
    final keys = <KeyInterface>[];
    for (final fingerprint in fingerprints) {
      final cached = storage.loadOxPublicKey(bareJid, fingerprint);
      if (cached != null) {
        keys.add(OpenPGP.readPublicKey(cached));
        await trustStore.trustStateFor(bareJid, fingerprint);
        continue;
      }
      final base64Key = await pep.fetchPublicKey(bareJid, fingerprint);
      if (base64Key == null) {
        continue;
      }
      final armored = utf8.decode(base64Decode(base64Key));
      await storage.storeOxPublicKey(bareJid, fingerprint, armored);
      keys.add(OpenPGP.readPublicKey(armored));
      await trustStore.trustStateFor(bareJid, fingerprint);
    }
    return keys;
  }

  @override
  Future<EncryptedPayload> encryptForSend(
    String toBareJid,
    String plaintext,
  ) async {
    final recipientKeys = await fetchPublicKeys(toBareJid);
    if (recipientKeys.isEmpty) {
      throw StateError('No known OX public key for $toBareJid');
    }

    // XEP-0373 §3 / XEP-0374 §3: the plaintext OpenPGP payload is an
    // <envelope/> wrapping a <payload/> containing the stanza child
    // element(s) being protected -- here, just the message <body/>.
    final envelope = XmppElement()..name = 'envelope';
    envelope.addAttribute(XmppAttribute('xmlns', oxNamespace));
    final payloadElement = XmppElement()..name = 'payload';
    final body = XmppElement()..name = 'body';
    body.addAttribute(XmppAttribute('xmlns', 'jabber:client'));
    body.textValue = plaintext;
    payloadElement.addChild(body);
    envelope.addChild(payloadElement);

    final literalMessage = OpenPGP.createLiteralMessage(
      utf8.encode(envelope.buildXmlString()),
    );
    final encryptedMessage = OpenPGP.encrypt(
      literalMessage,
      encryptionKeys: [...recipientKeys, _privateKey.publicKey],
      signingKeys: [_privateKey],
    );

    final openpgp = XmppElement()..name = 'openpgp';
    openpgp.addAttribute(XmppAttribute('xmlns', oxNamespace));
    openpgp.textValue = base64Encode(utf8.encode(encryptedMessage.armor()));

    return EncryptedPayload(
      element: openpgp,
      fallbackBody:
          'This message is encrypted with OX '
          '(https://xmpp.org/extensions/xep-0373.html) but your client '
          'does not support it.',
    );
  }

  @override
  Future<DecryptResult> decryptIncoming(XmppElement stanza) async {
    final openpgp = stanza.name == 'openpgp'
        ? stanza
        : stanza.getChild('openpgp');
    if (openpgp == null || openpgp.getAttribute('xmlns')?.value != oxNamespace) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: TrustState.untrusted,
        error: 'Stanza does not contain an OX <openpgp/> element',
      );
    }
    final fromJid = stanza.getAttribute('from')?.value;
    final bareSenderJid = fromJid == null
        ? null
        : Jid.fromFullJid(fromJid).userAtDomain;
    if (bareSenderJid == null) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: TrustState.untrusted,
        error: 'Missing sender JID on <openpgp/>',
      );
    }

    final base64Payload = openpgp.textValue?.trim();
    if (base64Payload == null || base64Payload.isEmpty) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: await trustStateFor(bareSenderJid),
        error: 'Empty OX <openpgp/> payload',
      );
    }

    try {
      final armored = utf8.decode(base64Decode(base64Payload));
      final decrypted = OpenPGP.decrypt(
        armored,
        decryptionKeys: [_privateKey],
      );

      final senderKeys = await fetchPublicKeys(bareSenderJid);
      String? verifiedFingerprint;
      if (senderKeys.isNotEmpty) {
        final verifications = decrypted.verify(senderKeys);
        for (final verification in verifications) {
          if (!verification.isVerified) {
            continue;
          }
          for (final key in senderKeys) {
            if (_bytesEqual(key.keyID, verification.keyID)) {
              verifiedFingerprint = key.fingerprint.toHexadecimal();
              break;
            }
          }
        }
      }

      final plaintext = _extractEnvelopeBody(
        utf8.decode(decrypted.literalData.binary),
      );

      return DecryptResult(
        plaintext: plaintext,
        protocolId: protocolId,
        senderTrust: await trustStateFor(
          bareSenderJid,
          deviceOrKeyId: verifiedFingerprint,
        ),
        error: plaintext == null ? 'Malformed OX envelope' : null,
      );
    } catch (e) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: await trustStateFor(bareSenderJid),
        error: 'Failed to decrypt OX message: $e',
      );
    }
  }

  /// Extracts the plaintext `<body/>` text from a serialised XEP-0373/0374
  /// `<envelope/>` (see [encryptForSend]), or `null` if the payload isn't
  /// in the expected shape.
  String? _extractEnvelopeBody(String envelopeXml) {
    try {
      final document = xml.XmlDocument.parse(envelopeXml);
      final body = document.rootElement
          .findElements('payload')
          .firstOrNull
          ?.findElements('body')
          .firstOrNull;
      return body?.innerText.trim();
    } catch (_) {
      return null;
    }
  }

  /// Every known OX public key fingerprint (and its [TrustState]) cached
  /// for [bareJid], for the fingerprint verification screen.
  Future<List<OxKeyFingerprint>> keyFingerprintsFor(String bareJid) async {
    final fingerprints = storage.loadOxFingerprintList(bareJid) ?? const [];
    final result = <OxKeyFingerprint>[];
    for (final fingerprint in fingerprints) {
      result.add(
        OxKeyFingerprint(
          fingerprint: fingerprint,
          trust: await trustStore.trustStateFor(bareJid, fingerprint),
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
    final fingerprints = storage.loadOxFingerprintList(bareJid) ?? const [];
    if (fingerprints.isEmpty) {
      return TrustState.untrusted;
    }
    final states = [
      for (final fingerprint in fingerprints)
        await trustStore.trustStateFor(bareJid, fingerprint),
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
    await trustStore.setTrust(bareJid, deviceOrKeyId, state);
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
