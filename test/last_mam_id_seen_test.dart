import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/storage/storage_service.dart';

/// In-memory fake. Storage methods touched by R2.1 are overridden to
/// avoid spinning up Hive in unit tests.
class FakeStorageService extends StorageService {
  String? _anchor;

  @override
  String? loadLastMamIdSeen() => _anchor;

  @override
  Future<void> storeLastMamIdSeen(String mamId) async {
    if (mamId.isEmpty) {
      return;
    }
    _anchor = mamId;
  }

  @override
  Future<void> clearLastMamIdSeen() async {
    _anchor = null;
  }
}

void main() {
  group('R2.1: StorageService last_mam_id_seen anchor', () {
    test('null when never written', () {
      final s = FakeStorageService();
      expect(s.loadLastMamIdSeen(), isNull);
    });

    test('store then load round-trips', () async {
      final s = FakeStorageService();
      await s.storeLastMamIdSeen('mam-id-42');
      expect(s.loadLastMamIdSeen(), 'mam-id-42');
    });

    test('empty store is a no-op', () async {
      final s = FakeStorageService();
      await s.storeLastMamIdSeen('mam-id-1');
      await s.storeLastMamIdSeen('');
      expect(s.loadLastMamIdSeen(), 'mam-id-1');
    });

    test('clear removes the anchor', () async {
      final s = FakeStorageService();
      await s.storeLastMamIdSeen('mam-id-1');
      await s.clearLastMamIdSeen();
      expect(s.loadLastMamIdSeen(), isNull);
    });
  });
}
