import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omemo_dart/omemo_dart.dart' as omemo_dart;

import 'package:wimsy/encryption/xeddsa.dart';

void main() {
  group('convertMontgomeryToEdwards', () {
    test('agrees with the vendored omemo_dart copy of the same conversion', () {
      // `vendor/omemo_dart/lib/src/xeddsa_convert.dart` independently
      // re-implements this exact conversion (see its doc comment for why
      // it can't just import this file), since it's needed inside the
      // vendored library itself. Both must produce identical output.
      final u = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7) % 256));
      final ours = convertMontgomeryToEdwards(u);
      final vendored = omemo_dart.convertMontgomeryToEdwards(u);
      expect(ours, vendored);
    });

    test(
      'round-trips through OmemoPublicKey.toCurve25519 (the forward map) '
      'back to the original u-coordinate, independent of the sign bit',
      () async {
        // This is the algebraic property that
        // `OmemoBundle.ikIsX25519`/`x3dhFromBundle`/`omemoDH` all rely on:
        // converting a real client's raw X25519 identity-key bytes to the
        // Edwards form (for Ed25519 signature verification) and then back
        // via the library's existing, unmodified forward conversion (used
        // for the X3DH ECDH step) must reproduce the exact original bytes.
        //
        // Note: this round-trip is only guaranteed for `u` values that are
        // genuine X25519 public keys (i.e. `u = scalarMultBase(k)` for some
        // clamped scalar `k`, landing on the curve's main subgroup) -- not
        // for arbitrary 32-byte strings, some of which correspond to the
        // quadratic twist and have no valid birational-equivalent Edwards
        // point (`convertMontgomeryToEdwards`'s `y` would have no square
        // root `x`, a case `OmemoPublicKey.toCurve25519`'s `_unpackneg`
        // detects and -- as `toCurve25519` ignores its return code --
        // silently yields all-zero bytes for). This matches exactly how
        // real legacy-OMEMO clients' identity keys are used in practice
        // (always genuine X25519 public keys from a real keypair).
        final x25519 = Cryptography.instance.x25519();
        for (final sign in [0, 1]) {
          final keyPair = await x25519.newKeyPair();
          final publicKey = await keyPair.extractPublicKey();
          final u = Uint8List.fromList(publicKey.bytes);

          final edwardsBytes = convertMontgomeryToEdwards(u, sign: sign);
          final edwardsPublicKey = omemo_dart.OmemoPublicKey.fromBytes(
            edwardsBytes,
            KeyPairType.ed25519,
          );
          final roundTripped = await edwardsPublicKey.toCurve25519();
          expect(await roundTripped.getBytes(), u);
        }
      },
    );
  });

  group('calculateKeyPair / xeddsaSign', () {
    test(
      'produces a signature that a standard Ed25519 verify accepts for the '
      'convert_mont-derived public key (self-consistency with xeddsa_verify)',
      () async {
        // This is the core correctness property required for interop: real
        // legacy-OMEMO clients verify our SPK signature by computing
        // `A = convert_mont(our_raw_x25519_ik_bytes)` and then doing a
        // standard Ed25519 verify of (R, s) over the message for public
        // key A. We don't need to reimplement `xeddsa_verify` -- using
        // `package:cryptography`'s Ed25519().verify directly on the
        // converted key is mathematically identical (see the XEdDSA spec:
        // "XEd25519 signatures are valid Ed25519 signatures and vice
        // versa").
        final rawPrivateKey = List<int>.generate(32, (i) => (i * 13 + 1) % 256);
        final x25519 = Cryptography.instance.x25519();
        final keyPair = await x25519.newKeyPairFromSeed(rawPrivateKey);
        final publicKey = await keyPair.extractPublicKey();
        final uBytes = publicKey.bytes;

        const message = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        final signature = xeddsaSign(
          rawPrivateKey,
          message,
          random: List<int>.filled(64, 0x42),
        );
        expect(signature.length, 64);

        final edwardsPublicKey = convertMontgomeryToEdwards(uBytes);
        final verified = await Ed25519().verify(
          message,
          signature: Signature(
            signature,
            publicKey: SimplePublicKey(
              edwardsPublicKey,
              type: KeyPairType.ed25519,
            ),
          ),
        );
        expect(verified, isTrue);
      },
    );

    test('calculateKeyPair always yields a public key with sign bit 0', () {
      for (var seed = 0; seed < 5; seed++) {
        final k = List<int>.generate(32, (i) => (i * 17 + seed) % 256);
        final pair = calculateKeyPair(k);
        expect(pair.edwardsPublicKey[31] & 0x80, 0);
      }
    });

    test(
      'is deterministic for a fixed private key and random input, but '
      'produces different signatures for different random input',
      () {
        final k = List<int>.generate(32, (i) => i);
        const message = [0xaa, 0xbb, 0xcc];
        final sig1 = xeddsaSign(k, message, random: List<int>.filled(64, 1));
        final sig2 = xeddsaSign(k, message, random: List<int>.filled(64, 1));
        final sig3 = xeddsaSign(k, message, random: List<int>.filled(64, 2));
        expect(sig1, sig2);
        expect(sig1, isNot(sig3));
      },
    );

    test(
      'rejects a signature verified against the wrong message or wrong key',
      () async {
        final rawPrivateKey = List<int>.generate(32, (i) => (255 - i));
        final x25519 = Cryptography.instance.x25519();
        final keyPair = await x25519.newKeyPairFromSeed(rawPrivateKey);
        final publicKey = await keyPair.extractPublicKey();

        const message = [9, 9, 9];
        final signature = xeddsaSign(
          rawPrivateKey,
          message,
          random: List<int>.filled(64, 0x7),
        );
        final edwardsPublicKey = convertMontgomeryToEdwards(publicKey.bytes);

        final verifiedWrongMessage = await Ed25519().verify(
          [9, 9, 8],
          signature: Signature(
            signature,
            publicKey: SimplePublicKey(
              edwardsPublicKey,
              type: KeyPairType.ed25519,
            ),
          ),
        );
        expect(verifiedWrongMessage, isFalse);

        final otherPrivateKey = List<int>.generate(32, (i) => i + 1);
        final otherKeyPair = await x25519.newKeyPairFromSeed(otherPrivateKey);
        final otherPublicKey = await otherKeyPair.extractPublicKey();
        final otherEdwardsPublicKey = convertMontgomeryToEdwards(
          otherPublicKey.bytes,
        );
        final verifiedWrongKey = await Ed25519().verify(
          message,
          signature: Signature(
            signature,
            publicKey: SimplePublicKey(
              otherEdwardsPublicKey,
              type: KeyPairType.ed25519,
            ),
          ),
        );
        expect(verifiedWrongKey, isFalse);
      },
    );
  });
}
