import 'dart:async';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/stanzas/AbstractStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/MessageStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/PresenceStanza.dart';

class MucManager {
  static const _mucNs = 'http://jabber.org/protocol/muc';
  static const _mucUserNs = 'http://jabber.org/protocol/muc#user';

  static final Map<Connection, MucManager> _instances = {};

  static MucManager getInstance(Connection connection) {
    var instance = _instances[connection];
    if (instance == null) {
      instance = MucManager(connection);
      _instances[connection] = instance;
    }
    return instance;
  }

  final Connection _connection;

  final StreamController<MucMessage> _messageController = StreamController.broadcast();
  final StreamController<MucPresenceUpdate> _presenceController = StreamController.broadcast();
  final StreamController<MucSubjectUpdate> _subjectController = StreamController.broadcast();

  Stream<MucMessage> get roomMessageStream => _messageController.stream;
  Stream<MucPresenceUpdate> get roomPresenceStream => _presenceController.stream;
  Stream<MucSubjectUpdate> get roomSubjectStream => _subjectController.stream;

  MucManager(this._connection) {
    _connection.inStanzasStream.listen(_handleStanza);
  }

  void joinRoom(Jid roomJid, String nick, {String? password}) {
    final stanza = PresenceStanza();
    stanza.toJid = Jid.fromFullJid('${roomJid.userAtDomain}/$nick');
    final x = XmppElement()..name = 'x';
    x.addAttribute(XmppAttribute('xmlns', _mucNs));
    if (password != null && password.trim().isNotEmpty) {
      final pass = XmppElement()..name = 'password';
      pass.textValue = password;
      x.addChild(pass);
    }
    stanza.addChild(x);
    _connection.writeStanza(stanza);
  }

  void leaveRoom(Jid roomJid, String nick) {
    final stanza = PresenceStanza.withType(PresenceType.UNAVAILABLE);
    stanza.toJid = Jid.fromFullJid('${roomJid.userAtDomain}/$nick');
    _connection.writeStanza(stanza);
  }

  void sendGroupMessage(Jid roomJid, String body, {String? messageId}) {
    final stanza = MessageStanza(
      messageId ?? AbstractStanza.getRandomId(),
      MessageStanzaType.GROUPCHAT,
    );
    stanza.toJid = roomJid;
    stanza.body = body;
    _connection.writeStanza(stanza);
  }

  void _handleStanza(AbstractStanza? stanza) {
    if (stanza == null) {
      return;
    }
    if (stanza is MessageStanza) {
      final isGroupchat = stanza.type == MessageStanzaType.GROUPCHAT;
      final isMamGroupchat = _isMamGroupchatResult(stanza);
      if (isGroupchat || isMamGroupchat) {
        _handleGroupMessage(stanza);
      }
    } else if (stanza is PresenceStanza) {
      _handlePresence(stanza);
    }
  }

  void _handleGroupMessage(MessageStanza stanza) {
    final parsed = parseMucGroupMessage(stanza);
    if (parsed == null) {
      return;
    }
    if (parsed.subject != null) {
      _subjectController.add(parsed.subject!);
      return;
    }
    if (parsed.message != null) {
      _messageController.add(parsed.message!);
    }
  }

  void _handlePresence(PresenceStanza stanza) {
    final from = stanza.fromJid;
    if (from == null || from.resource == null || from.resource!.isEmpty) {
      return;
    }
    final x = stanza.children.firstWhereOrNull(
      (child) => child.name == 'x' && child.getAttribute('xmlns')?.value == _mucUserNs,
    );
    if (x == null) {
      return;
    }
    final item = x.getChild('item');
    final role = item?.getAttribute('role')?.value;
    final affiliation = item?.getAttribute('affiliation')?.value;
    final statusCodes = x.children
        .where((child) => child.name == 'status')
        .map((child) => child.getAttribute('code')?.value ?? '')
        .where((code) => code.isNotEmpty)
        .toSet();
    final isSelf = statusCodes.contains('110');
    final isUnavailable = stanza.type == PresenceType.UNAVAILABLE;
    final presence = MucPresenceUpdate(
      roomJid: from.userAtDomain,
      nick: from.resource ?? '',
      role: role,
      affiliation: affiliation,
      isSelf: isSelf,
      unavailable: isUnavailable,
    );
    _presenceController.add(presence);
  }

}

bool _isMamGroupchatResult(MessageStanza stanza) {
  final result = stanza.children.firstWhereOrNull((child) => child.name == 'result');
  final forwarded = result?.getChild('forwarded');
  final forwardedMessage = forwarded?.getChild('message');
  final type = forwardedMessage?.getAttribute('type')?.value;
  return type == 'groupchat';
}

String? _extractForwardedBody(XmppElement? message) {
  return message?.getChild('body')?.textValue;
}

String? _extractForwardedSubject(XmppElement? message) {
  return message?.getChild('subject')?.textValue;
}

String? _extractOobUrl(XmppElement? message) {
  if (message == null) {
    return null;
  }
  for (final child in message.children) {
    if (child.name != 'x' || child.getAttribute('xmlns')?.value != 'jabber:x:oob') {
      continue;
    }
    final url = child.getChild('url')?.textValue?.trim();
    if (url != null && url.isNotEmpty) {
      return url;
    }
  }
  return null;
}

String? _extractStanzaId(XmppElement? message, String roomJid) {
  if (message == null) {
    return null;
  }
  final stanzaId = message.children.firstWhereOrNull(
    (child) =>
        child.name == 'stanza-id' &&
        child.getAttribute('xmlns')?.value == 'urn:xmpp:sid:0' &&
        child.getAttribute('by')?.value == roomJid,
  )?.getAttribute('id')?.value;
  if (stanzaId != null && stanzaId.isNotEmpty) {
    return stanzaId;
  }
  final byMatch = message.children.firstWhereOrNull(
    (child) => child.name == 'stanza-id' && child.getAttribute('by')?.value == roomJid,
  )?.getAttribute('id')?.value;
  if (byMatch != null && byMatch.isNotEmpty) {
    return byMatch;
  }
  final fallback = message.getAttribute('id')?.value;
  if (fallback != null && fallback.isNotEmpty) {
    return fallback;
  }
  return null;
}

String? _extractMessageIdAttr(XmppElement? forwardedMessage, MessageStanza stanza) {
  final forwardedId = forwardedMessage?.getAttribute('id')?.value;
  if (forwardedId != null && forwardedId.isNotEmpty) {
    return forwardedId;
  }
  final stanzaId = stanza.id;
  if (stanzaId != null && stanzaId.isNotEmpty) {
    return stanzaId;
  }
  return null;
}

Jid? _parseForwardedFrom(XmppElement? message) {
  final from = message?.getAttribute('from')?.value;
  if (from == null || from.isEmpty) {
    return null;
  }
  return Jid.fromFullJid(from);
}

DateTime? _extractDelayedTimestamp(XmppElement? element) {
  final delayed = element?.getChild('delay');
  final stamp = delayed?.getAttribute('stamp')?.value;
  if (stamp == null || stamp.isEmpty) {
    return null;
  }
  try {
    return DateTime.parse(stamp);
  } catch (_) {
    return null;
  }
}

MucParsedGroupMessage? parseMucGroupMessage(MessageStanza stanza) {
  final result = stanza.children.firstWhereOrNull((child) => child.name == 'result');
  final forwarded = result?.getChild('forwarded');
  final forwardedMessage = forwarded?.getChild('message');
  final from = _parseForwardedFrom(forwardedMessage) ?? stanza.fromJid;
  if (from == null) {
    return null;
  }
  final roomJid = from.userAtDomain;
  final nick = from.resource;
  final body = _extractForwardedBody(forwardedMessage) ?? stanza.body ?? '';
  final oobUrl = _extractOobUrl(forwardedMessage) ?? _extractOobUrl(stanza);
  final subject = _extractForwardedSubject(forwardedMessage) ?? stanza.subject;
  if (subject != null && subject.isNotEmpty && body.trim().isEmpty) {
    return MucParsedGroupMessage.subject(
      MucSubjectUpdate(roomJid: roomJid, subject: subject),
    );
  }
  if (body.trim().isEmpty && (oobUrl == null || oobUrl.isEmpty)) {
    return null;
  }
  final timestamp = _extractDelayedTimestamp(forwarded) ??
      _extractDelayedTimestamp(forwardedMessage) ??
      _extractDelayedTimestamp(stanza) ??
      DateTime.now();
  final mamResultId = result?.getAttribute('id')?.value;
  final forwardedStanzaId = _extractStanzaId(forwardedMessage, roomJid);
  final directStanzaId = _extractStanzaId(stanza, roomJid);
  final messageIdAttr = _extractMessageIdAttr(forwardedMessage, stanza);
  return MucParsedGroupMessage.message(
    MucMessage(
      roomJid: roomJid,
      nick: nick ?? '',
      body: body,
      oobUrl: oobUrl,
      rawXml: stanza.buildXmlString(),
      mamResultId: mamResultId,
      messageId: messageIdAttr,
      stanzaId: forwardedStanzaId ?? directStanzaId ?? stanza.id,
      timestamp: timestamp,
    ),
  );
}

class MucParsedGroupMessage {
  const MucParsedGroupMessage.message(this.message) : subject = null;
  const MucParsedGroupMessage.subject(this.subject) : message = null;

  final MucMessage? message;
  final MucSubjectUpdate? subject;
}

class MucMessage {
  MucMessage({
    required this.roomJid,
    required this.nick,
    required this.body,
    required this.timestamp,
    this.mamResultId,
    this.messageId,
    this.stanzaId,
    this.oobUrl,
    this.rawXml,
  });

  final String roomJid;
  final String nick;
  final String body;
  final DateTime timestamp;
  final String? mamResultId;
  final String? messageId;
  final String? stanzaId;
  final String? oobUrl;
  final String? rawXml;
}

class MucPresenceUpdate {
  MucPresenceUpdate({
    required this.roomJid,
    required this.nick,
    this.role,
    this.affiliation,
    required this.isSelf,
    required this.unavailable,
  });

  final String roomJid;
  final String nick;
  final String? role;
  final String? affiliation;
  final bool isSelf;
  final bool unavailable;
}

class MucSubjectUpdate {
  MucSubjectUpdate({required this.roomJid, required this.subject});

  final String roomJid;
  final String subject;
}

extension MucModuleGetter on Connection {
  MucManager getMucModule() {
    return MucManager.getInstance(this);
  }
}
