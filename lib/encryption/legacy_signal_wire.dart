/// Pure-Dart parsing/serialization of libsignal's native wire format for
/// `PreKeySignalMessage` and `SignalMessage` (also known, in XEP-0384
/// v0.3.0 terms, as the byte layout of a `<key prekey='true'>` and a plain
/// `<key>` element's content respectively), as actually produced by real
/// legacy-OMEMO clients (Conversations/Gajim/Dino -- all libsignal-based).
///
/// Background: `omemo_dart` (see `vendor/omemo_dart/`) only implements a
/// different, newer protobuf schema (`OMEMOKeyExchange`/
/// `OMEMOAuthenticatedMessage`, see `vendor/omemo_dart/protobuf/schema.proto`)
/// with no leading version byte, which is *not* what real legacy-OMEMO
/// clients put on the wire. This file is step one (wire-format parsing
/// only, no cryptography) of making legacy OMEMO interoperate with real
/// clients: it lets [OmemoBackend] (see `lib/encryption/omemo_backend.dart`)
/// translate between the two byte layouts. The actual X3DH/Double-Ratchet
/// crypto needed to use these fields is *not* implemented here -- see the
/// class docs on `OmemoBackend` for the current state of that effort.
///
/// Wire layout, confirmed by manually decoding a real captured stanza from
/// Conversations (see `test/legacy_signal_wire_test.dart` for the exact
/// bytes used as a regression fixture):
///
/// `PreKeySignalMessage` := `version` (1 byte) + `protobuf` (no trailing
/// MAC of its own -- the MAC lives inside the nested `message` field's
/// bytes, see below). The embedded protobuf has these fields (observed
/// field numbers, matching libsignal-protocol's `WhisperTextProtocol`
/// `.proto` definitions):
///   - field 1 (varint): `preKeyId`
///   - field 2 (bytes): `baseKey` (libsignal DJB-type-prefixed, 33 bytes)
///   - field 3 (bytes): `identityKey` (libsignal DJB-type-prefixed, 33 bytes)
///   - field 4 (bytes): `message` -- a nested, fully-encoded `SignalMessage`
///     (itself version-byte-prefixed and MAC-suffixed, see below)
///   - field 5 (varint): `registrationId`
///   - field 6 (varint): `signedPreKeyId`
///
/// `SignalMessage` := `version` (1 byte) + `protobuf` + `mac` (8 bytes,
/// appended *outside* the protobuf, i.e. not itself a protobuf field).
/// The embedded protobuf has these fields:
///   - field 1 (bytes): `ratchetKey` (libsignal DJB-type-prefixed, 33 bytes)
///   - field 2 (varint): `counter`
///   - field 3 (varint): `previousCounter`
///   - field 4 (bytes): `ciphertext`
///
/// The `version` byte in both cases packs the current and maximum
/// supported protocol version as two nibbles, `(current << 4) | max`;
/// real clients currently send `0x33` (version 3, the long-standing
/// stable libsignal wire version).
library;

import 'dart:typed_data';

/// The libsignal wire-format version currently used by real clients for
/// both `PreKeySignalMessage` and `SignalMessage` (major=minor=3, i.e.
/// `0x33`).
const int kLegacySignalWireVersion = 3;

/// Number of trailing MAC bytes appended (outside the protobuf) to a
/// serialized [SignalMessageWire].
const int kSignalMessageMacLength = 8;

/// Thrown when parsing a [PreKeySignalMessageWire] or [SignalMessageWire]
/// fails because the bytes are too short, have an unsupported version
/// byte, or are missing a required field.
class LegacySignalWireFormatException implements Exception {
  LegacySignalWireFormatException(this.message);

  final String message;

  @override
  String toString() => 'LegacySignalWireFormatException: $message';
}

/// A single decoded protobuf field: either a varint ([intValue]) or a
/// length-delimited byte string ([bytesValue]), per the minimal subset of
/// the protobuf wire format actually used by libsignal's messages here
/// (fixed32/fixed64 fields are skipped, since none of the fields we care
/// about use them).
class _ProtoField {
  _ProtoField.varint(this.fieldNumber, this.intValue) : bytesValue = null;

  _ProtoField.bytes(this.fieldNumber, this.bytesValue) : intValue = null;

  final int fieldNumber;
  final int? intValue;
  final List<int>? bytesValue;
}

int _readVarint(List<int> buf, int offset, void Function(int) setNext) {
  var result = 0;
  var shift = 0;
  var i = offset;
  while (true) {
    if (i >= buf.length) {
      throw LegacySignalWireFormatException('Truncated varint');
    }
    final b = buf[i];
    i++;
    result |= (b & 0x7f) << shift;
    if ((b & 0x80) == 0) {
      break;
    }
    shift += 7;
  }
  setNext(i);
  return result;
}

void _writeVarint(BytesBuilder out, int value) {
  var v = value;
  while (true) {
    final b = v & 0x7f;
    v >>= 7;
    if (v == 0) {
      out.addByte(b);
      break;
    } else {
      out.addByte(b | 0x80);
    }
  }
}

void _writeTag(BytesBuilder out, int fieldNumber, int wireType) {
  _writeVarint(out, (fieldNumber << 3) | wireType);
}

/// Parses the minimal subset of the protobuf wire format used by
/// libsignal's `PreKeySignalMessage`/`SignalMessage` schemas: varint
/// (wire type 0) and length-delimited (wire type 2) fields only. Any
/// other wire type (fixed32/fixed64/group) causes parsing to stop and the
/// fields decoded so far to be returned, since none of the fields we need
/// use them and real messages don't contain any.
List<_ProtoField> _parseProtoFields(List<int> buf) {
  final fields = <_ProtoField>[];
  var i = 0;
  while (i < buf.length) {
    var next = i;
    final tag = _readVarint(buf, i, (n) => next = n);
    i = next;
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;
    if (wireType == 0) {
      final value = _readVarint(buf, i, (n) => next = n);
      i = next;
      fields.add(_ProtoField.varint(fieldNumber, value));
    } else if (wireType == 2) {
      final length = _readVarint(buf, i, (n) => next = n);
      i = next;
      if (i + length > buf.length) {
        throw LegacySignalWireFormatException(
          'Truncated length-delimited field $fieldNumber',
        );
      }
      fields.add(_ProtoField.bytes(fieldNumber, buf.sublist(i, i + length)));
      i += length;
    } else {
      // Unknown/unsupported wire type: stop parsing rather than risk
      // misinterpreting the remaining bytes.
      break;
    }
  }
  return fields;
}

int? _lastVarint(List<_ProtoField> fields, int fieldNumber) {
  for (final field in fields.reversed) {
    if (field.fieldNumber == fieldNumber && field.intValue != null) {
      return field.intValue;
    }
  }
  return null;
}

List<int>? _lastBytes(List<_ProtoField> fields, int fieldNumber) {
  for (final field in fields.reversed) {
    if (field.fieldNumber == fieldNumber && field.bytesValue != null) {
      return field.bytesValue;
    }
  }
  return null;
}

/// A parsed/serializable libsignal `SignalMessage`, i.e. the content of a
/// plain (non-prekey) `<key>` element in a legacy-OMEMO (XEP-0384 v0.3.0)
/// message from a real client.
///
/// See the library doc comment at the top of this file for the exact wire
/// layout.
class SignalMessageWire {
  const SignalMessageWire({
    required this.version,
    required this.ratchetKey,
    required this.counter,
    required this.previousCounter,
    required this.ciphertext,
    required this.mac,
  });

  /// The protocol version this message was sent with (e.g. `3`).
  final int version;

  /// The sender's current ratchet public key, libsignal DJB-type-prefixed
  /// (33 bytes: a leading `0x05` type byte followed by the raw 32-byte
  /// X25519 key).
  final List<int> ratchetKey;

  /// The message counter within the current sending chain.
  final int counter;

  /// The length of the previous sending chain, used by the receiver to
  /// skip/derive any message keys it missed.
  final int previousCounter;

  final List<int> ciphertext;

  /// The trailing 8-byte MAC, appended outside the protobuf.
  final List<int> mac;

  /// Parses a `SignalMessage` from its wire-format [bytes]: a leading
  /// version byte, a protobuf body, and a trailing 8-byte MAC.
  ///
  /// Throws [LegacySignalWireFormatException] if [bytes] is too short, has
  /// an unsupported version, or is missing a required field.
  factory SignalMessageWire.parse(List<int> bytes) {
    if (bytes.length < 1 + kSignalMessageMacLength) {
      throw LegacySignalWireFormatException(
        'SignalMessage too short: ${bytes.length} bytes',
      );
    }
    final versionByte = bytes[0];
    final version = versionByte >> 4;
    if (version < kLegacySignalWireVersion) {
      throw LegacySignalWireFormatException(
        'Unsupported SignalMessage version: $version',
      );
    }
    final mac = bytes.sublist(bytes.length - kSignalMessageMacLength);
    final body = bytes.sublist(1, bytes.length - kSignalMessageMacLength);
    final fields = _parseProtoFields(body);

    final ratchetKey = _lastBytes(fields, 1);
    final counter = _lastVarint(fields, 2);
    final previousCounter = _lastVarint(fields, 3);
    final ciphertext = _lastBytes(fields, 4);
    if (ratchetKey == null || counter == null || ciphertext == null) {
      throw LegacySignalWireFormatException(
        'SignalMessage missing a required field '
        '(ratchetKey=${ratchetKey != null}, counter=${counter != null}, '
        'ciphertext=${ciphertext != null})',
      );
    }
    return SignalMessageWire(
      version: version,
      ratchetKey: ratchetKey,
      counter: counter,
      previousCounter: previousCounter ?? 0,
      ciphertext: ciphertext,
      mac: mac,
    );
  }

  /// Serializes this `SignalMessage` back to its wire-format byte layout
  /// (version byte, protobuf body, trailing MAC), in the same field order
  /// (1, 2, 3, 4) real clients use.
  Uint8List serialize() {
    final body = BytesBuilder();
    _writeTag(body, 1, 2);
    _writeVarint(body, ratchetKey.length);
    body.add(ratchetKey);
    _writeTag(body, 2, 0);
    _writeVarint(body, counter);
    _writeTag(body, 3, 0);
    _writeVarint(body, previousCounter);
    _writeTag(body, 4, 2);
    _writeVarint(body, ciphertext.length);
    body.add(ciphertext);

    final out = BytesBuilder();
    out.addByte((version << 4) | version);
    out.add(body.toBytes());
    out.add(mac);
    return out.toBytes();
  }
}

/// A parsed/serializable libsignal `PreKeySignalMessage`, i.e. the content
/// of a `<key prekey='true'>` element in a legacy-OMEMO (XEP-0384 v0.3.0)
/// message from a real client.
///
/// See the library doc comment at the top of this file for the exact wire
/// layout.
class PreKeySignalMessageWire {
  const PreKeySignalMessageWire({
    required this.version,
    required this.registrationId,
    required this.preKeyId,
    required this.signedPreKeyId,
    required this.baseKey,
    required this.identityKey,
    required this.message,
  });

  /// The protocol version this message was sent with (e.g. `3`).
  final int version;

  final int registrationId;
  final int preKeyId;
  final int signedPreKeyId;

  /// The sender's ephemeral X3DH base key, libsignal DJB-type-prefixed
  /// (33 bytes).
  final List<int> baseKey;

  /// The sender's identity key, libsignal DJB-type-prefixed (33 bytes).
  final List<int> identityKey;

  /// The nested, fully wire-encoded `SignalMessage` bytes (i.e. the bytes
  /// a [SignalMessageWire.parse] call would accept), *not* yet parsed.
  final List<int> message;

  /// Parses a `PreKeySignalMessage` from its wire-format [bytes]: a
  /// leading version byte followed directly by the protobuf body (no
  /// trailing MAC of its own -- the MAC is inside [message]'s bytes).
  ///
  /// Throws [LegacySignalWireFormatException] if [bytes] is too short, has
  /// an unsupported version, or is missing a required field.
  factory PreKeySignalMessageWire.parse(List<int> bytes) {
    if (bytes.isEmpty) {
      throw LegacySignalWireFormatException('PreKeySignalMessage is empty');
    }
    final versionByte = bytes[0];
    final version = versionByte >> 4;
    if (version < kLegacySignalWireVersion) {
      throw LegacySignalWireFormatException(
        'Unsupported PreKeySignalMessage version: $version',
      );
    }
    final fields = _parseProtoFields(bytes.sublist(1));

    final preKeyId = _lastVarint(fields, 1);
    final baseKey = _lastBytes(fields, 2);
    final identityKey = _lastBytes(fields, 3);
    final message = _lastBytes(fields, 4);
    final registrationId = _lastVarint(fields, 5);
    final signedPreKeyId = _lastVarint(fields, 6);
    if (baseKey == null ||
        identityKey == null ||
        message == null ||
        registrationId == null ||
        signedPreKeyId == null) {
      throw LegacySignalWireFormatException(
        'PreKeySignalMessage missing a required field '
        '(baseKey=${baseKey != null}, identityKey=${identityKey != null}, '
        'message=${message != null}, registrationId=${registrationId != null}, '
        'signedPreKeyId=${signedPreKeyId != null})',
      );
    }
    return PreKeySignalMessageWire(
      version: version,
      registrationId: registrationId,
      // preKeyId is technically optional in the protobuf schema (a
      // PreKeySignalMessage for a one-time-prekey-less bundle wouldn't
      // have one), but real OMEMO prekey bundles always include one, so
      // default to 0 rather than throwing if it's ever absent.
      preKeyId: preKeyId ?? 0,
      signedPreKeyId: signedPreKeyId,
      baseKey: baseKey,
      identityKey: identityKey,
      message: message,
    );
  }

  /// Serializes this `PreKeySignalMessage` back to its wire-format byte
  /// layout (version byte followed directly by the protobuf body), in the
  /// same field order (1, 2, 3, 4, 5, 6) real clients use.
  Uint8List serialize() {
    final body = BytesBuilder();
    _writeTag(body, 1, 0);
    _writeVarint(body, preKeyId);
    _writeTag(body, 2, 2);
    _writeVarint(body, baseKey.length);
    body.add(baseKey);
    _writeTag(body, 3, 2);
    _writeVarint(body, identityKey.length);
    body.add(identityKey);
    _writeTag(body, 4, 2);
    _writeVarint(body, message.length);
    body.add(message);
    _writeTag(body, 5, 0);
    _writeVarint(body, registrationId);
    _writeTag(body, 6, 0);
    _writeVarint(body, signedPreKeyId);

    final out = BytesBuilder();
    out.addByte((version << 4) | version);
    out.add(body.toBytes());
    return out.toBytes();
  }
}
