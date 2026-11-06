import 'dart:typed_data';

/// Pure field-arithmetic helper implementing the Montgomery->Edwards
/// birational map used by XEdDSA (see
/// https://signal.org/docs/specifications/xeddsa section 2, "u_to_y"), so
/// a raw Curve25519 (X25519) public key `u` coordinate -- as published by
/// real legacy-OMEMO clients (Conversations/Gajim/Dino, XEP-0384 v0.3.0)
/// for their identity key -- can be reinterpreted as the equivalent
/// Ed25519 public key point `A` for standard Ed25519 signature
/// verification (`package:cryptography`'s `Ed25519().verify`), without
/// needing any Edwards-curve point/scalar arithmetic (only modular field
/// inversion).
///
/// This is a local, additive addition to the vendored library (see
/// `VENDORING.md`), needed because it must be applied *inside*
/// `OmemoManager._onIncomingStanzaImpl` (to a remote device's identity
/// key parsed from an incoming `<key kex="true">` element) where
/// application-level code cannot easily intercept. The companion
/// signing-side math (which does need Edwards point arithmetic, since
/// *our own* signing key is derived from the raw Montgomery scalar) lives
/// in the application instead, at `lib/encryption/xeddsa.dart`, since
/// only our own device generation needs it. Both independently implement
/// this same conversion (duplicated, not shared, to avoid a dependency
/// cycle between the vendored package and the app); see
/// `test/xeddsa_test.dart` for a cross-check that the two agree.
///
/// [sign] selects which of the two points `+-A` on the curve to return
/// (0 or 1, encoded as the top bit of the last byte); verifiers always use
/// sign 0 by convention (`convert_mont(u)` in the XEdDSA spec).
List<int> convertMontgomeryToEdwards(List<int> uBytes, {int sign = 0}) {
  assert(
    uBytes.length == 32,
    'u must be a 32-byte Curve25519 coordinate',
  );
  final p = BigInt.two.pow(255) - BigInt.from(19);
  final u = _mod(_decodeLittleEndian(uBytes), p);
  final numerator = _mod(u - BigInt.one, p);
  final denominator = _mod(u + BigInt.one, p);
  final denominatorInv = denominator.modPow(p - BigInt.two, p);
  final y = _mod(numerator * denominatorInv, p);
  final encoded = _encodeLittleEndian(y, 32);
  if (sign & 1 == 1) {
    encoded[31] |= 0x80;
  } else {
    encoded[31] &= 0x7f;
  }
  return encoded;
}

BigInt _mod(BigInt a, BigInt m) {
  final r = a % m;
  return r.isNegative ? r + m : r;
}

BigInt _decodeLittleEndian(List<int> bytes) {
  var result = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    result = (result << 8) | BigInt.from(bytes[i] & 0xff);
  }
  return result;
}

Uint8List _encodeLittleEndian(BigInt value, int length) {
  final bytes = Uint8List(length);
  var v = value;
  final mask = BigInt.from(0xff);
  for (var i = 0; i < length; i++) {
    bytes[i] = (v & mask).toInt();
    v = v >> 8;
  }
  return bytes;
}
