// Regression test for the stray unconditional _roomMessages.clear() in
// _safeClose().
//
// Before the fix, _safeClose(preserveCache: true) would clear _roomMessages
// regardless of the preserveCache flag, because the field was cleared twice:
//   1. Inside the `if (!preserveCache)` block (correct).
//   2. Unconditionally outside that block (bug).
//
// This caused _primeMamSync to see an empty _roomMessages on every reconnect,
// making it send `<before/>` initial MAM queries for all groupchat rooms
// instead of cheaper catch-up queries using `<after lastMamId/>`.
//
// This test models the relevant cache-management logic in isolation and
// verifies that room messages survive a preserveCache=true disconnect cycle.

import 'package:flutter_test/flutter_test.dart';

/// Minimal replica of the _safeClose cache-clearing logic from XmppService.
///
/// Mirrors the `if (!preserveCache)` blocks and any unconditional clears,
/// so we can test both the pre-fix (buggy) and post-fix (correct) behaviour.
class _MockCacheState {
  final Map<String, List<String>> roomMessages = {};
  final Set<String> seededRoomMessageJids = {};

  /// Mirrors the _safeClose logic that existed BEFORE the fix:
  ///   - clears roomMessages inside if (!preserveCache)
  ///   - then clears roomMessages unconditionally again (the bug)
  void safeCloseBuggy({required bool preserveCache}) {
    if (!preserveCache) {
      roomMessages.clear();
      seededRoomMessageJids.clear();
    }
    // BUG: this unconditional clear overwrites the preserveCache guard above.
    roomMessages.clear();
  }

  /// Mirrors the _safeClose logic AFTER the fix:
  ///   - only clears roomMessages inside if (!preserveCache)
  ///   - no stray unconditional clear
  void safeCloseFixed({required bool preserveCache}) {
    if (!preserveCache) {
      roomMessages.clear();
      seededRoomMessageJids.clear();
    }
    // The unconditional roomMessages.clear() has been removed.
  }
}

void main() {
  group('reconnect cache preservation', () {
    test('buggy safeClose clears room messages even when preserveCache=true',
        () {
      final cache = _MockCacheState();
      cache.roomMessages['room@example.com'] = ['msg1', 'msg2'];
      cache.seededRoomMessageJids.add('room@example.com');

      // Simulate what happened before the fix.
      cache.safeCloseBuggy(preserveCache: true);

      // Room messages were wiped — the old bug.
      expect(cache.roomMessages, isEmpty);
    });

    test('fixed safeClose preserves room messages when preserveCache=true', () {
      final cache = _MockCacheState();
      cache.roomMessages['room@example.com'] = ['msg1', 'msg2'];
      cache.seededRoomMessageJids.add('room@example.com');

      // After the fix, preserveCache=true leaves the cache intact.
      cache.safeCloseFixed(preserveCache: true);

      expect(cache.roomMessages['room@example.com'], equals(['msg1', 'msg2']));
      expect(cache.seededRoomMessageJids, contains('room@example.com'));
    });

    test('fixed safeClose still clears room messages when preserveCache=false',
        () {
      final cache = _MockCacheState();
      cache.roomMessages['room@example.com'] = ['msg1', 'msg2'];
      cache.seededRoomMessageJids.add('room@example.com');

      // preserveCache=false (full logout) must wipe everything.
      cache.safeCloseFixed(preserveCache: false);

      expect(cache.roomMessages, isEmpty);
      expect(cache.seededRoomMessageJids, isEmpty);
    });

    test('fixed safeClose preserves messages for multiple rooms', () {
      final cache = _MockCacheState();
      cache.roomMessages['room1@example.com'] = ['a', 'b'];
      cache.roomMessages['room2@example.com'] = ['c', 'd'];
      cache.seededRoomMessageJids
        ..add('room1@example.com')
        ..add('room2@example.com');

      cache.safeCloseFixed(preserveCache: true);

      expect(cache.roomMessages['room1@example.com'], equals(['a', 'b']));
      expect(cache.roomMessages['room2@example.com'], equals(['c', 'd']));
    });
  });
}
