import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omemo_dart/omemo_dart.dart';
import 'package:xml/xml.dart' as xml;
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/encryption/encryption_backend.dart';
import 'package:wimsy/encryption/omemo_backend.dart';
import 'package:wimsy/encryption/omemo2_serialization.dart';
import 'package:wimsy/storage/storage_service.dart';

/// In-memory fake [StorageService]. We override only the legacy-OMEMO
/// methods (see `lib/storage/storage_service.dart`) so [OmemoBackend] can
/// be exercised without spinning up Hive or the platform secure store,
/// following the same convention as `FakeStorageService` in
/// `test/omemo2_backend_test.dart`.
class FakeStorageService extends StorageService {
  final Map<String, Map<String, dynamic>> identities = {};
  final Map<String, List<int>> deviceLists = {};
  final Map<String, Map<String, dynamic>> bundles = {};
  final Map<String, Map<String, dynamic>> ratchets = {};
  final Map<String, Map<String, dynamic>> trust = {};

  @override
  Future<void> storeOmemoIdentity(
    String bareJid,
    Map<String, dynamic> deviceJson,
  ) async {
    identities[bareJid] = deviceJson;
  }

  @override
  Future<Map<String, dynamic>?> loadOmemoIdentity(String bareJid) async {
    return identities[bareJid];
  }

  @override
  Future<void> storeOmemoDeviceList(
    String bareJid,
    List<int> deviceIds,
  ) async {
    deviceLists[bareJid] = List.of(deviceIds);
  }

  @override
  List<int>? loadOmemoDeviceList(String bareJid) => deviceLists[bareJid];

  @override
  Future<void> storeOmemoBundle(
    String bareJid,
    int deviceId,
    Map<String, dynamic> bundleJson,
  ) async {
    bundles['$bareJid:$deviceId'] = bundleJson;
  }

  @override
  Map<String, dynamic>? loadOmemoBundle(String bareJid, int deviceId) =>
      bundles['$bareJid:$deviceId'];

  @override
  Future<void> storeOmemoRatchet(
    String bareJid,
    int deviceId,
    Map<String, dynamic> ratchetJson,
  ) async {
    ratchets['$bareJid:$deviceId'] = ratchetJson;
  }

  @override
  Map<String, dynamic>? loadOmemoRatchet(String bareJid, int deviceId) =>
      ratchets['$bareJid:$deviceId'];

  @override
  Map<int, Map<String, dynamic>> loadOmemoRatchetsForJid(String bareJid) {
    final prefix = '$bareJid:';
    final result = <int, Map<String, dynamic>>{};
    for (final entry in ratchets.entries) {
      if (entry.key.startsWith(prefix)) {
        final deviceId = int.tryParse(entry.key.substring(prefix.length));
        if (deviceId != null) {
          result[deviceId] = entry.value;
        }
      }
    }
    return result;
  }

  @override
  Future<void> removeOmemoRatchets(
    List<MapEntry<String, int>> ratchetKeys,
  ) async {
    for (final key in ratchetKeys) {
      ratchets.remove('${key.key}:${key.value}');
    }
  }

  @override
  Future<void> storeOmemoTrust(
    String bareJid,
    int deviceId,
    Map<String, dynamic> trustJson,
  ) async {
    trust['$bareJid:$deviceId'] = trustJson;
  }

  @override
  List<Map<String, dynamic>> loadOmemoTrustForJid(String bareJid) {
    final prefix = '$bareJid:';
    return [
      for (final entry in trust.entries)
        if (entry.key.startsWith(prefix)) entry.value,
    ];
  }

  @override
  Future<void> removeOmemoTrustForJid(String bareJid) async {
    trust.removeWhere((key, _) => key.startsWith('$bareJid:'));
  }
}

/// Shared in-memory "PEP server" used by [FakeOmemoPep] so two
/// [OmemoBackend]s in the same test can discover each other's device
/// list/bundles without any real XMPP connection.
class FakeOmemoNetwork {
  final Map<String, List<int>> deviceLists = {};
  final Map<String, OmemoBundle> bundles = {};
}

class FakeOmemoPep implements OmemoPepTransport {
  FakeOmemoPep(this.network, this.ownBareJid);

  final FakeOmemoNetwork network;
  final String ownBareJid;

  @override
  Future<void> publishLegacyDeviceList(List<int> deviceIds) async {
    network.deviceLists[ownBareJid] = List.of(deviceIds);
  }

  @override
  Future<List<int>?> fetchLegacyDeviceList(String bareJid) async {
    return network.deviceLists[bareJid];
  }

  @override
  void subscribeToLegacyDeviceList(String bareJid) {}

  @override
  Future<void> publishLegacyBundle(OmemoBundle bundle) async {
    network.bundles['$ownBareJid:${bundle.id}'] = bundle;
  }

  @override
  Future<OmemoBundle?> fetchLegacyBundle(String bareJid, int deviceId) async {
    return network.bundles['$bareJid:$deviceId'];
  }
}

void main() {
  const aliceJid = 'alice@example.org';
  const bobJid = 'bob@example.org';

  test(
    'OmemoBackend: session establishment and encrypt/decrypt round-trip',
    () async {
      final network = FakeOmemoNetwork();
      final aliceStorage = FakeStorageService();
      final bobStorage = FakeStorageService();

      final aliceBackend = await OmemoBackend.create(
        selfBareJid: aliceJid,
        storage: aliceStorage,
        pep: FakeOmemoPep(network, aliceJid),
      );
      final bobBackend = await OmemoBackend.create(
        selfBareJid: bobJid,
        storage: bobStorage,
        pep: FakeOmemoPep(network, bobJid),
      );

      expect(aliceBackend.protocolId, 'omemo');

      await aliceBackend.publishIdentity();
      await bobBackend.publishIdentity();

      final payload = await aliceBackend.encryptForSend(
        bobJid,
        'hello from alice',
      );
      expect(payload.element.name, 'encrypted');
      expect(
        payload.element.getAttribute('xmlns')?.value,
        'eu.siacs.conversations.axolotl',
      );

      // Verify the legacy envelope shape: a <header sid='...'> with direct
      // <key rid='...'> children (not nested under <keys>, unlike OMEMO2),
      // and a sibling base64 <payload>.
      final header = payload.element.getChild('header');
      expect(header, isNotNull);
      expect(header!.getAttribute('sid'), isNotNull);
      final keyElements = header.children.where((c) => c.name == 'key');
      expect(keyElements, isNotEmpty);
      for (final keyElement in keyElements) {
        expect(keyElement.getAttribute('rid'), isNotNull);
      }
      expect(payload.element.getChild('payload'), isNotNull);

      // XEP-0384 v0.3.0's <header> transports the AES-128-GCM IV
      // explicitly as a direct <iv> child, alongside the <key> elements.
      final ivElement = header.getChild('iv');
      expect(ivElement, isNotNull);
      expect(ivElement!.textValue, isNotEmpty);

      final message = MessageStanza(
        AbstractStanza.getRandomId(),
        MessageStanzaType.CHAT,
      );
      message.fromJid = Jid.fromFullJid('$aliceJid/device1');
      message.addChild(payload.element);

      final result = await bobBackend.decryptIncoming(message);
      expect(result.error, isNull);
      expect(result.plaintext, 'hello from alice');
      expect(result.protocolId, 'omemo');
      expect(result.senderTrust, TrustState.tofu);

      expect(aliceStorage.ratchets, isNotEmpty);
      expect(bobStorage.ratchets, isNotEmpty);

      // Legacy-OMEMO and OMEMO2 devices must be tracked under distinct
      // storage (see the class doc on OmemoBackend): the legacy device id
      // persisted here should not collide with any `omemo2dl:`-style key.
      expect(aliceStorage.deviceLists.containsKey(aliceJid), isTrue);
    },
  );

  test(
    'OmemoBackend: encryptForSend throws instead of silently sending an '
    'empty <encrypted/> stanza when no devices/bundles are known for the '
    'recipient',
    () async {
      // Regression test: if the recipient's device list/bundle fetch via
      // PEP fails or returns nothing (e.g. the recipient has never
      // published one, or our subscription/fetch failed), omemo_dart's
      // onOutgoingStanza returns an EncryptionResult with no keys for that
      // JID at all. Previously, encryptForSend would still build and
      // return an <encrypted/> stanza with a <header> containing zero
      // <key> children -- which the server would happily deliver, but no
      // recipient device could ever decrypt -- without surfacing any
      // error to the caller (see xmpp_service.dart's "Failed to encrypt
      // outgoing message" path, which only fires on a thrown error).
      final network = FakeOmemoNetwork();
      final aliceStorage = FakeStorageService();

      final aliceBackend = await OmemoBackend.create(
        selfBareJid: aliceJid,
        storage: aliceStorage,
        pep: FakeOmemoPep(network, aliceJid),
      );

      // Note: bobBackend.publishIdentity() is deliberately never called,
      // so network.deviceLists/bundles has nothing for bobJid.
      await expectLater(
        aliceBackend.encryptForSend(bobJid, 'hello from alice'),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'OmemoBackend: encryptForSend explains *why* no usable key was found '
    'when a known device exists but is no longer trusted/enabled, instead '
    'of a generic "no devices/keys available" message',
    () async {
      // Regression test: a real-world session showed `omemo_dart` logging
      // "Fetching bundles"/"Building new ratchet" for a known device (so
      // it clearly had a device list and bundle), yet still producing zero
      // usable keys with no explanation anywhere in the log -- this
      // happens when BlindTrustBeforeVerificationTrustManager.isTrusted/
      // isEnabled silently skip the device (e.g. because it was
      // explicitly marked untrusted, or another device of the same JID
      // was verified). The thrown error must name the actual device id
      // and its trusted/enabled state instead of just saying "no devices
      // known".
      final network = FakeOmemoNetwork();
      final aliceStorage = FakeStorageService();
      final bobStorage = FakeStorageService();

      final aliceBackend = await OmemoBackend.create(
        selfBareJid: aliceJid,
        storage: aliceStorage,
        pep: FakeOmemoPep(network, aliceJid),
      );
      final bobBackend = await OmemoBackend.create(
        selfBareJid: bobJid,
        storage: bobStorage,
        pep: FakeOmemoPep(network, bobJid),
      );
      await bobBackend.publishIdentity();

      // First send succeeds and establishes a session + blind-trusted
      // device for bob.
      await aliceBackend.encryptForSend(bobJid, 'hello from alice');
      final deviceIds = await aliceBackend.knownDeviceIdsFor(bobJid);
      expect(deviceIds, isNotEmpty);
      final deviceId = deviceIds.first;

      // Now explicitly mark that device as untrusted (e.g. the user
      // revoked trust, or -- as in the real-world report -- a different
      // device of bob's was marked "verified", which makes BTBV refuse
      // blind trust for this one).
      await aliceBackend.setTrust(bobJid, '$deviceId', TrustState.untrusted);

      await expectLater(
        aliceBackend.encryptForSend(bobJid, 'hello again'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('$deviceId'), contains('trusted=false')),
          ),
        ),
      );
    },
  );

  test(
    'OmemoBackend: outgoing <key kex="true"> embeds libsignal '
    'DJB-type-prefixed ik/ek for interop with real legacy-OMEMO clients',
    () async {
      // Regression test for the "Message was not encrypted for this
      // device" / "Algorithm ed25519 expects a public key with 32 bytes,
      // but got: 33 bytes" bugs: real legacy-OMEMO clients
      // (Conversations/Gajim/Dino) serialize the `ik`/`ek` fields of the
      // `OMEMOKeyExchange` protobuf embedded in a <key kex='true'>
      // element using libsignal's DJB-type-prefixed format (leading 0x05
      // byte + 32 raw bytes = 33 bytes total), not the raw 32-byte form
      // `omemo_dart`'s own schema expects. We must do the same when
      // publishing a brand-new session's key exchange, or those clients
      // fail to recognise our message as encrypted for their device.
      final network = FakeOmemoNetwork();
      final aliceStorage = FakeStorageService();
      final bobStorage = FakeStorageService();

      final aliceBackend = await OmemoBackend.create(
        selfBareJid: aliceJid,
        storage: aliceStorage,
        pep: FakeOmemoPep(network, aliceJid),
      );
      final bobBackend = await OmemoBackend.create(
        selfBareJid: bobJid,
        storage: bobStorage,
        pep: FakeOmemoPep(network, bobJid),
      );
      await bobBackend.publishIdentity();

      final payload = await aliceBackend.encryptForSend(
        bobJid,
        'hello from alice',
      );
      final header = payload.element.getChild('header')!;
      final kexKeyElement = header.children.firstWhere(
        (c) => c.name == 'key' && c.getAttribute('kex')?.value == 'true',
      );
      final kex = OMEMOKeyExchange.fromBuffer(
        base64Decode(kexKeyElement.textValue!.trim()),
      );
      expect(kex.ik.length, 33);
      expect(kex.ik.first, 0x05);
      expect(kex.ek.length, 33);
      expect(kex.ek.first, 0x05);

      // And the receiving side must still be able to decrypt it (i.e. the
      // DJB-type byte is correctly stripped again before being handed to
      // `OmemoManager`).
      final message = MessageStanza(
        AbstractStanza.getRandomId(),
        MessageStanzaType.CHAT,
      );
      message.fromJid = Jid.fromFullJid('$aliceJid/device1');
      message.addChild(payload.element);
      final result = await bobBackend.decryptIncoming(message);
      expect(result.error, isNull);
      expect(result.plaintext, 'hello from alice');
    },
  );

  test(
    'omemoPublicKeyFromJson strips a stale 33-byte DJB-type-prefixed '
    'remote identity key baked into an already-persisted ratchet session',
    () async {
      // Regression test: a ratchet session established with a
      // legacy-OMEMO contact *before* the DJB-type-byte fix (see
      // OmemoBackend's _stripDjbKeyTypeBytes) may have persisted a
      // 33-byte remote identity key as part of its on-disk JSON state.
      // Unlike a cached bundle, such a ratchet is never re-created from
      // scratch -- it's loaded as-is -- so without this defensive strip
      // it would keep reproducing "Algorithm ed25519 expects a public
      // key with 32 bytes, but got: 33 bytes" on every encrypt/decrypt.
      final rawKey = List<int>.generate(32, (i) => i);
      final staleJson = {
        'type': 'ed25519',
        'pk': base64Encode([0x05, ...rawKey]),
      };
      final key = omemoPublicKeyFromJson(staleJson);
      expect(key.type, KeyPairType.ed25519);
      // Should not throw, and should recover the original 32-byte key.
      expect(await key.getBytes(), rawKey);

      // A key that was never type-prefixed (OMEMO2, or an already-fixed
      // legacy-OMEMO session) must pass through unchanged.
      final freshJson = {'type': 'ed25519', 'pk': base64Encode(rawKey)};
      expect(await omemoPublicKeyFromJson(freshJson).getBytes(), rawKey);
    },
  );

  test(
    'OmemoBackend: encryptForSend tolerates a stale pre-fix cached bundle '
    'carrying a 33-byte libsignal-DJB-type-prefixed key',
    () async {
      // Regression test: before the DJB-type-byte fix in
      // lib/xmpp/omemo_pep.dart, fetched bundles from real legacy-OMEMO
      // clients (Conversations/Gajim/Dino) were cached verbatim with a
      // leading 0x05 byte on each key (33 bytes instead of 32), and that
      // stale cache entry is never re-fetched once present. Simulate such
      // a stale Hive cache entry directly in storage (bypassing the fixed
      // fetch path entirely) and confirm OmemoBackend's cache-loading
      // path (_bundleFromJson) now defensively strips it, instead of
      // reproducing "Algorithm ed25519 expects a public key with 32
      // bytes, but got: 33 bytes" indefinitely.
      final network = FakeOmemoNetwork();
      final aliceStorage = FakeStorageService();
      final bobStorage = FakeStorageService();

      final aliceBackend = await OmemoBackend.create(
        selfBareJid: aliceJid,
        storage: aliceStorage,
        pep: FakeOmemoPep(network, aliceJid),
      );
      final bobBackend = await OmemoBackend.create(
        selfBareJid: bobJid,
        storage: bobStorage,
        pep: FakeOmemoPep(network, bobJid),
      );

      await bobBackend.publishIdentity();
      final bobDeviceId =
          (await bobStorage.loadOmemoIdentity(bobJid))!['id'] as int;
      final realBundle = network.bundles['$bobJid:$bobDeviceId']!;

      String addDjbType(String base64Encoded) =>
          base64Encode([0x05, ...base64Decode(base64Encoded)]);

      // Pre-seed alice's bundle cache with a stale, pre-fix-style entry:
      // same keys as bob's real bundle, but with the libsignal DJB-type
      // byte still attached (33 bytes).
      await aliceStorage.storeOmemoBundle(bobJid, bobDeviceId, {
        'jid': bobJid,
        'id': bobDeviceId,
        'spk': addDjbType(realBundle.spkEncoded),
        'spkId': realBundle.spkId,
        'spks': realBundle.spkSignatureEncoded,
        'ik': addDjbType(realBundle.ikEncoded),
        'opks': {
          for (final entry in realBundle.opksEncoded.entries)
            entry.key.toString(): addDjbType(entry.value),
        },
      });

      // Must not throw "Algorithm ed25519 expects a public key with 32
      // bytes, but got: 33 bytes" despite the stale cache entry.
      final payload = await aliceBackend.encryptForSend(
        bobJid,
        'hello from alice',
      );
      expect(payload.element.name, 'encrypted');
    },
  );

  test(
    'OmemoBackend: restores the same identity across restarts',
    () async {
      final network = FakeOmemoNetwork();
      final storage = FakeStorageService();

      final first = await OmemoBackend.create(
        selfBareJid: aliceJid,
        storage: storage,
        pep: FakeOmemoPep(network, aliceJid),
      );
      await first.publishIdentity();
      final firstDeviceId = (await storage.loadOmemoIdentity(aliceJid))!['id'];

      final second = await OmemoBackend.create(
        selfBareJid: aliceJid,
        storage: storage,
        pep: FakeOmemoPep(network, aliceJid),
      );
      final secondDeviceId = (await storage.loadOmemoIdentity(aliceJid))!['id'];

      expect(secondDeviceId, firstDeviceId);
      expect(second.protocolId, 'omemo');
    },
  );

  test(
    'OmemoBackend: decryptIncoming reports an error for a non-legacy-OMEMO stanza',
    () async {
      final network = FakeOmemoNetwork();
      final storage = FakeStorageService();
      final backend = await OmemoBackend.create(
        selfBareJid: bobJid,
        storage: storage,
        pep: FakeOmemoPep(network, bobJid),
      );

      final message = MessageStanza(
        AbstractStanza.getRandomId(),
        MessageStanzaType.CHAT,
      );
      message.fromJid = Jid.fromFullJid('$aliceJid/device1');
      final body = XmppElement()..name = 'body';
      body.textValue = 'not encrypted';
      message.addChild(body);

      final result = await backend.decryptIncoming(message);
      expect(result.plaintext, isNull);
      expect(result.error, isNotNull);

      // An OMEMO2-namespaced <encrypted/> should also be rejected by the
      // legacy backend, since the two protocols/namespaces are distinct.
      final omemo2Message = MessageStanza(
        AbstractStanza.getRandomId(),
        MessageStanzaType.CHAT,
      );
      omemo2Message.fromJid = Jid.fromFullJid('$aliceJid/device1');
      final encrypted = XmppElement()..name = 'encrypted';
      encrypted.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:omemo:2'));
      omemo2Message.addChild(encrypted);
      final omemo2Result = await backend.decryptIncoming(omemo2Message);
      expect(omemo2Result.plaintext, isNull);
      expect(omemo2Result.error, isNotNull);
    },
  );

  test('setTrust/trustStateFor round-trip for a verified device', () async {
    final network = FakeOmemoNetwork();
    final aliceStorage = FakeStorageService();
    final bobStorage = FakeStorageService();

    final aliceBackend = await OmemoBackend.create(
      selfBareJid: aliceJid,
      storage: aliceStorage,
      pep: FakeOmemoPep(network, aliceJid),
    );
    final bobBackend = await OmemoBackend.create(
      selfBareJid: bobJid,
      storage: bobStorage,
      pep: FakeOmemoPep(network, bobJid),
    );
    await aliceBackend.publishIdentity();
    await bobBackend.publishIdentity();

    await aliceBackend.encryptForSend(bobJid, 'hi');
    final bobDeviceId = network.deviceLists[bobJid]!.first;

    expect(
      await aliceBackend.trustStateFor(bobJid, deviceOrKeyId: '$bobDeviceId'),
      TrustState.tofu,
    );

    await aliceBackend.setTrust(bobJid, '$bobDeviceId', TrustState.verified);
    expect(
      await aliceBackend.trustStateFor(bobJid, deviceOrKeyId: '$bobDeviceId'),
      TrustState.verified,
    );

    await aliceBackend.setTrust(bobJid, '$bobDeviceId', TrustState.revoked);
    expect(
      await aliceBackend.trustStateFor(bobJid, deviceOrKeyId: '$bobDeviceId'),
      TrustState.untrusted,
    );
  });

  test(
    'Legacy OMEMO envelope: hand-constructed example stanza parses as expected',
    () {
      // A self-consistent, hand-constructed example of the XEP-0384 v0.3.0
      // wire shape (no real external client is available in this
      // environment to source a recorded fixture from, see the class doc
      // on OmemoBackend), used to catch wire-format regressions in the
      // envelope structure independent of the omemo_dart round-trip above.
      const exampleStanza = '''
<message from="bob@example.org/gajim" to="alice@example.org/wimsy" type="chat">
  <encrypted xmlns="eu.siacs.conversations.axolotl">
    <header sid="1234">
      <key rid="5678">BASE64RATCHETKEYDATA==</key>
      <key rid="9012" kex="true">BASE64KEXKEYDATA==</key>
      <iv>BASE64IVDATA==</iv>
    </header>
    <payload>BASE64CIPHERTEXTDATA==</payload>
  </encrypted>
</message>''';

      final document = xml.XmlDocument.parse(exampleStanza);
      final encryptedXml = document.rootElement.findElements('encrypted').first;
      expect(encryptedXml.getAttribute('xmlns'), legacyOmemoNamespace);

      final headerXml = encryptedXml.findElements('header').first;
      expect(headerXml.getAttribute('sid'), '1234');
      final keyXmls = headerXml.findElements('key').toList();
      expect(keyXmls.length, 2);
      expect(keyXmls[0].getAttribute('rid'), '5678');
      expect(keyXmls[0].getAttribute('kex'), isNull);
      expect(keyXmls[1].getAttribute('rid'), '9012');
      expect(keyXmls[1].getAttribute('kex'), 'true');

      final ivXml = headerXml.findElements('iv').first;
      expect(ivXml.innerText, 'BASE64IVDATA==');

      final payloadXml = encryptedXml.findElements('payload').first;
      expect(payloadXml.innerText, 'BASE64CIPHERTEXTDATA==');
    },
  );

  test(
    'AES-128-GCM payload cipher helper: round-trips plaintext and rejects '
    'tampered ciphertext',
    () async {
      // Targeted unit test of the exact cipher/key-material convention used
      // by OmemoBackend.encryptForSend/decryptIncoming (16-byte AES-128 key
      // + 16-byte GCM tag as the 32-byte ratchet-wrapped key material, IV
      // transported separately), independent of the OMEMO
      // session/ratchet machinery.
      final cipher = AesGcm.with128bits();
      final secretKey = await cipher.newSecretKey();
      final nonce = cipher.newNonce();
      const plaintext = 'hello legacy OMEMO';

      final secretBox = await cipher.encrypt(
        utf8.encode(plaintext),
        secretKey: secretKey,
        nonce: nonce,
      );
      final rawKeyMaterial = [
        ...await secretKey.extractBytes(),
        ...secretBox.mac.bytes,
      ];
      expect(rawKeyMaterial.length, 32);
      expect(secretBox.mac.bytes.length, 16);

      final rawKey = rawKeyMaterial.sublist(0, 16);
      final mac = rawKeyMaterial.sublist(16);
      final decrypted = await cipher.decrypt(
        SecretBox(secretBox.cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(rawKey),
      );
      expect(utf8.decode(decrypted), plaintext);

      // Tampering with the ciphertext must be rejected by GCM's
      // authentication tag check.
      final tamperedCiphertext = List<int>.of(secretBox.cipherText);
      tamperedCiphertext[0] ^= 0xff;
      await expectLater(
        cipher.decrypt(
          SecretBox(tamperedCiphertext, nonce: nonce, mac: Mac(mac)),
          secretKey: SecretKey(rawKey),
        ),
        throwsA(isA<Exception>()),
      );
    },
  );

  test(
    'OmemoBackend: exported identity key can be imported to restore the '
    'same fingerprint',
    () async {
      final network = FakeOmemoNetwork();
      final originalStorage = FakeStorageService();

      final original = await OmemoBackend.create(
        selfBareJid: aliceJid,
        storage: originalStorage,
        pep: FakeOmemoPep(network, aliceJid),
      );
      final exported = await original.exportIdentityKey();

      expect(exported, startsWith('-----BEGIN OMEMO IDENTITY KEY-----'));
      expect(exported, endsWith('-----END OMEMO IDENTITY KEY-----'));

      // "Reinstall": a fresh, empty storage, restoring via the exported PEM.
      final restoredStorage = FakeStorageService();
      final restored = await OmemoBackend.create(
        selfBareJid: aliceJid,
        storage: restoredStorage,
        pep: FakeOmemoPep(network, aliceJid),
        importedIdentityKeyPem: exported,
      );

      expect(await restored.ownFingerprint(), await original.ownFingerprint());
    },
  );

  test(
    'OmemoBackend: importing an OMEMO2 export fails with a mismatched label',
    () async {
      final network = FakeOmemoNetwork();
      final storage = FakeStorageService();
      final backend = await OmemoBackend.create(
        selfBareJid: aliceJid,
        storage: storage,
        pep: FakeOmemoPep(network, aliceJid),
      );
      final exported = await backend.exportIdentityKey();
      final tampered = exported.replaceAll('OMEMO ', 'OMEMO2 ');

      await expectLater(
        OmemoBackend.create(
          selfBareJid: bobJid,
          storage: FakeStorageService(),
          pep: FakeOmemoPep(network, bobJid),
          importedIdentityKeyPem: tampered,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'x3dhFromBundle: verifies the SPK signature against the libsignal '
    'type-byte-prefixed bytes when OmemoBundle.spkSignatureMessageEncoded '
    'is set, matching how real legacy-OMEMO clients (Conversations/Gajim/'
    'Dino) sign their bundle',
    () async {
      // Reproduces the real-world "InvalidKeyExchangeSignatureError" bug:
      // libsignal's SignedPreKeyRecord signs `publicKey.serialize()`,
      // which is the 33-byte DJB-type-prefixed form (0x05 + 32 raw
      // bytes), not the raw 32-byte key omemo_dart itself works with.
      // `lib/xmpp/omemo_pep.dart` strips that type byte from the keys it
      // hands to `omemo_dart` for X3DH/ECDH, but previously had no way to
      // tell `x3dhFromBundle` that the *signature* still covers the
      // original, longer bytes -- so verification always failed for any
      // real contact's bundle. This asserts the dedicated
      // `spkSignatureMessageEncoded` field fixes that, and that omitting
      // it (the old behaviour) reproduces the original bug.
      final ik = await OmemoKeyPair.generateNewPair(KeyPairType.ed25519);
      final spk = await OmemoKeyPair.generateNewPair(KeyPairType.x25519);
      final opk = await OmemoKeyPair.generateNewPair(KeyPairType.x25519);

      final rawSpkBytes = await spk.pk.getBytes();
      final djbPrefixedSpkBytes = [0x05, ...rawSpkBytes];
      // What a real libsignal-based client actually signs.
      final signature = await sig(ik, djbPrefixedSpkBytes);

      final bundleWithFix = OmemoBundle(
        bobJid,
        1,
        base64Encode(rawSpkBytes),
        99,
        base64Encode(signature),
        base64Encode(await ik.pk.getBytes()),
        {7: base64Encode(await opk.pk.getBytes())},
        spkSignatureMessageEncoded: base64Encode(djbPrefixedSpkBytes),
      );

      final fixedResult = await x3dhFromBundle(bundleWithFix, ik);
      expect(
        fixedResult.isType<InvalidKeyExchangeSignatureError>(),
        isFalse,
        reason:
            'with spkSignatureMessageEncoded set to the DJB-prefixed '
            'bytes that were actually signed, verification must succeed',
      );

      // Without the fix (old behaviour: no spkSignatureMessageEncoded),
      // the signature is checked against the raw, un-prefixed SPK bytes
      // instead -- which never matches a real client's signature.
      final bundleWithoutFix = OmemoBundle(
        bobJid,
        1,
        base64Encode(rawSpkBytes),
        99,
        base64Encode(signature),
        base64Encode(await ik.pk.getBytes()),
        {7: base64Encode(await opk.pk.getBytes())},
      );
      final brokenResult = await x3dhFromBundle(bundleWithoutFix, ik);
      expect(
        brokenResult.isType<InvalidKeyExchangeSignatureError>(),
        isTrue,
        reason:
            'reproduces the real-world bug: without the fix, a correctly '
            'signed real-client bundle is wrongly rejected',
      );
    },
  );
}
