import 'package:meta/meta.dart';
import 'package:omemo_dart/src/errors.dart';

@immutable
class DecryptionResult {
  const DecryptionResult(
    this.payload,
    this.usedOpkId,
    this.newRatchets,
    this.replacedRatchets,
    this.error, {
    this.rawKeyMaterial,
  });

  /// The decrypted payload or null, if it was an empty OMEMO message.
  final String? payload;

  /// The ratchet-unwrapped raw key material transported for this message,
  /// populated only when [OmemoIncomingStanza.skipPayloadDecryption] was
  /// true. Null for an empty OMEMO message (i.e. no payload was sent) or
  /// when payload decryption was performed internally as usual.
  final List<int>? rawKeyMaterial;

  /// In case a key exchange has been performed: The id of the used OPK. Useful for
  /// replacing the OPK after a message catch-up.
  final int? usedOpkId;

  /// Mapping of JIDs to a list of device ids for which we created a new ratchet session.
  final Map<String, List<int>> newRatchets;

  /// Similar to [newRatchets], but the ratchets listed in [replacedRatchets] where also existent before
  /// and replaced with the new ratchet.
  final Map<String, List<int>> replacedRatchets;

  /// The error that occurred during decryption or null, if no error occurred.
  final OmemoError? error;
}
