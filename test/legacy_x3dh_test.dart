import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/encryption/legacy_x3dh.dart';

Future<SimpleKeyPair> _kp() => X25519().newKeyPair();

Future<List<int>> _pub(SimpleKeyPair kp) async =>
    (await kp.extractPublicKey()).bytes;

void main() {
  group('DJB key type helpers', () {
    test('add/strip round trip', () {
      final raw = List<int>.generate(32, (i) => i);
      final prefixed = addDjbType(raw);
      expect(prefixed.length, 33);
      expect(prefixed[0], 0x05);
      expect(stripDjbType(prefixed), raw);
      expect(stripDjbType(raw), raw);
    });

    test('rejects bad lengths and type bytes', () {
      expect(() => stripDjbType([1, 2, 3]), throwsArgumentError);
      expect(
        () => stripDjbType([0x06, ...List.filled(32, 0)]),
        throwsArgumentError,
      );
      expect(() => addDjbType([1, 2]), throwsArgumentError);
    });
  });

  group('legacy X3DH', () {
    for (final withOpk in [true, false]) {
      test(
        'initiator and receiver agree (one-time prekey: $withOpk)',
        () async {
          final ikA = await _kp();
          final ekA = await _kp();
          final ikB = await _kp();
          final spkB = await _kp();
          final opkB = await _kp();

          final alice = await legacyX3dhInitiator(
            ourIdentityKey: ikA,
            ourBaseKey: ekA,
            // Real clients hand us DJB-prefixed keys; mix forms on purpose.
            theirIdentityKey: addDjbType(await _pub(ikB)),
            theirSignedPreKey: await _pub(spkB),
            theirOneTimePreKey: withOpk ? addDjbType(await _pub(opkB)) : null,
          );
          final bob = await legacyX3dhReceiver(
            ourIdentityKey: ikB,
            ourSignedPreKey: spkB,
            ourOneTimePreKey: withOpk ? opkB : null,
            theirIdentityKey: addDjbType(await _pub(ikA)),
            theirBaseKey: addDjbType(await _pub(ekA)),
          );

          expect(alice.rootKey.length, 32);
          expect(alice.chainKey.length, 32);
          expect(bob.rootKey, alice.rootKey);
          expect(bob.chainKey, alice.chainKey);
          expect(alice.rootKey, isNot(alice.chainKey));
        },
      );
    }

    test('output depends on the one-time prekey and on the base key', () async {
      final ikA = await _kp();
      final ekA = await _kp();
      final ekA2 = await _kp();
      final ikB = await _kp();
      final spkB = await _kp();
      final opkB = await _kp();

      Future<LegacyX3dhResult> run(SimpleKeyPair ek, bool opk) =>
          legacyX3dhInitiator(
            ourIdentityKey: ikA,
            ourBaseKey: ek,
            theirIdentityKey: await_(ikB),
            theirSignedPreKey: await_(spkB),
            theirOneTimePreKey: opk ? await_(opkB) : null,
          );

      final a = await run(ekA, true);
      final b = await run(ekA, false);
      final c = await run(ekA2, true);
      expect(a.rootKey, isNot(b.rootKey));
      expect(a.rootKey, isNot(c.rootKey));
    });
  });
}

// Synchronous public-key extraction helper is not available, so tests that
// need one in a non-async context use this cached lookup.
List<int> await_(SimpleKeyPair kp) => (kp as SimpleKeyPairData).publicKey.bytes;
