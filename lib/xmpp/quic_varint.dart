import 'dart:typed_data';

/// QUIC variable-length integer (varint) encode/decode helpers, per
/// RFC 9000 §16 ("Variable-Length Integer Encoding").
///
/// The two most-significant bits of the first byte indicate how many bytes
/// the encoded integer occupies:
///   00 -> 1 byte  (6 usable bits,  0 ..          2^6-1)
///   01 -> 2 bytes (14 usable bits, 0 ..         2^14-1)
///   10 -> 4 bytes (30 usable bits, 0 ..         2^30-1)
///   11 -> 8 bytes (62 usable bits, 0 ..         2^62-1)
///
/// These helpers back the "QUIC stream header" introduced by the
/// xmpp-quic-redux protoXEP, which prefixes every QUIC stream with a
/// varint-encoded stream-type octet (and, for Ancillary streams, a
/// varint-encoded Session ID).

/// Maximum value representable by a QUIC varint (2^62 - 1).
///
/// Written as a shift-and-mask expression rather than the single integer
/// literal `0x3FFFFFFFFFFFFFFF`, because that literal cannot be represented
/// exactly as a JavaScript (IEEE 754 double) number, which breaks `dart2js`/
/// `dart2wasm` web compilation (`can't be represented exactly in
/// JavaScript`). The computed value is identical on the Dart VM (64-bit
/// native ints); on web, Dart ints above 2^53 - 1 already lose precision at
/// the runtime-number level, which is a pre-existing platform limitation of
/// compiling to JavaScript, not something this expression introduces.
const int quicVarintMax = (0x3FFFFFFF << 32) | 0xFFFFFFFF;

/// Encodes [value] as a QUIC variable-length integer.
///
/// Throws [ArgumentError] if [value] is negative or exceeds [quicVarintMax].
Uint8List encodeQuicVarint(int value) {
  if (value < 0) {
    throw ArgumentError.value(
      value,
      'value',
      'QUIC varints cannot encode negative values',
    );
  }
  if (value <= 0x3F) {
    return Uint8List.fromList(<int>[value]);
  } else if (value <= 0x3FFF) {
    final encoded = value | 0x4000;
    return Uint8List.fromList(<int>[
      (encoded >> 8) & 0xFF,
      encoded & 0xFF,
    ]);
  } else if (value <= 0x3FFFFFFF) {
    final encoded = value | 0x80000000;
    return Uint8List.fromList(<int>[
      (encoded >> 24) & 0xFF,
      (encoded >> 16) & 0xFF,
      (encoded >> 8) & 0xFF,
      encoded & 0xFF,
    ]);
  } else if (value <= quicVarintMax) {
    final high = ((value >> 32) & 0x3FFFFFFF) | 0xC0000000;
    final low = value & 0xFFFFFFFF;
    return Uint8List.fromList(<int>[
      (high >> 24) & 0xFF,
      (high >> 16) & 0xFF,
      (high >> 8) & 0xFF,
      high & 0xFF,
      (low >> 24) & 0xFF,
      (low >> 16) & 0xFF,
      (low >> 8) & 0xFF,
      low & 0xFF,
    ]);
  }
  throw ArgumentError.value(
    value,
    'value',
    'Exceeds the QUIC varint maximum of $quicVarintMax',
  );
}

/// Attempts to decode a QUIC varint from [bytes] starting at [offset].
///
/// Returns a record of `(value, bytesConsumed)` on success, or `null` if
/// [bytes] does not yet contain enough data (starting at [offset]) to decode
/// a complete varint — callers reading from a stream should treat `null` as
/// "wait for more bytes" rather than an error.
(int, int)? decodeQuicVarint(Uint8List bytes, [int offset = 0]) {
  if (offset < 0 || offset >= bytes.length) {
    return null;
  }
  final firstByte = bytes[offset];
  final length = 1 << ((firstByte & 0xC0) >> 6);
  if (offset + length > bytes.length) {
    return null;
  }
  var value = firstByte & 0x3F;
  for (var i = 1; i < length; i++) {
    value = (value << 8) | bytes[offset + i];
  }
  return (value, length);
}
