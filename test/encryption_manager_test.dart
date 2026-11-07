import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/encryption/encryption_manager.dart';
import 'package:wimsy/storage/storage_service.dart';

/// In-memory fake [StorageService], overriding only the bits
/// [EncryptionManager] (and, transitively, [Omemo2Backend]) touch.
class FakeStorageService extends StorageService {
  final Map<String, String> protocolByJid = {};
  final Map<String, Map<String, dynamic>> identities = {};
  final Map<String, List<int>> deviceLists = {};

  @override
  Future<void> storeEncryptionProtocolForJid(
    String bareJid,
    String? protocolId,
  ) async {
    if (protocolId == null || protocolId.isEmpty) {
      protocolByJid.remove(bareJid);
    } else {
      protocolByJid[bareJid] = protocolId;
    }
  }

  @override
  String? loadEncryptionProtocolForJid(String bareJid) =>
      protocolByJid[bareJid];

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
  Future<void> storeOmemoIdentity(
    String bareJid,
    Map<String, dynamic> deviceJson,
  ) async {
    identities['legacy:$bareJid'] = deviceJson;
  }

  @override
  Future<Map<String, dynamic>?> loadOmemoIdentity(String bareJid) async {
    return identities['legacy:$bareJid'];
  }

  @override
  Future<void> storeOmemoDeviceList(
    String bareJid,
    List<int> deviceIds,
  ) async {
    deviceLists['legacy:$bareJid'] = List.of(deviceIds);
  }

  @override
  List<int>? loadOmemoDeviceList(String bareJid) =>
      deviceLists['legacy:$bareJid'];
}

class TestConnection extends Connection {
  TestConnection(super.account);

  AbstractStanza? lastWrittenStanza;
  final List<AbstractStanza> writtenStanzas = [];

  @override
  void writeStanza(AbstractStanza stanza) {
    lastWrittenStanza = stanza;
    writtenStanzas.add(stanza);
  }

  @override
  void writeNonza(Nonza nonza) {}

  @override
  void write(Object? message) {}
}

TestConnection _buildConnection() {
  final account = XmppAccountSettings(
    'test',
    'user',
    'example.com',
    'pass',
    5222,
  );
  return TestConnection(account);
}

void main() {
  const aliceJid = 'alice@example.com';
  const bobJid = 'bob@example.com';

  test('protocol selection defaults to none and is persisted', () async {
    final storage = FakeStorageService();
    final manager = EncryptionManager(
      connection: _buildConnection(),
      storage: storage,
      selfBareJid: aliceJid,
      onUpdate: () {},
    );

    expect(manager.protocolFor(bobJid), EncryptionProtocol.none);
    expect(manager.isEncryptionEnabled(bobJid), isFalse);

    await manager.setProtocolFor(bobJid, EncryptionProtocol.omemo2);

    expect(manager.protocolFor(bobJid), EncryptionProtocol.omemo2);
    expect(manager.isEncryptionEnabled(bobJid), isTrue);
    expect(storage.protocolByJid[bobJid], 'omemo2');

    await manager.setProtocolFor(bobJid, EncryptionProtocol.none);
    expect(manager.protocolFor(bobJid), EncryptionProtocol.none);
    expect(storage.protocolByJid.containsKey(bobJid), isFalse);
  });

  test('protocol selection is reloaded from storage for a fresh manager', () {
    final storage = FakeStorageService();
    storage.protocolByJid[bobJid] = 'omemo2';

    final manager = EncryptionManager(
      connection: _buildConnection(),
      storage: storage,
      selfBareJid: aliceJid,
      onUpdate: () {},
    );

    expect(manager.protocolFor(bobJid), EncryptionProtocol.omemo2);
  });

  test('onUpdate fires whenever the selection changes', () async {
    final storage = FakeStorageService();
    var updates = 0;
    final manager = EncryptionManager(
      connection: _buildConnection(),
      storage: storage,
      selfBareJid: aliceJid,
      onUpdate: () => updates++,
    );

    await manager.setProtocolFor(bobJid, EncryptionProtocol.omemo2);
    expect(updates, 1);
  });

  test('backendFor(none) returns null and skips encryption', () async {
    final storage = FakeStorageService();
    final manager = EncryptionManager(
      connection: _buildConnection(),
      storage: storage,
      selfBareJid: aliceJid,
      onUpdate: () {},
    );

    expect(await manager.backendFor(EncryptionProtocol.none), isNull);
    expect(
      await manager.encryptForSend(bobJid, 'hello'),
      isNull,
      reason:
          'encryptForSend should be a no-op (return null) when the '
          'conversation has no protocol selected',
    );
  });

  test(
    'backendFor(omemo2) lazily creates and caches an Omemo2Backend',
    () async {
      final storage = FakeStorageService();
      final manager = EncryptionManager(
        connection: _buildConnection(),
        storage: storage,
        selfBareJid: aliceJid,
        onUpdate: () {},
      );

      final backend = await manager.backendFor(EncryptionProtocol.omemo2);
      expect(backend, isNotNull);
      expect(backend!.protocolId, 'omemo2');

      final backendAgain = await manager.backendFor(EncryptionProtocol.omemo2);
      expect(
        identical(backend, backendAgain),
        isTrue,
        reason: 'the Omemo2Backend instance should be cached/reused',
      );
    },
  );

  test(
    'decryptIncoming/decryptIncomingByNamespace return null for a '
    'stanza without an <encrypted/> element',
    () async {
      final storage = FakeStorageService();
      final manager = EncryptionManager(
        connection: _buildConnection(),
        storage: storage,
        selfBareJid: aliceJid,
        onUpdate: () {},
      );
      await manager.setProtocolFor(bobJid, EncryptionProtocol.omemo2);

      final stanza = MessageStanza(
        AbstractStanza.getRandomId(),
        MessageStanzaType.CHAT,
      );
      stanza.fromJid = Jid.fromFullJid(bobJid);
      stanza.body = 'plaintext';

      expect(await manager.decryptIncomingByNamespace(stanza), isNull);
    },
  );

  test(
    'creating a backend automatically publishes our identity via PEP '
    'instead of requiring a separate, never-called publishIdentity() '
    'from production code',
    () async {
      // Regression test: real-world interop failures (Conversations
      // reporting "Message was not encrypted for this device" /
      // omemo_dart throwing NotEncryptedForDeviceError on every incoming
      // message) were traced back to `publishIdentity()` never being
      // invoked anywhere outside of unit tests, so our own device/bundle
      // was never (re-)announced via PEP after being (re)created --
      // contacts kept a stale device id of ours forever. EncryptionManager
      // must now publish identity itself, right when a backend is first
      // created, so this can't regress silently again.
      final storage = FakeStorageService();
      final connection = _buildConnection();
      final manager = EncryptionManager(
        connection: connection,
        storage: storage,
        selfBareJid: aliceJid,
        onUpdate: () {},
      );

      expect(
        connection.lastWrittenStanza,
        isNull,
        reason: 'nothing should be published before a backend is used',
      );

      await manager.backendFor(EncryptionProtocol.omemo2);
      // publishIdentity() is fired-and-forgotten (not awaited by
      // backendFor), so give the microtask queue a chance to run the
      // publish's first `connection.writeStanza` call before asserting.
      await Future<void>.delayed(Duration.zero);

      final written = connection.lastWrittenStanza;
      expect(
        written,
        isA<IqStanza>(),
        reason:
            'creating the OMEMO2 backend should have published our own '
            'bundle/device-list via a PEP publish IQ',
      );
      final publish = (written as IqStanza).getChild('pubsub')?.getChild(
        'publish',
      );
      expect(publish, isNotNull);
    },
  );

  test(
    'publishAllIdentities() eagerly creates the OMEMO2 and legacy-OMEMO '
    'backends so our own identity is published right after connecting, '
    'without waiting for any per-conversation action',
    () async {
      // Regression test: previously, our own OMEMO2/legacy-OMEMO device
      // list and key bundle were only ever published reactively -- when
      // a conversation's protocol was explicitly selected, or a message
      // was sent/received -- so an account that never did either of
      // those from a given device simply never announced itself via PEP,
      // making it invisible to contacts trying to discover its devices
      // even though it could happily read contacts' own device lists.
      final storage = FakeStorageService();
      final connection = _buildConnection();
      final manager = EncryptionManager(
        connection: connection,
        storage: storage,
        selfBareJid: aliceJid,
        onUpdate: () {},
      );

      expect(
        connection.writtenStanzas,
        isEmpty,
        reason: 'nothing should be published before publishAllIdentities()',
      );

      manager.publishAllIdentities();
      // Both backends' identity publishes are fired-and-forgotten. Each
      // `publishIdentity()` first publishes the device's bundle, then
      // awaits a device-list fetch IQ response (to merge with it) before
      // publishing the device list itself -- since nothing in this test
      // ever responds to that fetch, only the two bundle publishes are
      // observable here; that's still enough to prove both backends were
      // actually created and started publishing.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      final publishedNodes = connection.writtenStanzas
          .whereType<IqStanza>()
          .map(
            (iq) => iq.getChild('pubsub')?.getChild('publish')?.getAttribute('node')?.value,
          )
          .whereType<String>()
          .toSet();
      expect(
        publishedNodes.contains('urn:xmpp:omemo:2:bundles'),
        isTrue,
        reason: 'publishAllIdentities() should have published our OMEMO2 bundle',
      );
      expect(
        publishedNodes.any(
          (node) => node.startsWith('eu.siacs.conversations.axolotl.bundles:'),
        ),
        isTrue,
        reason:
            'publishAllIdentities() should have published our legacy-OMEMO '
            'bundle',
      );
    },
  );

  test(
    'turning on OMEMO2 for a conversation proactively fetches the '
    "contact's device list instead of waiting for the first outgoing "
    'message',
    () async {
      // Regression test: previously, Wimsy never fetched/subscribed to a
      // contact's device list (or their bundles) until the user actually
      // sent them an encrypted message -- so a newly-added contact (or
      // one we'd never messaged yet) always showed zero devices in the
      // fingerprint verification screen, with no IQ/subscription ever
      // sent for their device-list PEP node.
      final storage = FakeStorageService();
      final connection = _buildConnection();
      final manager = EncryptionManager(
        connection: connection,
        storage: storage,
        selfBareJid: aliceJid,
        onUpdate: () {},
      );

      await manager.setProtocolFor(bobJid, EncryptionProtocol.omemo2);
      // Device discovery is fired-and-forgotten; give the microtask
      // queue a few turns to get past identity publish and reach the
      // device-list fetch IQ (which then blocks forever awaiting a
      // response nothing in this test ever sends).
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      final deviceListFetch = connection.writtenStanzas.whereType<IqStanza>().where((
        iq,
      ) {
        final items = iq.getChild('pubsub')?.getChild('items');
        return iq.toJid?.userAtDomain == bobJid &&
            items?.getAttribute('node')?.value == 'urn:xmpp:omemo:2:devices';
      });
      expect(
        deviceListFetch,
        isNotEmpty,
        reason:
            'selecting OMEMO2 for $bobJid should have proactively sent a '
            'device-list fetch IQ to them',
      );
    },
  );

  test(
    'fetching OMEMO2 fingerprints for a contact proactively triggers '
    'device discovery too',
    () async {
      final storage = FakeStorageService();
      final connection = _buildConnection();
      final manager = EncryptionManager(
        connection: connection,
        storage: storage,
        selfBareJid: aliceJid,
        onUpdate: () {},
      );

      unawaited(manager.omemo2FingerprintsFor(bobJid));
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      final deviceListFetch = connection.writtenStanzas.whereType<IqStanza>().where((
        iq,
      ) {
        final items = iq.getChild('pubsub')?.getChild('items');
        return iq.toJid?.userAtDomain == bobJid &&
            items?.getAttribute('node')?.value == 'urn:xmpp:omemo:2:devices';
      });
      expect(
        deviceListFetch,
        isNotEmpty,
        reason:
            'opening the fingerprint screen for $bobJid should have '
            'proactively sent a device-list fetch IQ to them',
      );
    },
  );

  test('encryptionProtocolId/encryptionProtocolFromId round-trip', () {
    for (final protocol in EncryptionProtocol.values) {
      final id = encryptionProtocolId(protocol);
      if (protocol == EncryptionProtocol.none) {
        // 'none' round-trips to EncryptionProtocol.none via the default
        // branch of encryptionProtocolFromId (it isn't an explicit case).
        expect(encryptionProtocolFromId(id), EncryptionProtocol.none);
      } else {
        expect(encryptionProtocolFromId(id), protocol);
      }
    }
    expect(encryptionProtocolFromId(null), EncryptionProtocol.none);
    expect(encryptionProtocolFromId('bogus'), EncryptionProtocol.none);
  });
}
