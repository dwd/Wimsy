import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/startup_fetch_helpers.dart';

void main() {
  group('shouldFetchDisplayedSyncBootstrap (R1.1)', () {
    test('empty cache → fetch', () {
      expect(
        shouldFetchDisplayedSyncBootstrap(hasCachedDisplayedSync: false),
        isTrue,
      );
    });

    test('cache populated from disk → skip the bootstrap IQ', () {
      expect(
        shouldFetchDisplayedSyncBootstrap(hasCachedDisplayedSync: true),
        isFalse,
      );
    });

    test('force=true overrides the cache check', () {
      expect(
        shouldFetchDisplayedSyncBootstrap(
          hasCachedDisplayedSync: true,
          force: true,
        ),
        isTrue,
      );
    });

    test('force=true on empty cache also fetches (idempotent)', () {
      expect(
        shouldFetchDisplayedSyncBootstrap(
          hasCachedDisplayedSync: false,
          force: true,
        ),
        isTrue,
      );
    });
  });

  group('shouldFetchMamCatchUpForChat (R2.2)', () {
    test('no displayed marker → fetch', () {
      expect(
        shouldFetchMamCatchUpForChat(
          displayedStanzaId: null,
          latestLocalMamId: 'mam-1',
          stanzaIdAtLatestMamId: 'sid-1',
        ),
        isTrue,
      );
      expect(
        shouldFetchMamCatchUpForChat(
          displayedStanzaId: '',
          latestLocalMamId: 'mam-1',
          stanzaIdAtLatestMamId: 'sid-1',
        ),
        isTrue,
      );
    });

    test('no local MAM cursor → fetch', () {
      expect(
        shouldFetchMamCatchUpForChat(
          displayedStanzaId: 'sid-1',
          latestLocalMamId: null,
          stanzaIdAtLatestMamId: 'sid-1',
        ),
        isTrue,
      );
    });

    test('no stanza-id at latest MAM id → fetch', () {
      expect(
        shouldFetchMamCatchUpForChat(
          displayedStanzaId: 'sid-1',
          latestLocalMamId: 'mam-1',
          stanzaIdAtLatestMamId: null,
        ),
        isTrue,
      );
    });

    test('marker matches latest local stanza-id → skip', () {
      expect(
        shouldFetchMamCatchUpForChat(
          displayedStanzaId: 'sid-1',
          latestLocalMamId: 'mam-1',
          stanzaIdAtLatestMamId: 'sid-1',
        ),
        isFalse,
      );
    });

    test('marker is newer than what we have → fetch', () {
      expect(
        shouldFetchMamCatchUpForChat(
          displayedStanzaId: 'sid-99',
          latestLocalMamId: 'mam-1',
          stanzaIdAtLatestMamId: 'sid-1',
        ),
        isTrue,
      );
    });
  });
}
