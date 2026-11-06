import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:hex/hex.dart';
import 'package:omemo_dart/src/keys.dart';

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
    return OmemoPublicKey.fromBytes(data, KeyPairType.ed25519);
  }

  OmemoPublicKey getOpk(int id) {
    final data = base64Decode(opksEncoded[id]!);
    return OmemoPublicKey.fromBytes(data, KeyPairType.x25519);
  }

  List<int> get spkSignature => base64Decode(spkSignatureEncoded);

  /// Calculates the fingerprint of the bundle (See
  /// https://xmpp.org/extensions/xep-0384.html#security § 2).
  Future<String> getFingerprint() async {
    return HEX.encode(await ik.getBytes());
  }
}
