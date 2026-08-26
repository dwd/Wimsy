import 'package:xmpp_stone/xmpp_stone.dart';

const String mucDirectInviteNamespace = 'jabber:x:conference';
const String _mucUserNamespace = 'http://jabber.org/protocol/muc#user';

class MucDirectInvite {
  MucDirectInvite({required this.roomJid, this.reason, this.password});

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
  for (final container in _messageContainers(stanza)) {
    for (final child in container.children) {
      if (child.name != 'x') {
        continue;
      }
      if (child.getAttribute('xmlns')?.value != mucDirectInviteNamespace) {
        continue;
      }
      final roomJid = child.getAttribute('jid')?.value?.trim() ?? '';
      if (roomJid.isEmpty) {
        continue;
      }
      final reason = _trimmed(child.getAttribute('reason')?.value);
      final password = _trimmed(child.getAttribute('password')?.value);
      return MucDirectInvite(
        roomJid: roomJid,
        reason: reason,
        password: password,
      );
    }
  }
  return null;
}

MucMediatedInvite? parseMucMediatedInvite(MessageStanza stanza) {
  for (final container in _messageContainers(stanza)) {
    final from = container.getAttribute('from')?.value;
    final roomJid = from == null || from.isEmpty
        ? stanza.fromJid?.userAtDomain ?? ''
        : Jid.fromFullJid(from).userAtDomain;
    if (roomJid.isEmpty) {
      continue;
    }
    for (final child in container.children) {
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
  }
  return null;
}

/// Returns the outer stanza and any nested forwarded message elements.
Iterable<XmppElement> _messageContainers(XmppElement root) sync* {
  yield root;
  for (final child in root.children) {
    if (child.name == 'message') {
      yield child;
    }
    yield* _nestedMessageContainers(child);
  }
}

Iterable<XmppElement> _nestedMessageContainers(XmppElement root) sync* {
  for (final child in root.children) {
    if (child.name == 'message') {
      yield child;
    } else {
      yield* _nestedMessageContainers(child);
    }
  }
}

String? _trimmed(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
