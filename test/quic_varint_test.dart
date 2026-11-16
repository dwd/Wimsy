import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/quic_varint.dart';

void main() {
  group('encodeQuicVarint / decodeQuicVarint round-trip', () {
    for (final value in [
      0,
      1,
      37,
      0x3F, // largest 1-byte value
      0x40, // smallest 2-byte value
      300,
      0x3FFF, // largest 2-byte value
      0x4000, // smallest 4-byte value
      100000,
      0x3FFFFFFF, // largest 4-byte value
      0x40000000, // smallest 8-byte value
      5000000000,
      quicVarintMax, // largest 8-byte value
    ]) {
      test('round-trips $value', () {
        final encoded = encodeQuicVarint(value);
        final decoded = decodeQuicVarint(encoded);
        expect(decoded, isNotNull);
        expect(decoded!.$1, value);
        expect(decoded.$2, encoded.length);
      });
    }

    test('uses the correct encoded length for each size class', () {
      expect(encodeQuicVarint(0x3F).length, 1);
      expect(encodeQuicVarint(0x40).length, 2);
      expect(encodeQuicVarint(0x3FFF).length, 2);
      expect(encodeQuicVarint(0x4000).length, 4);
      expect(encodeQuicVarint(0x3FFFFFFF).length, 4);
      expect(encodeQuicVarint(0x40000000).length, 8);
    });

    test('rejects negative values', () {
      expect(() => encodeQuicVarint(-1), throwsArgumentError);
    });

    test('rejects values exceeding the varint maximum', () {
      expect(() => encodeQuicVarint(quicVarintMax + 1), throwsArgumentError);
    });
  });

  group('decodeQuicVarint partial-buffer handling', () {
    test('returns null for an empty buffer', () {
      expect(decodeQuicVarint(Uint8List(0)), isNull);
    });

    test('returns null when a 2-byte varint is split mid-stream', () {
      final encoded = encodeQuicVarint(0x1234);
      expect(encoded.length, 2);
      final partial = encoded.sublist(0, 1);
      expect(decodeQuicVarint(partial), isNull);
    });

    test('returns null when an 8-byte varint is split mid-stream', () {
      final encoded = encodeQuicVarint(quicVarintMax);
      expect(encoded.length, 8);
      for (var i = 1; i < encoded.length; i++) {
        expect(decodeQuicVarint(encoded.sublist(0, i)), isNull);
      }
      expect(decodeQuicVarint(encoded), isNotNull);
    });

    test('decodes starting at a non-zero offset', () {
      final prefix = Uint8List.fromList([0xAA, 0xBB]);
      final encodedValue = encodeQuicVarint(42);
      final buffer = Uint8List(prefix.length + encodedValue.length)
        ..setRange(0, prefix.length, prefix)
        ..setRange(prefix.length, prefix.length + encodedValue.length, encodedValue);
      final decoded = decodeQuicVarint(buffer, prefix.length);
      expect(decoded, isNotNull);
      expect(decoded!.$1, 42);
      expect(decoded.$2, encodedValue.length);
    });
  });
}
