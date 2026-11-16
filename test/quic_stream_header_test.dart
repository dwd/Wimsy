import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/quic_varint.dart';
import 'package:wimsy/xmpp/quic_xmpp_socket.dart';

void main() {
  group('buildQuicStreamHeader', () {
    test('Primary header is a single varint-encoded zero byte', () {
      final header = buildQuicStreamHeader(type: quicStreamTypePrimary);
      expect(header, Uint8List.fromList([0]));
    });

    test(
      'Ancillary header is type=1 followed by the varint-encoded session id',
      () {
        final header = buildQuicStreamHeader(
          type: quicStreamTypeAncillary,
          sessionId: quicPrimaryStreamId,
        );
        expect(header, Uint8List.fromList([1, 0]));
      },
    );

    test('Ancillary header encodes larger session ids correctly', () {
      final header = buildQuicStreamHeader(
        type: quicStreamTypeAncillary,
        sessionId: 400,
      );
      final expectedSessionBytes = encodeQuicVarint(400);
      expect(header[0], 1);
      expect(header.sublist(1), expectedSessionBytes);
    });

    test('Ancillary header defaults session id to the Primary stream id', () {
      final header = buildQuicStreamHeader(type: quicStreamTypeAncillary);
      expect(header, Uint8List.fromList([1, 0]));
    });
  });

  group('tryParseQuicStreamHeader', () {
    test('parses a Primary header and reports no session id', () {
      final buffer = Uint8List.fromList([0, 60, 109, 101, 115, 115, 97, 103]);
      final header = tryParseQuicStreamHeader(buffer);
      expect(header, isNotNull);
      expect(header!.type, quicStreamTypePrimary);
      expect(header.sessionId, isNull);
      expect(header.bytesConsumed, 1);
    });

    test('parses an Ancillary header and the session id', () {
      final headerBytes = buildQuicStreamHeader(
        type: quicStreamTypeAncillary,
        sessionId: quicPrimaryStreamId,
      );
      final buffer = Uint8List.fromList([...headerBytes, 60, 109, 115, 103]);
      final header = tryParseQuicStreamHeader(buffer);
      expect(header, isNotNull);
      expect(header!.type, quicStreamTypeAncillary);
      expect(header.sessionId, quicPrimaryStreamId);
      expect(header.bytesConsumed, headerBytes.length);
    });

    test('strips exactly the header bytes, leaving the payload intact', () {
      final headerBytes = buildQuicStreamHeader(
        type: quicStreamTypeAncillary,
        sessionId: 7,
      );
      const payload = "<stream:stream xmlns='jabber:client'>";
      final buffer = Uint8List.fromList([...headerBytes, ...payload.codeUnits]);
      final header = tryParseQuicStreamHeader(buffer)!;
      final remaining = buffer.sublist(header.bytesConsumed);
      expect(String.fromCharCodes(remaining), payload);
    });

    test('returns null when the Primary header buffer is empty', () {
      expect(tryParseQuicStreamHeader(Uint8List(0)), isNull);
    });

    test(
      'returns null when an Ancillary session-id varint is not yet complete',
      () {
        // Type byte (1) followed by the first byte of a 2-byte session id
        // varint (0x41 -> length prefix 01 => needs a second byte).
        final buffer = Uint8List.fromList([1, 0x41]);
        expect(tryParseQuicStreamHeader(buffer), isNull);
      },
    );
  });
}
