import 'package:xmpp_stone/xmpp_stone.dart';

const String mucDirectInviteNamespace = 'jabber:x:conference';
const String _mucUserNamespace = 'http://jabber.org/protocol/muc#user';

class MucDirectInvite {
  MucDirectInvite({
    required this.roomJid,
    this.reason,
    this.password,
  });

  final String roomJid;
  final String? reason;
  final String? password;
}

class MucMediatedInvite {
  MucMediatedInvite({
    required this.roomJid,
    this.inviterJid,
    this.reason,
    this.password,
  });

  final String roomJid;
  final String? inviterJid;
  final String? reason;
  final String? password;
}

MucDirectInvite? parseMucDirectInvite(MessageStanza stanza) {
  for (final child in stanza.children) {
    if (child.name != 'x') {
      continue;
    }
    if (child.getAttribute('xmlns')?.value != mucDirectInviteNamespace) {
      continue;
    }
    final roomJid = child.getAttribute('jid')?.value?.trim() ?? '';
    if (roomJid.isEmpty) {
      return null;
    }
    final reason = _trimmed(child.getAttribute('reason')?.value);
    final password = _trimmed(child.getAttribute('password')?.value);
    return MucDirectInvite(
      roomJid: roomJid,
      reason: reason,
      password: password,
    );
  }
  return null;
}

MucMediatedInvite? parseMucMediatedInvite(MessageStanza stanza) {
  final roomJid = stanza.fromJid?.userAtDomain ?? '';
  if (roomJid.isEmpty) {
    return null;
  }
  for (final child in stanza.children) {
    if (child.name != 'x') {
      continue;
    }
    if (child.getAttribute('xmlns')?.value != _mucUserNamespace) {
      continue;
    }
    final invite = child.getChild('invite');
    if (invite == null) {
      continue;
    }
    final inviter = _trimmed(invite.getAttribute('from')?.value);
    final reason = _trimmed(invite.getChild('reason')?.textValue);
    final password = _trimmed(child.getChild('password')?.textValue);
    return MucMediatedInvite(
      roomJid: roomJid,
      inviterJid: inviter,
      reason: reason,
      password: password,
    );
  }
  return null;
}

String? _trimmed(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
