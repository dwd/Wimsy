import 'dart:convert';
import 'dart:math' show min;

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

/// Encodes an OMEMO/OMEMO2 long-term identity key pair (`OmemoDevice.ik`,
/// an Ed25519 keypair) as a PEM-style block so it can be copied out of the
/// app (e.g. into a password manager) and later restored with
/// [identityKeyPairFromPem]/[deviceFromIdentityKeyExport]. This is *not*
/// the Double Ratchet's per-session root key (`OmemoDoubleRatchet.rk`,
/// which is ephemeral session state, not something worth backing up) --
/// it's the single long-term key that anchors a device's fingerprint.
///
/// The body is the key pair's JSON representation (see
/// [omemoKeyPairToJson]) base64-encoded and wrapped at 64 columns, matching
/// the general shape of a PEM block (RFC 7468) even though the payload
/// itself is JSON rather than DER.
Future<String> identityKeyPairToPem(OmemoKeyPair ik, String label) async {
  final json = await omemoKeyPairToJson(ik);
  final payload = base64Encode(utf8.encode(jsonEncode(json)));
  final buffer = StringBuffer('-----BEGIN $label IDENTITY KEY-----\n');
  for (var i = 0; i < payload.length; i += 64) {
    buffer
      ..write(payload.substring(i, min(i + 64, payload.length)))
      ..write('\n');
  }
  buffer.write('-----END $label IDENTITY KEY-----');
  return buffer.toString();
}

/// Parses a PEM-style block produced by [identityKeyPairToPem] back into an
/// [OmemoKeyPair]. Throws a [FormatException] if [pem] doesn't contain a
/// `BEGIN $label IDENTITY KEY` / `END $label IDENTITY KEY` block (e.g.
/// because the user pasted an OMEMO2 export into the legacy OMEMO import
/// field, or vice-versa) or if its contents are malformed.
OmemoKeyPair identityKeyPairFromPem(String pem, String label) {
  final beginMarker = '-----BEGIN $label IDENTITY KEY-----';
  final endMarker = '-----END $label IDENTITY KEY-----';
  final beginIndex = pem.indexOf(beginMarker);
  final endIndex = pem.indexOf(endMarker);
  if (beginIndex == -1 || endIndex == -1 || endIndex < beginIndex) {
    throw FormatException(
      'Not a valid $label identity key export (missing $beginMarker / '
      '$endMarker markers)',
    );
  }
  final body = pem
      .substring(beginIndex + beginMarker.length, endIndex)
      .replaceAll(RegExp(r'\s+'), '');
  if (body.isEmpty) {
    throw const FormatException('Identity key export has an empty body');
  }
  final json = jsonDecode(utf8.decode(base64Decode(body)));
  return omemoKeyPairFromJson((json as Map).cast<dynamic, dynamic>());
}

/// Builds a brand-new [OmemoDevice] for [jid] that reuses an imported
/// identity key [ik] (e.g. from [identityKeyPairFromPem]) instead of
/// generating a fresh one, so that a restored device keeps the same
/// fingerprint it had before. Everything else (device id, signed prekey,
/// its signature, and the one-time prekeys) is freshly generated, mirroring
/// `OmemoDevice.generateNewDevice` -- the signed-prekey signature is
/// recomputed against the imported [ik] since it must match.
Future<OmemoDevice> deviceFromIdentityKeyExport(
  String jid,
  OmemoKeyPair ik, {
  int opkAmount = 100,
}) async {
  final spk = await OmemoKeyPair.generateNewPair(KeyPairType.x25519);
  final spkId = generateRandom32BitNumber();
  final signature = await sig(ik, await spk.pk.getBytes());

  final opks = <int, OmemoKeyPair>{};
  for (var i = 0; i < opkAmount; i++) {
    while (true) {
      final opkId = generateRandom32BitNumber();
      if (opks.containsKey(opkId)) {
        continue;
      }
      opks[opkId] = await OmemoKeyPair.generateNewPair(KeyPairType.x25519);
      break;
    }
  }

  return OmemoDevice(
    jid,
    generateRandom32BitNumber(),
    ik,
    spk,
    spkId,
    signature,
    null,
    null,
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
  var bytes = base64Decode(json['pk'] as String);
  // Defensive: a ratchet session established with a legacy-OMEMO contact
  // before the libsignal DJB-type-byte fix (see
  // `lib/encryption/omemo_backend.dart`'s `_stripDjbKeyTypeBytes`) may
  // have persisted a 33-byte (type-byte-prefixed) remote identity key as
  // part of its `OmemoDoubleRatchet.ik`/`KeyExchangeData.ik` state. Such a
  // ratchet is never re-created on its own (it's loaded from storage, not
  // re-derived via X3DH), so it would otherwise keep reproducing
  // "Algorithm ed25519 expects a public key with 32 bytes, but got: 33
  // bytes" on every encrypt/decrypt indefinitely. Both `omemo_dart` key
  // types are always exactly 32 raw bytes, so stripping a stray leading
  // byte here is always safe (and a no-op for OMEMO2, which never adds
  // one).
  if (bytes.length == 33) {
    bytes = bytes.sublist(1);
  }
  return OmemoPublicKey.fromBytes(bytes, type);
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
