import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:hex/hex.dart';
import 'package:omemo_dart/src/keys.dart';
import 'package:omemo_dart/src/xeddsa_convert.dart';

class OmemoBundle {
  const OmemoBundle(
    this.jid,
    this.id,
    this.spkEncoded,
    this.spkId,
    this.spkSignatureEncoded,
    this.ikEncoded,
    this.opksEncoded, {
    this.spkSignatureMessageEncoded,
    this.ikIsX25519 = false,
  });

  /// The bare Jid the Bundle belongs to
  final String jid;

  /// The device Id
  final int id;

  /// The SPK but base64 encoded
  final String spkEncoded;
  final int spkId;

  /// The SPK signature but base64 encoded
  final String spkSignatureEncoded;

  /// The IK but base64 encoded
  final String ikEncoded;

  /// The mapping of a OPK's id to the base64 encoded data
  final Map<int, String> opksEncoded;

  /// The base64-encoded bytes that [spkSignatureEncoded] is actually a
  /// signature *over*, if different from [spkEncoded] itself.
  ///
  /// Per the XEdDSA/libsignal convention (see
  /// https://signal.org/docs/specifications/xeddsa and e.g. libsignal's
  /// `SignedPreKeyRecord`, which signs `publicKey.serialize()`), real
  /// legacy-OMEMO clients (XEP-0384 v0.3.0, Conversations/Gajim/Dino)
  /// sign the *serialized* SPK public key, which includes a leading
  /// "DJB type" byte (`0x05`) -- i.e. 33 bytes, not the raw 32-byte
  /// Curve25519 key that [spkEncoded] holds once that type byte has been
  /// stripped for use in X3DH/ECDH. When a caller needs to verify a
  /// bundle whose signature was computed over that longer, type-prefixed
  /// form, it can set this field to the original (unstripped) bytes so
  /// [spkSignatureMessage] returns the correct message to verify against,
  /// while [spk] still yields the raw key needed for the Diffie-Hellman
  /// math. Left `null` (falling back to [spkEncoded]) for OMEMO2
  /// (`urn:xmpp:omemo:2`) bundles and any other producer that signs the
  /// raw key directly.
  final String? spkSignatureMessageEncoded;

  /// Whether [ikEncoded] holds a raw Curve25519 (X25519) `u` coordinate
  /// (as published by real legacy-OMEMO clients, XEP-0384 v0.3.0, for
  /// their identity key -- see https://signal.org/docs/specifications/xeddsa)
  /// rather than a genuine Ed25519-encoded point. Defaults to `false`, so
  /// OMEMO2 (`urn:xmpp:omemo:2`, genuine Ed25519 identity keys) and any
  /// other existing caller is completely unaffected.
  ///
  /// When `true`, [ik] applies the Montgomery->Edwards birational map
  /// (`convert_mont(u, sign=0)`) to [ikEncoded] before returning it, so
  /// that the *unmodified* Ed25519-signature-verification code in
  /// `x3dhFromBundle` and the *unmodified* `OmemoPublicKey.toCurve25519()`
  /// forward conversion used for the X3DH ECDH step both "just work" --
  /// the forward (Edwards->Montgomery) map `toCurve25519()` already
  /// performs is the algebraic inverse of `convert_mont`'s
  /// (Montgomery->Edwards) map, independent of the discarded sign bit
  /// (see `test/xeddsa_test.dart` for a dedicated round-trip test of this
  /// property). [getFingerprint] intentionally does *not* use [ik] (see
  /// below), so the Edwards-converted form never leaks into the
  /// user-visible fingerprint.
  final bool ikIsX25519;

  /// The bytes that [spkSignature] is a signature over. See
  /// [spkSignatureMessageEncoded].
  List<int> get spkSignatureMessage =>
      base64Decode(spkSignatureMessageEncoded ?? spkEncoded);

  OmemoPublicKey get spk {
    final data = base64Decode(spkEncoded);
    return OmemoPublicKey.fromBytes(data, KeyPairType.x25519);
  }

  OmemoPublicKey get ik {
    final data = base64Decode(ikEncoded);
    if (ikIsX25519) {
      return OmemoPublicKey.fromBytes(
        convertMontgomeryToEdwards(data),
        KeyPairType.ed25519,
      );
    }
    return OmemoPublicKey.fromBytes(data, KeyPairType.ed25519);
  }

  OmemoPublicKey getOpk(int id) {
    final data = base64Decode(opksEncoded[id]!);
    return OmemoPublicKey.fromBytes(data, KeyPairType.x25519);
  }

  List<int> get spkSignature => base64Decode(spkSignatureEncoded);

  /// Calculates the fingerprint of the bundle (See
  /// https://xmpp.org/extensions/xep-0384.html#security § 2).
  ///
  /// Always fingerprints the genuine identity-key bytes as published
  /// (i.e. [ikEncoded] directly) rather than going through [ik], since
  /// [ik] applies the Montgomery->Edwards conversion when [ikIsX25519] is
  /// set -- a form real clients (e.g. Conversations) never display and
  /// that must not leak into the user-visible fingerprint.
  Future<String> getFingerprint() async {
    return HEX.encode(base64Decode(ikEncoded));
  }
}
