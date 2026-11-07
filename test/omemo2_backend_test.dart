import 'dart:convert';

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
  Future<void> removeOmemo2DeviceList(String bareJid) async {
    deviceLists.remove(bareJid);
  }

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
  Future<void> removeOmemo2BundlesForJid(String bareJid) async {
    bundles.removeWhere((key, _) => key.startsWith('$bareJid:'));
  }

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
    'Omemo2Backend: device-list fetch always consults PEP live instead of '
    "getting stuck on a stale cached (e.g. empty) device list forever",
    () async {
      // Regression test mirroring the identical fix in OmemoBackend (see
      // `test/omemo_backend_test.dart`): fetchDeviceListImpl must prefer a
      // live PEP fetch over any cached device list, since OmemoManager
      // only calls this callback once per JID for the process's lifetime.
      final network = FakeOmemo2Network();
      final aliceStorage = FakeStorageService();
      final bobStorage = FakeStorageService();

      // Simulate a stale cache: Alice previously looked Bob up when he had
      // no OMEMO2 device at all.
      aliceStorage.deviceLists[bobJid] = <int>[];

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

      // Bob now publishes his (new) device/bundle via PEP.
      await bobBackend.publishIdentity();

      // Despite the stale empty cache, Alice must discover Bob's device
      // via a live fetch and successfully fetch/use his bundle.
      final payload = await aliceBackend.encryptForSend(
        bobJid,
        'hello from alice',
      );
      expect(payload.element.getChild('header'), isNotNull);

      final fingerprints = await aliceBackend.deviceFingerprintsFor(bobJid);
      expect(fingerprints, isNotEmpty);
    },
  );

  test(
    'Omemo2Backend.refreshDevices: wipes the cached device list/bundles '
    "for a contact and picks up a device removed from the contact's live "
    'PEP device list',
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

      // Bob publishes his device/bundle, and Alice discovers it.
      await bobBackend.publishIdentity();
      await aliceBackend.ensureDevicesKnown(bobJid);
      final beforeRemoval = await aliceBackend.deviceFingerprintsFor(bobJid);
      expect(beforeRemoval, hasLength(1));
      final bobDeviceId = beforeRemoval.single.deviceId;
      expect(aliceStorage.bundles.containsKey('$bobJid:$bobDeviceId'), isTrue);

      // Bob then removes his device from PEP entirely (e.g. re-installed
      // the app). Without a refresh, OmemoManager would keep using its
      // in-memory device list from the one-time fetch above forever.
      network.deviceLists[bobJid] = <int>[];

      final refreshed = await aliceBackend.refreshDevices(bobJid);
      expect(refreshed, isTrue);

      // The stale bundle cache must have been wiped...
      expect(
        aliceStorage.bundles.containsKey('$bobJid:$bobDeviceId'),
        isFalse,
      );
      // ...and the cached device list must now reflect Bob's live (now
      // empty) device list instead of the stale one from before the
      // refresh. (Note: [deviceFingerprintsFor] is driven by the trust
      // store's own record of devices it has ever seen, not by the
      // device list cache, so a previously-trusted device intentionally
      // keeps showing up there even after a refresh removes it from the
      // active/live device list -- trust decisions are only cleared
      // explicitly, e.g. via the "Untrust" button.)
      expect(aliceStorage.deviceLists[bobJid], isEmpty);
    },
  );

  test(
    'Omemo2Backend.refreshDevices: returns false and leaves the cache '
    'untouched when the live PEP fetch fails',
    () async {
      final network = FakeOmemo2Network();
      final aliceStorage = FakeStorageService();
      aliceStorage.deviceLists[bobJid] = <int>[1234];
      aliceStorage.bundles['$bobJid:1234'] = {'cached': true};

      final aliceBackend = await Omemo2Backend.create(
        selfBareJid: aliceJid,
        storage: aliceStorage,
        pep: FakeOmemo2Pep(network, aliceJid),
      );

      // Bob has never published anything, so `fetchDeviceList` returns
      // `null` (as opposed to an empty list), simulating e.g. no PEP node
      // existing at all / being offline.
      final refreshed = await aliceBackend.refreshDevices(bobJid);

      expect(refreshed, isFalse);
      expect(aliceStorage.deviceLists[bobJid], equals([1234]));
      expect(aliceStorage.bundles['$bobJid:1234'], equals({'cached': true}));
    },
  );

  test(
    'Omemo2Backend: bundle fetch always consults PEP live instead of '
    'getting stuck on a stale/broken cached bundle forever',
    () async {
      // Regression test mirroring the identical fix in OmemoBackend (see
      // `test/omemo_backend_test.dart`): fetchDeviceBundleImpl must prefer
      // a live PEP fetch over any cached bundle, since OmemoManager only
      // calls that callback once per (jid, device) for the process's
      // lifetime -- once used, a stale/broken cached bundle would
      // otherwise never be refreshed and no bundle-fetch IQ would ever be
      // sent for that device again.
      final network = FakeOmemo2Network();
      final aliceStorage = FakeStorageService();
      final bobStorage = FakeStorageService();

      final bobBackend = await Omemo2Backend.create(
        selfBareJid: bobJid,
        storage: bobStorage,
        pep: FakeOmemo2Pep(network, bobJid),
      );
      final bobDeviceId = await bobBackend.ownDeviceId();

      // Simulate a stale/broken cached bundle for Bob's device: garbage
      // key material that cannot possibly produce a valid session.
      aliceStorage.bundles['$bobJid:$bobDeviceId'] = {
        'jid': bobJid,
        'id': bobDeviceId,
        'ik': base64Encode(List<int>.filled(32, 0)),
        'spk': base64Encode(List<int>.filled(32, 0)),
        'spkId': 1,
        'spks': base64Encode(List<int>.filled(64, 0)),
        'opks': {'1': base64Encode(List<int>.filled(32, 0))},
      };

      final aliceBackend = await Omemo2Backend.create(
        selfBareJid: aliceJid,
        storage: aliceStorage,
        pep: FakeOmemo2Pep(network, aliceJid),
      );

      // Bob now publishes his real device/bundle via PEP.
      await bobBackend.publishIdentity();

      // Despite the stale/broken cached bundle, Alice must perform a live
      // fetch and use Bob's real, current bundle to successfully encrypt.
      final payload = await aliceBackend.encryptForSend(
        bobJid,
        'hello from alice',
      );
      expect(payload.element.getChild('header'), isNotNull);
    },
  );

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
    'Omemo2Backend.publishIdentity: adds our own device id without '
    'removing any other device already published for this account',
    () async {
      // Regression test mirroring the identical fix in OmemoBackend (see
      // `test/omemo_backend_test.dart`): publishing our own device-list
      // must only *add* our device id if it's not already present, never
      // drop other entries (XEP-0384 / XEP-0163 PEP semantics), since
      // Wimsy isn't necessarily the only client active on this account.
      final network = FakeOmemo2Network();
      final storage = FakeStorageService();

      const otherDeviceId = 123456789;
      storage.deviceLists[aliceJid] = [otherDeviceId];
      network.deviceLists[aliceJid] = [otherDeviceId];

      final backend = await Omemo2Backend.create(
        selfBareJid: aliceJid,
        storage: storage,
        pep: FakeOmemo2Pep(network, aliceJid),
      );
      await backend.publishIdentity();

      final currentDeviceId = await backend.ownDeviceId();
      expect(currentDeviceId, isNot(otherDeviceId));

      expect(
        storage.deviceLists[aliceJid],
        containsAll([otherDeviceId, currentDeviceId]),
      );
      expect(
        network.deviceLists[aliceJid],
        containsAll([otherDeviceId, currentDeviceId]),
      );

      // Publishing again must not duplicate our own id.
      await backend.publishIdentity();
      expect(
        network.deviceLists[aliceJid]!.where((id) => id == currentDeviceId),
        hasLength(1),
      );
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

  test(
    'Omemo2Backend: exported identity key can be imported to restore the '
    'same fingerprint',
    () async {
      final network = FakeOmemo2Network();
      final originalStorage = FakeStorageService();

      final original = await Omemo2Backend.create(
        selfBareJid: aliceJid,
        storage: originalStorage,
        pep: FakeOmemo2Pep(network, aliceJid),
      );
      final exported = await original.exportIdentityKey();

      expect(exported, startsWith('-----BEGIN OMEMO2 IDENTITY KEY-----'));
      expect(exported, endsWith('-----END OMEMO2 IDENTITY KEY-----'));

      // "Reinstall": a fresh, empty storage, restoring via the exported PEM.
      final restoredStorage = FakeStorageService();
      final restored = await Omemo2Backend.create(
        selfBareJid: aliceJid,
        storage: restoredStorage,
        pep: FakeOmemo2Pep(network, aliceJid),
        importedIdentityKeyPem: exported,
      );

      expect(await restored.ownFingerprint(), await original.ownFingerprint());

      // Importing is only honored when no device has been persisted yet:
      // reusing the import parameter against storage that already has an
      // identity must leave that identity untouched.
      final unaffected = await Omemo2Backend.create(
        selfBareJid: aliceJid,
        storage: restoredStorage,
        pep: FakeOmemo2Pep(network, aliceJid),
        importedIdentityKeyPem: await (await Omemo2Backend.create(
          selfBareJid: bobJid,
          storage: FakeStorageService(),
          pep: FakeOmemo2Pep(network, bobJid),
        )).exportIdentityKey(),
      );
      expect(
        await unaffected.ownFingerprint(),
        await restored.ownFingerprint(),
      );
    },
  );

  test(
    'Omemo2Backend: importing an OMEMO export fails with a legacy label',
    () async {
      final network = FakeOmemo2Network();
      final storage = FakeStorageService();
      final backend = await Omemo2Backend.create(
        selfBareJid: aliceJid,
        storage: storage,
        pep: FakeOmemo2Pep(network, aliceJid),
      );
      final exported = await backend.exportIdentityKey();
      final tampered = exported.replaceAll('OMEMO2', 'OMEMO');

      await expectLater(
        Omemo2Backend.create(
          selfBareJid: bobJid,
          storage: FakeStorageService(),
          pep: FakeOmemo2Pep(network, bobJid),
          importedIdentityKeyPem: tampered,
        ),
        throwsFormatException,
      );
    },
  );
}
