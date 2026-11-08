import 'package:omemo_dart/omemo_dart.dart';
import 'package:test/test.dart';

void main() {
  test(
    'generateRandom32BitNumber only produces ids parseable as a signed '
    '32-bit integer',
    () {
      // Regression test: device/signed-prekey/one-time-prekey ids are
      // serialized as plain XML integer attributes (sid, rid,
      // signedPreKeyId, preKeyId, ...). Several real-world OMEMO
      // implementations (e.g. Dino's xmpp-vala) parse these as a *signed*
      // 32-bit integer, so generating a value in the full unsigned 32-bit
      // range (0 to 2**32 - 1) has roughly a 50% chance of producing an id
      // such clients cannot parse, breaking interoperability with them
      // (observed as Dino logging "Can't parse OMEMO node: No sid").
      for (var i = 0; i < 1000; i++) {
        final id = generateRandom32BitNumber();
        expect(id, greaterThanOrEqualTo(0));
        expect(id, lessThanOrEqualTo(2147483647));
      }
    },
  );
}
