import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/startup_fetch_helpers.dart';

void main() {
  group('shouldFetchDisplayedSyncBootstrap (R1.1, reverted)', () {
    // R1.1 used to skip this IQ whenever the on-disk cache was non-empty,
    // relying on PEP +notify to keep it live. That's unsafe: +notify only
    // delivers publishes made while this device is online/subscribed, so a
    // device that was offline (e.g. desktop over a weekend while the user
    // read messages on mobile) would keep a stale marker forever — see
    // wimsy2.log, where gajim@conference.gajim.org and xsf@muc.xmpp.org
    // messages already cached and already read elsewhere kept showing as
    // unread. The bootstrap IQ is now always sent on connect.
    test('empty cache → fetch', () {
      expect(
        shouldFetchDisplayedSyncBootstrap(hasCachedDisplayedSync: false),
        isTrue,
      );
    });

    test('cache populated from disk → still fetch (do not trust a stale '
        'on-disk marker after being offline)', () {
      expect(
        shouldFetchDisplayedSyncBootstrap(hasCachedDisplayedSync: true),
        isTrue,
      );
    });

    test('force=true still fetches (idempotent, cache populated)', () {
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
