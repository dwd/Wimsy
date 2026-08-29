import 'package:xmpp_stone/xmpp_stone.dart';

/// Normalizes a user-entered JID and returns null when it is not a full JID.
///
/// [Jid] applies the available Stringprep-compatible case mapping to the
/// localpart and domain while leaving the case-sensitive resource unchanged.
String? normalizeEnteredJid(String value, {bool bare = false}) {
  final parsed = Jid.fromFullJid(value.trim());
  if (!parsed.isValid()) {
    return null;
  }
  return bare ? parsed.userAtDomain : parsed.fullJid;
}
