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
    if (stanza is MessageStanza && stanza.type == MessageStanzaType.GROUPCHAT) {
      _handleGroupMessage(stanza);
    } else if (stanza is PresenceStanza) {
      _handlePresence(stanza);
    }
  }

  void _handleGroupMessage(MessageStanza stanza) {
    final result = stanza.children.firstWhereOrNull((child) => child.name == 'result');
    final forwarded = result?.getChild('forwarded');
    final forwardedMessage = forwarded?.getChild('message');
    final from = _parseForwardedFrom(forwardedMessage) ?? stanza.fromJid;
    if (from == null) {
      return;
    }
    final roomJid = from.userAtDomain;
    final nick = from.resource;
    final body = _extractForwardedBody(forwardedMessage) ?? stanza.body ?? '';
    final subject = _extractForwardedSubject(forwardedMessage) ?? stanza.subject;
    if (subject != null && subject.isNotEmpty && body.trim().isEmpty) {
      _subjectController.add(MucSubjectUpdate(roomJid: roomJid, subject: subject));
      return;
    }
    if (body.trim().isEmpty) {
      return;
    }
    final timestamp = _extractDelayedTimestamp(forwarded) ??
        _extractDelayedTimestamp(forwardedMessage) ??
        _extractDelayedTimestamp(stanza) ??
        DateTime.now();
    _messageController.add(MucMessage(
      roomJid: roomJid,
      nick: nick ?? '',
      body: body,
      stanzaId: stanza.id,
      timestamp: timestamp,
    ));
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

  String? _extractForwardedBody(XmppElement? message) {
    return message?.getChild('body')?.textValue;
  }

  String? _extractForwardedSubject(XmppElement? message) {
    return message?.getChild('subject')?.textValue;
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
}

class MucMessage {
  MucMessage({
    required this.roomJid,
    required this.nick,
    required this.body,
    required this.timestamp,
    this.stanzaId,
  });

  final String roomJid;
  final String nick;
  final String body;
  final DateTime timestamp;
  final String? stanzaId;
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
