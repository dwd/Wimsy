import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/encryption/encryption_backend.dart';
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
}

class TestConnection extends Connection {
  TestConnection(super.account);

  AbstractStanza? lastWrittenStanza;

  @override
  void writeStanza(AbstractStanza stanza) {
    lastWrittenStanza = stanza;
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
