import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:omemo_dart/omemo_dart.dart';

/// Helpers to (de)serialise `omemo_dart`'s runtime objects (the local
/// device's cryptographic identity, and Double Ratchet session state) to
/// and from JSON-compatible `Map`s, so they can be persisted by
/// [StorageService]/[SecureStore].
///
/// `omemo_dart` itself does not ship `toJson`/`fromJson` helpers (see
/// `vendor/omemo_dart`), so this module owns the on-disk representation.
/// All binary key material is base64-encoded.

Map<String, dynamic> keyPairTypeToJson(KeyPairType type) {
  if (type == KeyPairType.ed25519) return {'type': 'ed25519'};
  if (type == KeyPairType.x25519) return {'type': 'x25519'};
  throw ArgumentError('Unsupported KeyPairType: $type');
}

KeyPairType keyPairTypeFromJson(Map<dynamic, dynamic> json) {
  switch (json['type']) {
    case 'ed25519':
      return KeyPairType.ed25519;
    case 'x25519':
      return KeyPairType.x25519;
    default:
      throw ArgumentError('Unknown KeyPairType: ${json['type']}');
  }
}

Future<Map<String, dynamic>> omemoKeyPairToJson(OmemoKeyPair pair) async {
  return {
    'type': pair.type == KeyPairType.ed25519 ? 'ed25519' : 'x25519',
    'pk': base64Encode(await pair.pk.getBytes()),
    'sk': base64Encode(await pair.sk.getBytes()),
  };
}

OmemoKeyPair omemoKeyPairFromJson(Map<dynamic, dynamic> json) {
  final type = json['type'] == 'ed25519'
      ? KeyPairType.ed25519
      : KeyPairType.x25519;
  return OmemoKeyPair.fromBytes(
    base64Decode(json['pk'] as String),
    base64Decode(json['sk'] as String),
    type,
  );
}

/// Serialises an [OmemoDevice] (our own cryptographic identity, including
/// private key material) to a JSON-compatible map. The result is intended
/// to be stored in [SecureStore], never in plain Hive storage.
Future<Map<String, dynamic>> omemoDeviceToJson(OmemoDevice device) async {
  return {
    'jid': device.jid,
    'id': device.id,
    'ik': await omemoKeyPairToJson(device.ik),
    'spk': await omemoKeyPairToJson(device.spk),
    'spkId': device.spkId,
    'spkSignature': base64Encode(device.spkSignature),
    'oldSpk': device.oldSpk == null
        ? null
        : await omemoKeyPairToJson(device.oldSpk!),
    'oldSpkId': device.oldSpkId,
    'opks': {
      for (final entry in device.opks.entries)
        entry.key.toString(): await omemoKeyPairToJson(entry.value),
    },
  };
}

Future<OmemoDevice> omemoDeviceFromJson(Map<dynamic, dynamic> json) async {
  final opksJson = (json['opks'] as Map).cast<dynamic, dynamic>();
  final opks = <int, OmemoKeyPair>{
    for (final entry in opksJson.entries)
      int.parse(entry.key.toString()): omemoKeyPairFromJson(
        (entry.value as Map).cast<dynamic, dynamic>(),
      ),
  };
  final oldSpkJson = json['oldSpk'];
  return OmemoDevice(
    json['jid'] as String,
    json['id'] as int,
    omemoKeyPairFromJson((json['ik'] as Map).cast<dynamic, dynamic>()),
    omemoKeyPairFromJson((json['spk'] as Map).cast<dynamic, dynamic>()),
    json['spkId'] as int,
    base64Decode(json['spkSignature'] as String),
    oldSpkJson == null
        ? null
        : omemoKeyPairFromJson((oldSpkJson as Map).cast<dynamic, dynamic>()),
    json['oldSpkId'] as int?,
    opks,
  );
}

Future<Map<String, dynamic>> omemoPublicKeyToJson(
  OmemoPublicKey key,
) async {
  return {
    'type': key.type == KeyPairType.ed25519 ? 'ed25519' : 'x25519',
    'pk': base64Encode(await key.getBytes()),
  };
}

OmemoPublicKey omemoPublicKeyFromJson(Map<dynamic, dynamic> json) {
  final type = json['type'] == 'ed25519'
      ? KeyPairType.ed25519
      : KeyPairType.x25519;
  return OmemoPublicKey.fromBytes(base64Decode(json['pk'] as String), type);
}

/// Serialises an [OmemoDoubleRatchet] session's state to a JSON-compatible
/// map, so it can be persisted in Hive and restored across app restarts.
Future<Map<String, dynamic>> omemoRatchetToJson(
  OmemoDoubleRatchet ratchet,
) async {
  return {
    'dhs': await omemoKeyPairToJson(ratchet.dhs),
    'dhr': ratchet.dhr == null ? null : await omemoPublicKeyToJson(ratchet.dhr!),
    'rk': base64Encode(ratchet.rk),
    'cks': ratchet.cks == null ? null : base64Encode(ratchet.cks!),
    'ckr': ratchet.ckr == null ? null : base64Encode(ratchet.ckr!),
    'ns': ratchet.ns,
    'nr': ratchet.nr,
    'pn': ratchet.pn,
    'ik': await omemoPublicKeyToJson(ratchet.ik),
    'sessionAd': base64Encode(ratchet.sessionAd),
    'acknowledged': ratchet.acknowledged,
    'kex': {
      'pkId': ratchet.kex.pkId,
      'spkId': ratchet.kex.spkId,
      'ek': await omemoPublicKeyToJson(ratchet.kex.ek),
      'ik': await omemoPublicKeyToJson(ratchet.kex.ik),
    },
    // Skipped message keys are intentionally not persisted across restarts;
    // they are a best-effort out-of-order-delivery optimisation and will
    // simply be unavailable for messages that arrive after a restart in an
    // order that would have required them. This mirrors a conservative,
    // "lose a few out-of-order messages rather than risk corrupting ratchet
    // state" tradeoff.
  };
}

Future<OmemoDoubleRatchet> omemoRatchetFromJson(
  Map<dynamic, dynamic> json,
) async {
  final kexJson = (json['kex'] as Map).cast<dynamic, dynamic>();
  return OmemoDoubleRatchet(
    omemoKeyPairFromJson((json['dhs'] as Map).cast<dynamic, dynamic>()),
    json['dhr'] == null
        ? null
        : omemoPublicKeyFromJson((json['dhr'] as Map).cast<dynamic, dynamic>()),
    base64Decode(json['rk'] as String),
    json['cks'] == null ? null : base64Decode(json['cks'] as String),
    json['ckr'] == null ? null : base64Decode(json['ckr'] as String),
    json['ns'] as int,
    json['nr'] as int,
    json['pn'] as int,
    omemoPublicKeyFromJson((json['ik'] as Map).cast<dynamic, dynamic>()),
    base64Decode(json['sessionAd'] as String),
    <SkippedKey, List<int>>{},
    json['acknowledged'] as bool,
    KeyExchangeData(
      kexJson['pkId'] as int,
      kexJson['spkId'] as int,
      omemoPublicKeyFromJson((kexJson['ek'] as Map).cast<dynamic, dynamic>()),
      omemoPublicKeyFromJson((kexJson['ik'] as Map).cast<dynamic, dynamic>()),
    ),
  );
}
