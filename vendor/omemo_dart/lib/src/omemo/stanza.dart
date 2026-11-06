import 'package:omemo_dart/src/omemo/encrypted_key.dart';

/// Describes a stanza that was received by the underlying XMPP library.
class OmemoIncomingStanza {
  const OmemoIncomingStanza(
    this.bareSenderJid,
    this.senderDeviceId,
    this.keys,
    this.payload,
    this.isCatchup, {
    this.skipPayloadDecryption = false,
  });

  /// The bare JID of the sender of the stanza.
  final String bareSenderJid;

  /// The device ID of the sender.
  final int senderDeviceId;

  /// The included encrypted keys for our own JID
  final List<EncryptedKey> keys;

  /// The string payload included in the <encrypted /> element.
  final String? payload;

  /// Flag indicating whether the message was received due to a catchup.
  final bool isCatchup;

  /// If true, [OmemoManager] will not attempt to decrypt/verify [payload]
  /// itself using its built-in AES-256-CBC+HMAC-SHA-256 payload cipher.
  /// Instead, the ratchet-unwrapped raw key material (whatever bytes were
  /// transported through the Double Ratchet for this message, e.g. the
  /// AES-256 key + truncated HMAC used by OMEMO2, or some other
  /// cipher-specific key material used by a different payload cipher) is
  /// returned via [DecryptionResult.rawKeyMaterial] instead, so a caller can
  /// apply its own payload cipher (e.g. legacy OMEMO's AES-128-GCM). This
  /// still reuses all of the existing device-list/bundle/trust/KEX/ratchet
  /// machinery; only the hardcoded payload decryption step is skipped.
  final bool skipPayloadDecryption;
}

/// Describes a stanza that is to be sent out
class OmemoOutgoingStanza {
  const OmemoOutgoingStanza(
    this.recipientJids,
    this.payload, {
    this.rawKeyMaterial,
    this.ciphertext,
  });

  /// The JIDs the stanza will be sent to.
  final List<String> recipientJids;

  /// The serialised XML data that should be encrypted.
  ///
  /// When [rawKeyMaterial] is non-null, this is ignored for the purpose of
  /// generating [EncryptionResult.ciphertext] (the caller-supplied
  /// [ciphertext] is used instead); it is still useful only as an
  /// indication of whether a payload is being sent at all.
  final String? payload;

  /// If non-null, [OmemoManager] will not generate its own random AES-256
  /// key and will not perform its built-in AES-256-CBC+HMAC-SHA-256
  /// encryption of [payload]. Instead, these exact bytes are ratchet-wrapped
  /// (per-device, via the usual X3DH/Double-Ratchet session machinery) and
  /// transported as the per-device encrypted key, so a caller can supply
  /// key material for a different payload cipher (e.g. legacy OMEMO's
  /// AES-128-GCM 16-byte key + 16-byte GCM tag). Must be accompanied by
  /// [ciphertext] (the already-encrypted payload bytes), which is used
  /// as-is for [EncryptionResult.ciphertext].
  final List<int>? rawKeyMaterial;

  /// The already-encrypted payload bytes to use when [rawKeyMaterial] is
  /// set. Ignored otherwise.
  final List<int>? ciphertext;
}
