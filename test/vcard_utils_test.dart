import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/vcard_utils.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('vcardDisplayName prefers full name', () {
    final vcard = VCard(null);
    final fn = XmppElement()..name = 'FN';
    fn.textValue = 'Alice Example';
    vcard.addChild(fn);
    expect(vcardDisplayName(vcard), 'Alice Example');
  });

  test('buildVcardElement includes photo when provided', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final vcard = buildVcardElement(
      displayName: 'Bob',
      avatarBytes: bytes,
      avatarMimeType: 'image/png',
    );
    expect(vcard.getAttribute('xmlns')?.value, 'vcard-temp');
    final photo = vcard.getChild('PHOTO');
    expect(photo, isNotNull);
    expect(photo!.getChild('TYPE')?.textValue, 'image/png');
    expect(photo.getChild('BINVAL')?.textValue, isNotEmpty);
  });

  test('vcardPhotoHash returns sha1 hex', () async {
    final hash = await vcardPhotoHash(Uint8List.fromList([1, 2, 3]));
    expect(hash.length, 40);
  });

  test('normalizeVcardPhotoHash keeps non-duplicated hash unchanged', () {
    const hash = 'a6626f8138cf2b82d2e8c3f3e28090a03d54aee2';
    expect(normalizeVcardPhotoHash(hash), hash);
  });

  test('normalizeVcardPhotoHash removes duplicated halves', () {
    const single = 'a6626f8138cf2b82d2e8c3f3e28090a03d54aee2';
    const doubled =
        'a6626f8138cf2b82d2e8c3f3e28090a03d54aee2a6626f8138cf2b82d2e8c3f3e28090a03d54aee2';
    expect(normalizeVcardPhotoHash(doubled), single);
  });

  group('shouldFetchVcardForCache (R4.1)', () {
    const jid = 'alice@example.com';
    const hash = 'a6626f8138cf2b82d2e8c3f3e28090a03d54aee2';

    test('preferName=true always fetches', () {
      expect(
        shouldFetchVcardForCache(
          bareJid: jid,
          preferName: true,
          cachedAvatarBytes: <String, Object?>{
            jid: Uint8List.fromList([1, 2]),
          },
          cachedAvatarState: <String, String>{jid: hash},
          advertisedHash: hash,
        ),
        isTrue,
      );
    });

    test('no state recorded → fetch', () {
      expect(
        shouldFetchVcardForCache(
          bareJid: jid,
          preferName: false,
          cachedAvatarBytes: const <String, Object?>{},
          cachedAvatarState: const <String, String>{},
        ),
        isTrue,
      );
    });

    test('no-avatar sentinel and no advertised hash → skip', () {
      expect(
        shouldFetchVcardForCache(
          bareJid: jid,
          preferName: false,
          cachedAvatarBytes: const <String, Object?>{},
          cachedAvatarState: const <String, String>{
            jid: vcardNoAvatarSentinel,
          },
        ),
        isFalse,
      );
    });

    test(
      'no-avatar sentinel but presence advertises a hash → fetch',
      () {
        expect(
          shouldFetchVcardForCache(
            bareJid: jid,
            preferName: false,
            cachedAvatarBytes: const <String, Object?>{},
            cachedAvatarState: const <String, String>{
              jid: vcardNoAvatarSentinel,
            },
            advertisedHash: hash,
          ),
          isTrue,
        );
      },
    );

    test('cached bytes & matching hash, no presence hash → skip', () {
      expect(
        shouldFetchVcardForCache(
          bareJid: jid,
          preferName: false,
          cachedAvatarBytes: <String, Object?>{
            jid: Uint8List.fromList([1, 2]),
          },
          cachedAvatarState: const <String, String>{jid: hash},
        ),
        isFalse,
      );
    });

    test(
      'cached bytes & matching hash & matching presence hash → skip',
      () {
        expect(
          shouldFetchVcardForCache(
            bareJid: jid,
            preferName: false,
            cachedAvatarBytes: <String, Object?>{
              jid: Uint8List.fromList([1, 2]),
            },
            cachedAvatarState: const <String, String>{jid: hash},
            advertisedHash: hash,
          ),
          isFalse,
        );
      },
    );

    test('cached bytes but presence advertises a different hash → fetch', () {
      const newHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      expect(
        shouldFetchVcardForCache(
          bareJid: jid,
          preferName: false,
          cachedAvatarBytes: <String, Object?>{
            jid: Uint8List.fromList([1, 2]),
          },
          cachedAvatarState: const <String, String>{jid: hash},
          advertisedHash: newHash,
        ),
        isTrue,
      );
    });

    test('hash recorded but no bytes cached → fetch', () {
      expect(
        shouldFetchVcardForCache(
          bareJid: jid,
          preferName: false,
          cachedAvatarBytes: const <String, Object?>{},
          cachedAvatarState: const <String, String>{jid: hash},
        ),
        isTrue,
      );
    });

    // R6: verify that after a re-seed (simulating the Ready-handler re-seed
    // introduced by R6) the guard correctly suppresses the fetch.
    test('R6: guard suppresses fetch after cache is re-seeded from disk', () {
      final hash = 'abc123';
      final bytes = Uint8List.fromList([1, 2, 3]);
      // Simulate what _seedVcardAvatars + _seedVcardAvatarState do on reconnect.
      final cachedAvatarBytes = <String, Uint8List>{'alice@example.com': bytes};
      final cachedAvatarState = <String, String>{'alice@example.com': hash};

      // The presence update advertises the same hash we already have cached.
      expect(
        shouldFetchVcardForCache(
          bareJid: 'alice@example.com',
          preferName: false,
          cachedAvatarBytes: cachedAvatarBytes,
          cachedAvatarState: cachedAvatarState,
          advertisedHash: hash,
        ),
        isFalse,
        reason: 'should skip fetch when re-seeded cache matches advertised hash',
      );
    });

    test('R6: guard allows fetch when re-seeded cache has different hash', () {
      final oldHash = 'oldhash';
      final newHash = 'newhash';
      final bytes = Uint8List.fromList([1, 2, 3]);
      final cachedAvatarBytes = <String, Uint8List>{'alice@example.com': bytes};
      final cachedAvatarState = <String, String>{
        'alice@example.com': oldHash,
      };

      // The presence update advertises a new hash — we must fetch.
      expect(
        shouldFetchVcardForCache(
          bareJid: 'alice@example.com',
          preferName: false,
          cachedAvatarBytes: cachedAvatarBytes,
          cachedAvatarState: cachedAvatarState,
          advertisedHash: newHash,
        ),
        isTrue,
        reason: 'should fetch when advertised hash differs from cached hash',
      );
    });
  });
}
