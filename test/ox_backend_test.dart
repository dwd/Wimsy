import 'package:dart_pg/dart_pg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/encryption/encryption_backend.dart';
import 'package:wimsy/encryption/ox_backend.dart';
import 'package:wimsy/storage/storage_service.dart';

/// In-memory fake [StorageService]. We override only the OX methods (see
/// `lib/storage/storage_service.dart`) so [OxBackend] can be exercised
/// without spinning up Hive or the platform secure store, following the
/// same convention as `FakeStorageService` in `test/omemo2_backend_test.dart`.
class FakeStorageService extends StorageService {
  final Map<String, String> identities = {};
  final Map<String, String> publicKeys = {};
  final Map<String, List<String>> fingerprintLists = {};
  final Map<String, String> trust = {};

  @override
  Future<void> storeOxIdentity(String bareJid, String armoredPrivateKey) async {
    identities[bareJid] = armoredPrivateKey;
  }

  @override
  Future<String?> loadOxIdentity(String bareJid) async => identities[bareJid];

  @override
  Future<void> removeOxIdentity(String bareJid) async {
    identities.remove(bareJid);
  }

  @override
  Future<void> storeOxPublicKey(
    String bareJid,
    String fingerprint,
    String armoredPublicKey,
  ) async {
    publicKeys['$bareJid:$fingerprint'] = armoredPublicKey;
    final known = fingerprintLists[bareJid] ?? [];
    if (!known.contains(fingerprint)) {
      fingerprintLists[bareJid] = [...known, fingerprint];
    }
  }

  @override
  String? loadOxPublicKey(String bareJid, String fingerprint) =>
      publicKeys['$bareJid:$fingerprint'];

  @override
  List<String>? loadOxFingerprintList(String bareJid) =>
      fingerprintLists[bareJid];

  @override
  Future<void> storeTrustState(
    String bareJid,
    String deviceOrKeyId,
    String state,
  ) async {
    trust['$bareJid:$deviceOrKeyId'] = state;
  }

  @override
  String? loadTrustState(String bareJid, String deviceOrKeyId) =>
      trust['$bareJid:$deviceOrKeyId'];
}

/// Shared in-memory "PEP server" used by [FakeOxPep] so two [OxBackend]s in
/// the same test can discover each other's public keys without any real
/// XMPP connection.
class FakeOxNetwork {
  final Map<String, List<String>> metadata = {};
  final Map<String, String> publicKeys = {};
}

class FakeOxPep implements OxPepTransport {
  FakeOxPep(this.network, this.ownBareJid);

  final FakeOxNetwork network;
  final String ownBareJid;

  @override
  Future<void> publishMetadata(String fingerprint) async {
    network.metadata[ownBareJid] = [fingerprint];
  }

  @override
  Future<List<String>?> fetchMetadata(String bareJid) async {
    return network.metadata[bareJid];
  }

  @override
  Future<void> publishPublicKey(String fingerprint, String base64PublicKey) async {
    network.publicKeys['$ownBareJid:$fingerprint'] = base64PublicKey;
  }

  @override
  Future<String?> fetchPublicKey(String bareJid, String fingerprint) async {
    return network.publicKeys['$bareJid:$fingerprint'];
  }
}

void main() {
  const aliceJid = 'alice@example.org';
  const bobJid = 'bob@example.org';

  // Curve25519 keys are used throughout these tests (rather than the RSA
  // default used in production) purely to keep key generation fast.
  const testKeyType = KeyType.curve25519;
  const testCurve = Ecc.secp521r1;

  Future<OxBackend> createBackend(
    FakeOxNetwork network,
    FakeStorageService storage,
    String bareJid,
  ) {
    return OxBackend.create(
      selfBareJid: bareJid,
      storage: storage,
      pep: FakeOxPep(network, bareJid),
      keyType: testKeyType,
      curve: testCurve,
    );
  }

  test('OxBackend: generates and persists a key pair', () async {
    final network = FakeOxNetwork();
    final storage = FakeStorageService();
    final backend = await createBackend(network, storage, aliceJid);

    expect(backend.protocolId, 'ox');
    expect(backend.ownFingerprint, isNotEmpty);
    expect(storage.identities[aliceJid], isNotNull);
  });

  test('OxBackend: restores the same identity across restarts', () async {
    final network = FakeOxNetwork();
    final storage = FakeStorageService();

    final first = await createBackend(network, storage, aliceJid);
    final second = await createBackend(network, storage, aliceJid);

    expect(second.ownFingerprint, first.ownFingerprint);
  });

  test('OxBackend: publishes and fetches public keys via PEP', () async {
    final network = FakeOxNetwork();
    final aliceStorage = FakeStorageService();
    final bobStorage = FakeStorageService();

    final aliceBackend = await createBackend(network, aliceStorage, aliceJid);
    final bobBackend = await createBackend(network, bobStorage, bobJid);

    await aliceBackend.publishIdentity();
    await bobBackend.publishIdentity();

    final aliceKeysAsSeenByBob = await bobBackend.fetchPublicKeys(aliceJid);
    expect(aliceKeysAsSeenByBob, hasLength(1));
    expect(
      aliceKeysAsSeenByBob.first.fingerprint.toHexadecimal(),
      aliceBackend.ownFingerprint,
    );

    // The fetched key should now be cached locally too.
    expect(bobStorage.publicKeys.keys, contains('$aliceJid:${aliceBackend.ownFingerprint}'));
  });

  test('OxBackend: encrypt/decrypt/sign round-trip between two backends', () async {
    final network = FakeOxNetwork();
    final aliceStorage = FakeStorageService();
    final bobStorage = FakeStorageService();

    final aliceBackend = await createBackend(network, aliceStorage, aliceJid);
    final bobBackend = await createBackend(network, bobStorage, bobJid);

    await aliceBackend.publishIdentity();
    await bobBackend.publishIdentity();

    final payload = await aliceBackend.encryptForSend(bobJid, 'hello from alice');
    expect(payload.element.name, 'openpgp');
    expect(payload.element.getAttribute('xmlns')?.value, 'urn:xmpp:openpgp:0');

    final message = MessageStanza(
      AbstractStanza.getRandomId(),
      MessageStanzaType.CHAT,
    );
    message.fromJid = Jid.fromFullJid('$aliceJid/device1');
    message.addChild(payload.element);

    final result = await bobBackend.decryptIncoming(message);
    expect(result.error, isNull);
    expect(result.plaintext, 'hello from alice');
    expect(result.protocolId, 'ox');
    // The message was validly signed by Alice's key, so her fingerprint
    // should be recorded/trusted (at least Trust-on-First-Use).
    expect(result.senderTrust, isNot(TrustState.untrusted));
  });

  test(
    'OxBackend: decryptIncoming reports an error for a non-OX stanza',
    () async {
      final network = FakeOxNetwork();
      final storage = FakeStorageService();
      final backend = await createBackend(network, storage, bobJid);

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
    },
  );

  test('setTrust/trustStateFor round-trip for a verified key', () async {
    final network = FakeOxNetwork();
    final aliceStorage = FakeStorageService();
    final bobStorage = FakeStorageService();

    final aliceBackend = await createBackend(network, aliceStorage, aliceJid);
    final bobBackend = await createBackend(network, bobStorage, bobJid);
    await aliceBackend.publishIdentity();
    await bobBackend.publishIdentity();

    // Discover Bob's key so Alice has a trust entry for it.
    await aliceBackend.fetchPublicKeys(bobJid);

    expect(
      await aliceBackend.trustStateFor(
        bobJid,
        deviceOrKeyId: bobBackend.ownFingerprint,
      ),
      TrustState.tofu,
    );

    await aliceBackend.setTrust(
      bobJid,
      bobBackend.ownFingerprint,
      TrustState.verified,
    );
    expect(
      await aliceBackend.trustStateFor(
        bobJid,
        deviceOrKeyId: bobBackend.ownFingerprint,
      ),
      TrustState.verified,
    );
  });
}
