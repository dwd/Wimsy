import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/vcard_utils.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('vcardDisplayName prefers full name', () {
    final vcard = VCard(null);
    final fn = XmppElement()..name = 'FN';
    fn.textValue = 'Alice Example';
    vcard.addChild(fn);
    expect(vcardDisplayName(vcard), 'Alice Example');
  });

  test('buildVcardElement includes photo when provided', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final vcard = buildVcardElement(
      displayName: 'Bob',
      avatarBytes: bytes,
      avatarMimeType: 'image/png',
    );
    expect(vcard.getAttribute('xmlns')?.value, 'vcard-temp');
    final photo = vcard.getChild('PHOTO');
    expect(photo, isNotNull);
    expect(photo!.getChild('TYPE')?.textValue, 'image/png');
    expect(photo.getChild('BINVAL')?.textValue, isNotEmpty);
  });

  test('vcardPhotoHash returns sha1 hex', () async {
    final hash = await vcardPhotoHash(Uint8List.fromList([1, 2, 3]));
    expect(hash.length, 40);
  });

  test('normalizeVcardPhotoHash keeps non-duplicated hash unchanged', () {
    const hash = 'a6626f8138cf2b82d2e8c3f3e28090a03d54aee2';
    expect(normalizeVcardPhotoHash(hash), hash);
  });

  test('normalizeVcardPhotoHash removes duplicated halves', () {
    const single = 'a6626f8138cf2b82d2e8c3f3e28090a03d54aee2';
    const doubled =
        'a6626f8138cf2b82d2e8c3f3e28090a03d54aee2a6626f8138cf2b82d2e8c3f3e28090a03d54aee2';
    expect(normalizeVcardPhotoHash(doubled), single);
  });
}
