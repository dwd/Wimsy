import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/encryption/legacy_signal_wire.dart';

void main() {
  // The exact base64 content of the <key prekey="true"> element from a
  // real stanza sent by Conversations (see the "Still the same error"
  // issue report), manually decoded byte-by-byte to confirm the wire
  // layout documented at the top of legacy_signal_wire.dart before this
  // parser was written.
  const realPreKeySignalMessageBase64 =
      'Mwi5wN0eEiEFqfrJprLRYFevE/n+W2b5JYchvS2P+ZNILyRRQR4dbggaIQWiNe56vDhlk'
      '1J3vmHR2HmaAx7HFqHqSigL5ogufUyneyJiMwohBaroIcd+T1MRTZvUmlWXgAGh6vmSkm'
      'nEI2Ew/4FXjMMxEAUYACIw6QsPfdiLk+8FpCT9lIfAEwvS8KfonurY3JF8fMFS8h4pwTT'
      'cayXfMJigdTb70G4AmVXTn3yRCuso16n0ogYwxcTWlAc=';

  test(
    'PreKeySignalMessageWire.parse decodes a real captured Conversations '
    'message exactly as manually verified byte-by-byte',
    () {
      final bytes = base64Decode(realPreKeySignalMessageBase64);
      final parsed = PreKeySignalMessageWire.parse(bytes);

      expect(parsed.version, 3);
      expect(parsed.preKeyId, 64446521);
      expect(parsed.registrationId, 1683821783);
      expect(parsed.signedPreKeyId, 1922409029 & 0xffffffff);
      expect(parsed.baseKey.length, 33);
      expect(parsed.baseKey.first, 0x05);
      expect(parsed.identityKey.length, 33);
      expect(parsed.identityKey.first, 0x05);
      expect(parsed.message.length, 98);
    },
  );

  test(
    'PreKeySignalMessageWire.serialize round-trips the real captured '
    "message byte-for-byte",
    () {
      final bytes = base64Decode(realPreKeySignalMessageBase64);
      final parsed = PreKeySignalMessageWire.parse(bytes);
      expect(parsed.serialize(), bytes);
    },
  );

  test(
    'SignalMessageWire.parse decodes the nested message field of the real '
    'captured PreKeySignalMessage',
    () {
      final bytes = base64Decode(realPreKeySignalMessageBase64);
      final parsed = PreKeySignalMessageWire.parse(bytes);
      final nested = SignalMessageWire.parse(parsed.message);

      expect(nested.version, 3);
      expect(nested.ratchetKey.length, 33);
      expect(nested.ratchetKey.first, 0x05);
      expect(nested.counter, 5);
      expect(nested.previousCounter, 0);
      expect(nested.mac.length, kSignalMessageMacLength);
    },
  );

  test(
    'SignalMessageWire.serialize round-trips the nested message '
    'byte-for-byte',
    () {
      final bytes = base64Decode(realPreKeySignalMessageBase64);
      final parsed = PreKeySignalMessageWire.parse(bytes);
      final nested = SignalMessageWire.parse(parsed.message);
      expect(nested.serialize(), parsed.message);
    },
  );

  test(
    'PreKeySignalMessageWire.parse throws on an unsupported (too old) '
    'version byte',
    () {
      final bytes = base64Decode(realPreKeySignalMessageBase64);
      final tampered = List<int>.of(bytes);
      tampered[0] = 0x22; // version 2, below kLegacySignalWireVersion.
      expect(
        () => PreKeySignalMessageWire.parse(tampered),
        throwsA(isA<LegacySignalWireFormatException>()),
      );
    },
  );

  test(
    'PreKeySignalMessageWire.parse throws on truncated/empty input',
    () {
      expect(
        () => PreKeySignalMessageWire.parse(const []),
        throwsA(isA<LegacySignalWireFormatException>()),
      );
    },
  );

  test(
    'SignalMessageWire.parse throws when missing a required field',
    () {
      // A minimal protobuf body containing only field 4 (ciphertext),
      // missing the required ratchetKey (field 1) and counter (field 2).
      final body = [0x22, 0x01, 0xff]; // tag=4<<3|2, len=1, byte 0xff
      final bytes = [
        0x33,
        ...body,
        ...List<int>.filled(kSignalMessageMacLength, 0),
      ];
      expect(
        () => SignalMessageWire.parse(bytes),
        throwsA(isA<LegacySignalWireFormatException>()),
      );
    },
  );
}
