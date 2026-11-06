import 'package:flutter_test/flutter_test.dart';

import 'package:wimsy/encryption/encryption_backend.dart';
import 'package:wimsy/encryption/trust_store.dart';
import 'package:wimsy/storage/storage_service.dart';

/// In-memory fake [StorageService], following the same convention as
/// `FakeStorageService` in `test/omemo2_backend_test.dart`, but only
/// overriding the generic trust-store methods [TrustStore] depends on.
class FakeStorageService extends StorageService {
  final Map<String, String> trustStates = {};

  @override
  Future<void> storeTrustState(
    String bareJid,
    String deviceOrKeyId,
    String stateName,
  ) async {
    trustStates['$bareJid:$deviceOrKeyId'] = stateName;
  }

  @override
  String? loadTrustState(String bareJid, String deviceOrKeyId) {
    return trustStates['$bareJid:$deviceOrKeyId'];
  }

  @override
  Future<void> removeTrustStatesForJid(String bareJid) async {
    trustStates.removeWhere((key, _) => key.startsWith('$bareJid:'));
  }
}

void main() {
  const bareJid = 'alice@example.com';
  const deviceId = '1';

  test('TrustStore: an unseen device/key defaults to tofu and is recorded', (
    () async {
      final storage = FakeStorageService();
      final trustStore = TrustStore(storage);

      expect(
        await trustStore.trustStateFor(bareJid, deviceId),
        TrustState.tofu,
      );
      // The TOFU decision should now be persisted.
      expect(storage.trustStates['$bareJid:$deviceId'], 'tofu');
    }),
  );

  test('TrustStore: tofu -> verified transition persists and round-trips', (
    () async {
      final storage = FakeStorageService();
      final trustStore = TrustStore(storage);

      expect(
        await trustStore.trustStateFor(bareJid, deviceId),
        TrustState.tofu,
      );

      await trustStore.setTrust(bareJid, deviceId, TrustState.verified);
      expect(
        await trustStore.trustStateFor(bareJid, deviceId),
        TrustState.verified,
      );
      expect(storage.trustStates['$bareJid:$deviceId'], 'verified');

      // A fresh TrustStore instance backed by the same storage should see
      // the persisted decision rather than re-defaulting to tofu.
      final reloaded = TrustStore(storage);
      expect(
        await reloaded.trustStateFor(bareJid, deviceId),
        TrustState.verified,
      );
    }),
  );

  test('TrustStore: revoked handling persists and round-trips', (() async {
    final storage = FakeStorageService();
    final trustStore = TrustStore(storage);

    await trustStore.setTrust(bareJid, deviceId, TrustState.verified);
    await trustStore.setTrust(bareJid, deviceId, TrustState.revoked);

    expect(
      await trustStore.trustStateFor(bareJid, deviceId),
      TrustState.revoked,
    );
    expect(storage.trustStates['$bareJid:$deviceId'], 'revoked');
  }));

  test('TrustStore: different devices/JIDs are tracked independently', (
    () async {
      final storage = FakeStorageService();
      final trustStore = TrustStore(storage);

      await trustStore.setTrust(bareJid, '1', TrustState.verified);
      await trustStore.setTrust(bareJid, '2', TrustState.untrusted);
      await trustStore.setTrust('bob@example.com', '1', TrustState.revoked);

      expect(await trustStore.trustStateFor(bareJid, '1'), TrustState.verified);
      expect(
        await trustStore.trustStateFor(bareJid, '2'),
        TrustState.untrusted,
      );
      expect(
        await trustStore.trustStateFor('bob@example.com', '1'),
        TrustState.revoked,
      );
    }),
  );

  test('TrustStore: knownStatesFor returns cached states scoped to a JID', (
    () async {
      final storage = FakeStorageService();
      final trustStore = TrustStore(storage);

      await trustStore.setTrust(bareJid, '1', TrustState.verified);
      await trustStore.setTrust(bareJid, '2', TrustState.tofu);
      await trustStore.setTrust('bob@example.com', '1', TrustState.untrusted);

      expect(trustStore.knownStatesFor(bareJid), {
        '1': TrustState.verified,
        '2': TrustState.tofu,
      });
    }),
  );
}
