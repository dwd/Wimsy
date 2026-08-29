import 'package:xmpp_stone/xmpp_stone.dart';

/// Chooses the nickname to use when joining a room without an explicit nick.
///
/// A profile display name is the friendliest choice. If the profile has no
/// name, the account JID's localpart is stable and recognizable to the user.
String defaultRoomNickname({
  required String accountJid,
  String? profileDisplayName,
}) {
  final profileName = profileDisplayName?.trim();
  if (profileName != null && profileName.isNotEmpty) {
    return profileName;
  }

  final localpart = Jid.fromFullJid(accountJid).local;
  return localpart.isNotEmpty ? localpart : 'wimsy';
}
