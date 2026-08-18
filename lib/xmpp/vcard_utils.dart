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

/// Sentinel value stored in the vCard avatar state map to mark a JID as
/// having no avatar. Persisted to disk via `StorageService` so we don't keep
/// re-fetching across restarts.
const String vcardNoAvatarSentinel = 'none';

/// Decide whether we should send an `<iq><vCard/></iq>` to [bareJid] given
/// what we already have cached.
///
/// The vCard avatar bytes for [bareJid] live in [cachedAvatarBytes] (keyed by
/// bare JID) and the SHA-1 photo hash in [cachedAvatarState]. The state value
/// may be:
///
/// * empty / missing — we have never received any state for this JID,
/// * [vcardNoAvatarSentinel] — we know the JID has no avatar,
/// * any other string — the SHA-1 hash advertised in the most recent
///   `vcard-temp:x:update` presence we saw.
///
/// When [preferName] is true the caller specifically wants the FN/NICKNAME
/// fields (not just the avatar), so we always fetch.
///
/// Otherwise we only fetch when the cache cannot satisfy a presence-driven
/// avatar refresh, i.e. when we are missing bytes for the advertised hash, or
/// when we have no recorded state at all.
bool shouldFetchVcardForCache({
  required String bareJid,
  required bool preferName,
  required Map<String, Object?> cachedAvatarBytes,
  required Map<String, String> cachedAvatarState,
  String? advertisedHash,
}) {
  if (preferName) {
    return true;
  }
  final state = cachedAvatarState[bareJid] ?? '';
  // No state at all — never seen this JID. Need to fetch.
  if (state.isEmpty) {
    return true;
  }
  // We've previously confirmed there is no avatar for this JID. The sentinel
  // is sticky until presence advertises a non-empty hash.
  if (state == vcardNoAvatarSentinel) {
    if (advertisedHash != null && advertisedHash.isNotEmpty) {
      return true;
    }
    return false;
  }
  // We have a recorded hash. If presence advertises a different hash we need
  // to refetch the bytes.
  if (advertisedHash != null &&
      advertisedHash.isNotEmpty &&
      advertisedHash != state) {
    return true;
  }
  // Same hash (or no presence-advertised hash to compare against): only skip
  // when we still have the bytes cached. Missing bytes implies a previous
  // partial fetch we should retry.
  if (!cachedAvatarBytes.containsKey(bareJid)) {
    return true;
  }
  return false;
}

/// Computes the JID to use for fetching/displaying a room occupant's avatar
/// via vCard, given the occupant's [nick] (as reported by
/// `ChatMessage.from` for messages received in a MUC room).
///
/// Room messages store only the occupant's nick, not a full JID. To fetch
/// the occupant's vCard avatar we need the occupant's *full* JID
/// (`room@conference/nick`), since anonymous/semi-anonymous MUCs hide the
/// occupant's real bare JID and vCard avatar lookups for occupants only work
/// against the full occupant JID (see `shouldFetchVcardForCache` above and
/// `XmppService.avatarBytesFor`'s full-JID handling).
///
/// Returns `null` for outgoing messages (no need to fetch our own avatar via
/// the occupant JID) or when [nick] is empty.
String? roomOccupantAvatarJid({
  required String roomJid,
  required String nick,
  required bool outgoing,
}) {
  if (outgoing || nick.isEmpty) {
    return null;
  }
  return '$roomJid/$nick';
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
