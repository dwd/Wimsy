/// Pure-Dart implementation of the X3DH key agreement exactly as performed by
/// libsignal (the "Signal protocol version 3" handshake used by every real
/// legacy-OMEMO / XEP-0384 v0.3.0 client: Conversations, Gajim, Dino, ...).
///
/// Why this exists: `omemo_dart` has its own X3DH (different HKDF info
/// strings, different concatenation order), so it cannot agree on a root key
/// with a real client. This file reimplements the libsignal flavour from
/// scratch using only `package:cryptography` primitives (X25519 and
/// HKDF-SHA256), keeping the project MIT-only (no libsignal ports).
///
/// Algorithm (as written down in libsignal's `RatchetingSession`):
///
///   secrets = 0xFF * 32                       // "discontinuity bytes", v3
///          || DH(SPK_B, IK_A)
///          || DH(IK_B,  EK_A)
///          || DH(SPK_B, EK_A)
///          || DH(OPK_B, EK_A)                 // only if a one-time prekey
///                                             // was used
///   (rootKey, chainKey) = HKDF-SHA256(
///       ikm = secrets, salt = 32 zero bytes, info = "WhisperText", 64 bytes)
///
/// where A is the initiator (sender of the `PreKeySignalMessage`), B the
/// responder (owner of the prekey bundle), IK = identity key, SPK = signed
/// prekey, OPK = one-time prekey and EK = the initiator's ephemeral "base
/// key". Note the DH concatenation order is libsignal's (the one above),
/// which differs from e.g. a listing that starts with DH(IK_B, EK_A); the
/// order feeds the KDF, so it matters for interoperability. (The Bob-side
/// code below computes the same four values with the roles of the keys
/// swapped, which yields identical DH outputs in the same order.)
///
/// Key encoding: real clients transmit identity/base/ratchet public keys
/// "DJB-type-prefixed" (33 bytes, leading 0x05 then the raw 32-byte X25519
/// key). Public-key inputs to this file may be either form; the prefix is
/// stripped before the DH. Our own identity key is a plain X25519 key (see
/// `xeddsa.dart`).
///
/// VERIFICATION STATUS: no external known-answer vectors were available in
/// the sandbox, so this is covered by self-consistency tests only
/// (initiator and responder derive identical secrets) plus tests that the
/// output depends on every input. The exact DH order, the 32x0xFF prefix and
/// the "WhisperText" info string were written from knowledge of libsignal's
/// `RatchetingSession.calculateDerivedKeys`; a human should double check
/// against an authoritative libsignal source (or a real captured session
/// with known private keys) before trusting this in production.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// libsignal's key-type tag for Curve25519 ("DJB") public keys.
const int kDjbKeyType = 0x05;

/// HKDF info string for the initial (X3DH) root/chain key derivation.
const String kLegacyX3dhInfo = 'WhisperText';

/// Returns the raw 32-byte X25519 public key for [key], which may be either
/// a raw 32-byte key or a 33-byte DJB-type-prefixed key.
///
/// Throws [ArgumentError] for any other length or an unknown type byte.
Uint8List stripDjbType(List<int> key) {
  if (key.length == 33) {
    if (key[0] != kDjbKeyType) {
      throw ArgumentError(
        'Unknown key type byte 0x${key[0].toRadixString(16)}',
      );
    }
    return Uint8List.fromList(key.sublist(1));
  }
  if (key.length == 32) {
    return Uint8List.fromList(key);
  }
  throw ArgumentError('Invalid public key length ${key.length}');
}

/// Returns the 33-byte DJB-type-prefixed form of a raw 32-byte [key].
Uint8List addDjbType(List<int> key) {
  if (key.length != 32) {
    throw ArgumentError('Expected a raw 32-byte key, got ${key.length}');
  }
  return Uint8List.fromList([kDjbKeyType, ...key]);
}

/// Computes the raw X25519 shared secret between our [keyPair] and the
/// peer's public key [theirPublicKey] (raw or DJB-prefixed).
Future<Uint8List> legacyDh(
  SimpleKeyPair keyPair,
  List<int> theirPublicKey,
) async {
  final secret = await X25519().sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(
      stripDjbType(theirPublicKey),
      type: KeyPairType.x25519,
    ),
  );
  return Uint8List.fromList(await secret.extractBytes());
}

/// HKDF-SHA256 as used throughout libsignal. A null [salt] means 32 zero
/// bytes (the RFC 5869 default for SHA-256, which is what libsignal's
/// `HKDFv3` uses when no salt is given).
Future<Uint8List> legacyHkdf({
  required List<int> ikm,
  List<int>? salt,
  required String info,
  required int length,
}) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
  final out = await hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: salt ?? Uint8List(32),
    info: info.codeUnits,
  );
  return Uint8List.fromList(await out.extractBytes());
}

/// The result of the X3DH agreement: the initial root key and the first
/// chain key, which seed the Double Ratchet (see
/// `legacy_double_ratchet.dart`).
class LegacyX3dhResult {
  const LegacyX3dhResult({required this.rootKey, required this.chainKey});

  /// 32-byte initial root key.
  final Uint8List rootKey;

  /// 32-byte initial chain key.
  final Uint8List chainKey;
}

Future<LegacyX3dhResult> _derive(List<Uint8List> dhOutputs) async {
  final secrets = BytesBuilder()..add(List<int>.filled(32, 0xff));
  for (final dh in dhOutputs) {
    secrets.add(dh);
  }
  final okm = await legacyHkdf(
    ikm: secrets.toBytes(),
    info: kLegacyX3dhInfo,
    length: 64,
  );
  return LegacyX3dhResult(
    rootKey: Uint8List.sublistView(okm, 0, 32),
    chainKey: Uint8List.sublistView(okm, 32, 64),
  );
}

/// X3DH from the point of view of the *receiver* of a `PreKeySignalMessage`
/// ("Bob", the owner of the prekey bundle), i.e. what we run in
/// `decryptIncoming`.
///
/// [theirIdentityKey] and [theirBaseKey] come from the
/// `PreKeySignalMessageWire` (DJB-prefixed). [ourOneTimePreKey] must be
/// supplied iff the message carried a one-time prekey id.
Future<LegacyX3dhResult> legacyX3dhReceiver({
  required SimpleKeyPair ourIdentityKey,
  required SimpleKeyPair ourSignedPreKey,
  SimpleKeyPair? ourOneTimePreKey,
  required List<int> theirIdentityKey,
  required List<int> theirBaseKey,
}) {
  return Future(
    () async => _derive([
      await legacyDh(ourSignedPreKey, theirIdentityKey),
      await legacyDh(ourIdentityKey, theirBaseKey),
      await legacyDh(ourSignedPreKey, theirBaseKey),
      if (ourOneTimePreKey != null)
        await legacyDh(ourOneTimePreKey, theirBaseKey),
    ]),
  );
}

/// X3DH from the point of view of the *initiator* ("Alice", who fetched the
/// peer's bundle and is sending the first `PreKeySignalMessage`), i.e. what
/// we run in `encryptForSend` for a fresh session.
Future<LegacyX3dhResult> legacyX3dhInitiator({
  required SimpleKeyPair ourIdentityKey,
  required SimpleKeyPair ourBaseKey,
  required List<int> theirIdentityKey,
  required List<int> theirSignedPreKey,
  List<int>? theirOneTimePreKey,
}) {
  return Future(
    () async => _derive([
      await legacyDh(ourIdentityKey, theirSignedPreKey),
      await legacyDh(ourBaseKey, theirIdentityKey),
      await legacyDh(ourBaseKey, theirSignedPreKey),
      if (theirOneTimePreKey != null)
        await legacyDh(ourBaseKey, theirOneTimePreKey),
    ]),
  );
}
