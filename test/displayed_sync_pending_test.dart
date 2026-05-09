import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/storage/storage_service.dart';

/// In-memory fake. We override only the methods touched by R1.3 so we can
/// exercise the load/store semantics without spinning up Hive.
class FakeStorageService extends StorageService {
  final Map<String, String> _pending = {};
  final Map<String, String> _sync = {};

  @override
  Map<String, String> loadDisplayedSync() => Map<String, String>.from(_sync);

  @override
  Future<void> storeDisplayedSync(Map<String, String> sync) async {
    _sync
      ..clear()
      ..addAll(sync);
  }

  @override
  Map<String, String> loadDisplayedSyncPending() =>
      Map<String, String>.from(_pending);

  @override
  Future<void> storeDisplayedSyncPending(Map<String, String> pending) async {
    _pending
      ..clear()
      ..addAll(pending);
  }

  @override
  Future<void> clearDisplayedSync() async {
    _sync.clear();
    _pending.clear();
  }
}

void main() {
  group('R1.3: StorageService displayed_sync_pending round-trip', () {
    test('empty by default', () {
      final s = FakeStorageService();
      expect(s.loadDisplayedSyncPending(), isEmpty);
    });

    test('store then load returns the same map', () async {
      final s = FakeStorageService();
      await s.storeDisplayedSyncPending({
        'xsf@muc.xmpp.org': 'sid-1',
        'alice@example.com': 'sid-2',
      });
      expect(s.loadDisplayedSyncPending(), {
        'xsf@muc.xmpp.org': 'sid-1',
        'alice@example.com': 'sid-2',
      });
    });

    test('overwrite replaces the whole map', () async {
      final s = FakeStorageService();
      await s.storeDisplayedSyncPending({'a': '1', 'b': '2'});
      await s.storeDisplayedSyncPending({'b': '3'});
      expect(s.loadDisplayedSyncPending(), {'b': '3'});
    });

    test('clearDisplayedSync wipes both displayed_sync and pending', () async {
      final s = FakeStorageService();
      await s.storeDisplayedSync({'a': 'sid-a'});
      await s.storeDisplayedSyncPending({'a': 'sid-pending'});
      await s.clearDisplayedSync();
      expect(s.loadDisplayedSync(), isEmpty);
      expect(s.loadDisplayedSyncPending(), isEmpty);
    });
  });
}
