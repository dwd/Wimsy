import 'package:flutter_test/flutter_test.dart';
import 'package:omemo_dart/omemo_dart.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/encryption/encryption_backend.dart';
import 'package:wimsy/encryption/omemo2_backend.dart';
import 'package:wimsy/storage/storage_service.dart';

/// In-memory fake [StorageService]. We override only the OMEMO2 methods
/// (see `lib/storage/storage_service.dart`) so [Omemo2Backend] can be
/// exercised without spinning up Hive or the platform secure store,
/// following the same convention as `FakeStorageService` in
/// `test/pep_manager_test.dart`.
class FakeStorageService extends StorageService {
  final Map<String, Map<String, dynamic>> identities = {};
  final Map<String, List<int>> deviceLists = {};
  final Map<String, Map<String, dynamic>> bundles = {};
  final Map<String, Map<String, dynamic>> ratchets = {};
  final Map<String, Map<String, dynamic>> trust = {};

  @override
  Future<void> storeOmemo2Identity(
    String bareJid,
    Map<String, dynamic> deviceJson,
  ) async {
    identities[bareJid] = deviceJson;
  }

  @override
  Future<Map<String, dynamic>?> loadOmemo2Identity(String bareJid) async {
    return identities[bareJid];
  }

  @override
  Future<void> storeOmemo2DeviceList(
    String bareJid,
    List<int> deviceIds,
  ) async {
    deviceLists[bareJid] = List.of(deviceIds);
  }

  @override
  List<int>? loadOmemo2DeviceList(String bareJid) => deviceLists[bareJid];

  @override
  Future<void> storeOmemo2Bundle(
    String bareJid,
    int deviceId,
    Map<String, dynamic> bundleJson,
  ) async {
    bundles['$bareJid:$deviceId'] = bundleJson;
  }

  @override
  Map<String, dynamic>? loadOmemo2Bundle(String bareJid, int deviceId) =>
      bundles['$bareJid:$deviceId'];

  @override
  Future<void> storeOmemo2Ratchet(
    String bareJid,
    int deviceId,
    Map<String, dynamic> ratchetJson,
  ) async {
    ratchets['$bareJid:$deviceId'] = ratchetJson;
  }

  @override
  Map<String, dynamic>? loadOmemo2Ratchet(String bareJid, int deviceId) =>
      ratchets['$bareJid:$deviceId'];

  @override
  Map<int, Map<String, dynamic>> loadOmemo2RatchetsForJid(String bareJid) {
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
  Future<void> removeOmemo2Ratchets(
    List<MapEntry<String, int>> ratchetKeys,
  ) async {
    for (final key in ratchetKeys) {
      ratchets.remove('${key.key}:${key.value}');
    }
  }

  @override
  Future<void> storeOmemo2Trust(
    String bareJid,
    int deviceId,
    Map<String, dynamic> trustJson,
  ) async {
    trust['$bareJid:$deviceId'] = trustJson;
  }

  @override
  List<Map<String, dynamic>> loadOmemo2TrustForJid(String bareJid) {
    final prefix = '$bareJid:';
    return [
      for (final entry in trust.entries)
        if (entry.key.startsWith(prefix)) entry.value,
    ];
  }

  @override
  Future<void> removeOmemo2TrustForJid(String bareJid) async {
    trust.removeWhere((key, _) => key.startsWith('$bareJid:'));
  }
}

/// Shared in-memory "PEP server" used by [FakeOmemo2Pep] so two
/// [Omemo2Backend]s in the same test can discover each other's device
/// list/bundles without any real XMPP connection, per the "fake/in-memory
/// storage" guidance for Step 1 tests.
class FakeOmemo2Network {
  final Map<String, List<int>> deviceLists = {};
  final Map<String, OmemoBundle> bundles = {};
}

class FakeOmemo2Pep implements Omemo2PepTransport {
  FakeOmemo2Pep(this.network, this.ownBareJid);

  final FakeOmemo2Network network;
  final String ownBareJid;

  @override
  Future<void> publishDeviceList(List<int> deviceIds) async {
    network.deviceLists[ownBareJid] = List.of(deviceIds);
  }

  @override
  Future<List<int>?> fetchDeviceList(String bareJid) async {
    return network.deviceLists[bareJid];
  }

  @override
  void subscribeToDeviceList(String bareJid) {}

  @override
  Future<void> publishBundle(OmemoBundle bundle) async {
    network.bundles['$ownBareJid:${bundle.id}'] = bundle;
  }

  @override
  Future<OmemoBundle?> fetchBundle(String bareJid, int deviceId) async {
    return network.bundles['$bareJid:$deviceId'];
  }
}

void main() {
  const aliceJid = 'alice@example.org';
  const bobJid = 'bob@example.org';

  test(
    'Omemo2Backend: session establishment and encrypt/decrypt round-trip',
    () async {
      final network = FakeOmemo2Network();
      final aliceStorage = FakeStorageService();
      final bobStorage = FakeStorageService();

      final aliceBackend = await Omemo2Backend.create(
        selfBareJid: aliceJid,
        storage: aliceStorage,
        pep: FakeOmemo2Pep(network, aliceJid),
      );
      final bobBackend = await Omemo2Backend.create(
        selfBareJid: bobJid,
        storage: bobStorage,
        pep: FakeOmemo2Pep(network, bobJid),
      );

      expect(aliceBackend.protocolId, 'omemo2');

      // Both sides publish their bundle/device-list, as would happen on
      // first login.
      await aliceBackend.publishIdentity();
      await bobBackend.publishIdentity();

      // Alice encrypts a message for Bob. omemo_dart transparently performs
      // the X3DH key exchange (fetching Bob's bundle via the fake PEP
      // network) and creates a new Double Ratchet session.
      final payload = await aliceBackend.encryptForSend(
        bobJid,
        'hello from alice',
      );
      expect(payload.element.name, 'encrypted');
      expect(
        payload.element.getAttribute('xmlns')?.value,
        'urn:xmpp:omemo:2',
      );

      // Wrap the <encrypted/> element the way it would appear inside an
      // incoming <message/> stanza.
      final message = MessageStanza(
        AbstractStanza.getRandomId(),
        MessageStanzaType.CHAT,
      );
      message.fromJid = Jid.fromFullJid('$aliceJid/device1');
      message.addChild(payload.element);

      final result = await bobBackend.decryptIncoming(message);
      expect(result.error, isNull);
      expect(result.plaintext, 'hello from alice');
      expect(result.protocolId, 'omemo2');

      // Trust-on-first-use: an unverified but seen device should report as
      // tofu, never outright untrusted, once a session exists.
      expect(result.senderTrust, TrustState.tofu);

      // A ratchet session should now have been persisted for both sides.
      expect(aliceStorage.ratchets, isNotEmpty);
      expect(bobStorage.ratchets, isNotEmpty);
    },
  );

  test(
    'Omemo2Backend: restores the same identity across restarts',
    () async {
      final network = FakeOmemo2Network();
      final storage = FakeStorageService();

      final first = await Omemo2Backend.create(
        selfBareJid: aliceJid,
        storage: storage,
        pep: FakeOmemo2Pep(network, aliceJid),
      );
      await first.publishIdentity();
      final firstDeviceId = (await storage.loadOmemo2Identity(aliceJid))!['id'];

      final second = await Omemo2Backend.create(
        selfBareJid: aliceJid,
        storage: storage,
        pep: FakeOmemo2Pep(network, aliceJid),
      );
      final secondDeviceId =
          (await storage.loadOmemo2Identity(aliceJid))!['id'];

      expect(secondDeviceId, firstDeviceId);
      expect(second.protocolId, 'omemo2');
    },
  );

  test(
    'Omemo2Backend: decryptIncoming reports an error for a non-OMEMO2 stanza',
    () async {
      final network = FakeOmemo2Network();
      final storage = FakeStorageService();
      final backend = await Omemo2Backend.create(
        selfBareJid: bobJid,
        storage: storage,
        pep: FakeOmemo2Pep(network, bobJid),
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
    },
  );

  test('setTrust/trustStateFor round-trip for a verified device', () async {
    final network = FakeOmemo2Network();
    final aliceStorage = FakeStorageService();
    final bobStorage = FakeStorageService();

    final aliceBackend = await Omemo2Backend.create(
      selfBareJid: aliceJid,
      storage: aliceStorage,
      pep: FakeOmemo2Pep(network, aliceJid),
    );
    final bobBackend = await Omemo2Backend.create(
      selfBareJid: bobJid,
      storage: bobStorage,
      pep: FakeOmemo2Pep(network, bobJid),
    );
    await aliceBackend.publishIdentity();
    await bobBackend.publishIdentity();

    // Establish a session so Alice has a trust entry for Bob's device.
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
}
