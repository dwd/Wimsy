import 'package:xmpp_stone/xmpp_stone.dart';

const String mucDirectInviteNamespace = 'jabber:x:conference';
const String _mucUserNamespace = 'http://jabber.org/protocol/muc#user';
const String _fallbackNamespace = 'urn:xmpp:fallback:0';

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

MessageStanza buildMucDirectInviteStanza({
  required String id,
  required String inviteeJid,
  required String roomJid,
  String? reason,
  String? password,
}) {
  final stanza = MessageStanza(id, MessageStanzaType.NORMAL)
    ..toJid = Jid.fromFullJid(inviteeJid);
  final fallbackBody = 'You have been invited to $roomJid.';
  stanza.body = fallbackBody;

  final direct = XmppElement()..name = 'x';
  direct.addAttribute(XmppAttribute('xmlns', mucDirectInviteNamespace));
  direct.addAttribute(XmppAttribute('jid', roomJid));
  final trimmedReason = _trimmed(reason);
  if (trimmedReason != null) {
    direct.addAttribute(XmppAttribute('reason', trimmedReason));
  }
  final trimmedPassword = _trimmed(password);
  if (trimmedPassword != null) {
    direct.addAttribute(XmppAttribute('password', trimmedPassword));
  }
  stanza.addChild(direct);

  // XEP-0428 lets invitation-aware clients replace the plain-text body with
  // richer UI while clients without XEP-0249 support still show useful text.
  final fallback = XmppElement()..name = 'fallback';
  fallback.addAttribute(XmppAttribute('xmlns', _fallbackNamespace));
  fallback.addAttribute(XmppAttribute('for', mucDirectInviteNamespace));
  final bodyRange = XmppElement()..name = 'body';
  bodyRange.addAttribute(XmppAttribute('start', '0'));
  bodyRange.addAttribute(
    XmppAttribute('end', fallbackBody.runes.length.toString()),
  );
  fallback.addChild(bodyRange);
  stanza.addChild(fallback);
  return stanza;
}

/// Removes the plain-text XEP-0428 fallback when an invitation card is shown.
String stripMucDirectInviteFallback(MessageStanza stanza, String body) {
  for (final container in _messageContainers(stanza)) {
    final hasInvite = container.children.any(
      (child) =>
          child.name == 'x' &&
          child.getAttribute('xmlns')?.value == mucDirectInviteNamespace,
    );
    if (!hasInvite) {
      continue;
    }
    for (final child in container.children) {
      if (child.name != 'fallback' ||
          child.getAttribute('xmlns')?.value != _fallbackNamespace ||
          child.getAttribute('for')?.value != mucDirectInviteNamespace) {
        continue;
      }
      final range = child.getChild('body');
      final start = int.tryParse(range?.getAttribute('start')?.value ?? '');
      final end = int.tryParse(range?.getAttribute('end')?.value ?? '');
      final runes = body.runes.toList();
      if (start == null ||
          end == null ||
          start < 0 ||
          end < start ||
          end > runes.length) {
        continue;
      }
      return String.fromCharCodes([...runes.take(start), ...runes.skip(end)]);
    }
  }
  return body;
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
