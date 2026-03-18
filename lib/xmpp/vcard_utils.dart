import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

String vcardDisplayName(VCard vcard) {
  final full = vcard.fullName?.trim();
  if (full != null && full.isNotEmpty) {
    return full;
  }
  final nick = vcard.nickName?.trim();
  if (nick != null && nick.isNotEmpty) {
    return nick;
  }
  final given = vcard.givenName?.trim() ?? '';
  final family = vcard.familyName?.trim() ?? '';
  final combined = [given, family].where((part) => part.isNotEmpty).join(' ');
  if (combined.isNotEmpty) {
    return combined;
  }
  return '';
}

XmppElement buildVcardElement({
  required String displayName,
  Uint8List? avatarBytes,
  String? avatarMimeType,
}) {
  final vcard = XmppElement()..name = 'vCard';
  vcard.addAttribute(XmppAttribute('xmlns', 'vcard-temp'));
  if (displayName.trim().isNotEmpty) {
    final fn = XmppElement()..name = 'FN';
    fn.textValue = displayName.trim();
    vcard.addChild(fn);
    final nick = XmppElement()..name = 'NICKNAME';
    nick.textValue = displayName.trim();
    vcard.addChild(nick);
  }
  if (avatarBytes != null && avatarBytes.isNotEmpty) {
    final photo = XmppElement()..name = 'PHOTO';
    if (avatarMimeType != null && avatarMimeType.trim().isNotEmpty) {
      final type = XmppElement()..name = 'TYPE';
      type.textValue = avatarMimeType.trim();
      photo.addChild(type);
    }
    final binval = XmppElement()..name = 'BINVAL';
    binval.textValue = base64Encode(avatarBytes);
    photo.addChild(binval);
    vcard.addChild(photo);
  }
  return vcard;
}

Future<String> vcardPhotoHash(Uint8List bytes) async {
  final hash = await Sha1().hash(bytes);
  return _toHex(hash.bytes);
}

String normalizeVcardPhotoHash(String hash) {
  var normalized = hash.trim();
  while (normalized.length.isEven && normalized.isNotEmpty) {
    final half = normalized.length ~/ 2;
    final first = normalized.substring(0, half);
    final second = normalized.substring(half);
    if (first != second) {
      break;
    }
    normalized = first;
  }
  return normalized;
}

String _toHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
