import 'dart:async';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/stanzas/AbstractStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/MessageStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/PresenceStanza.dart';

/// Emitted when a MUC join attempt is rejected by the server with a
/// presence stanza of type="error". The [roomJid] is the bare JID of the
/// room and [errorCondition] is the XMPP error condition element name
/// (e.g. "registration-required", "forbidden", "not-allowed").
class MucJoinError {
  MucJoinError({required this.roomJid, required this.errorCondition});

  final String roomJid;
  final String errorCondition;
}

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

  final StreamController<MucMessage> _messageController =
      StreamController.broadcast();
  final StreamController<MucPresenceUpdate> _presenceController =
      StreamController.broadcast();
  final StreamController<MucSubjectUpdate> _subjectController =
      StreamController.broadcast();
  final StreamController<MucJoinError> _joinErrorController =
      StreamController.broadcast();

  Stream<MucMessage> get roomMessageStream => _messageController.stream;
  Stream<MucPresenceUpdate> get roomPresenceStream =>
      _presenceController.stream;
  Stream<MucSubjectUpdate> get roomSubjectStream => _subjectController.stream;
  /// Emits an event when the server rejects a room join with an error presence.
  Stream<MucJoinError> get roomJoinErrorStream => _joinErrorController.stream;

  MucManager(this._connection) {
    _connection.inStanzasStream.listen(_handleStanza);
  }

  void joinRoom(
    Jid roomJid,
    String nick, {
    String? password,
    bool suppressHistory = false,
  }) {
    final stanza = PresenceStanza();
    stanza.toJid = Jid.fromFullJid('${roomJid.userAtDomain}/$nick');
    final x = XmppElement()..name = 'x';
    x.addAttribute(XmppAttribute('xmlns', _mucNs));
    if (password != null && password.trim().isNotEmpty) {
      final pass = XmppElement()..name = 'password';
      pass.textValue = password;
      x.addChild(pass);
    }
    if (suppressHistory) {
      // Request no server-side history on join; we rely on MAM for catch-up.
      final history = XmppElement()..name = 'history';
      history.addAttribute(XmppAttribute('maxchars', '0'));
      x.addChild(history);
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
    if (from == null) {
      return;
    }
    // A join-rejected error presence has type="error" and the from JID has no
    // resource (just the room bare JID). Detect it early and emit on the error
    // stream so callers can disable autojoin and surface the error to the user.
    if (stanza.type == PresenceType.ERROR) {
      final roomJid = from.userAtDomain;
      if (roomJid.isNotEmpty) {
        final condition = _extractErrorCondition(stanza);
        _joinErrorController.add(
          MucJoinError(roomJid: roomJid, errorCondition: condition),
        );
      }
      return;
    }
    if (from.resource == null || from.resource!.isEmpty) {
      return;
    }
    final x = stanza.children.firstWhereOrNull(
      (child) =>
          child.name == 'x' && child.getAttribute('xmlns')?.value == _mucUserNs,
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
      statusCodes: statusCodes,
    );
    _presenceController.add(presence);
  }

  /// Extracts the XMPP error condition element name from a presence error
  /// stanza (e.g. "registration-required", "forbidden", "not-allowed").
  String _extractErrorCondition(PresenceStanza stanza) {
    const xmppStanzasNs = 'urn:ietf:params:xml:ns:xmpp-stanzas';
    final error = stanza.getChild('error');
    if (error == null) {
      return '';
    }
    for (final child in error.children) {
      final xmlns = child.getAttribute('xmlns')?.value;
      if (xmlns == xmppStanzasNs && child.name != 'text') {
        return child.name ?? '';
      }
    }
    return '';
  }
}

const _replyNs = 'urn:xmpp:reply:0';
const _featureFallbackNs = 'urn:xmpp:feature-fallback:0';
const _legacyFallbackNs = 'urn:xmpp:fallback:0';

bool _isMamGroupchatResult(MessageStanza stanza) {
  final result =
      stanza.children.firstWhereOrNull((child) => child.name == 'result');
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
    if (child.name != 'x' ||
        child.getAttribute('xmlns')?.value != 'jabber:x:oob') {
      continue;
    }
    final url = child.getChild('url')?.textValue?.trim();
    if (url != null && url.isNotEmpty) {
      return url;
    }
  }
  return null;
}

_ReactionInfo? _extractReactions(XmppElement? message) {
  if (message == null) {
    return null;
  }
  for (final child in message.children) {
    if (child.name != 'reactions' ||
        child.getAttribute('xmlns')?.value != 'urn:xmpp:reactions:0') {
      continue;
    }
    final targetId = child.getAttribute('id')?.value;
    if (targetId == null || targetId.isEmpty) {
      return null;
    }
    final reactions = child.children
        .where((reaction) => reaction.name == 'reaction')
        .map((reaction) => reaction.textValue?.trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toList();
    return _ReactionInfo(targetId, reactions);
  }
  return null;
}

/// Extracts the XEP-0359 stanza-id applied by the MUC room with JID
/// [roomJid] from the given [message] element. Returns null if no
/// room-applied stanza-id element is present. Does NOT fall back to the
/// stanza's own id attribute — callers that need such a fallback must
/// handle it explicitly.
String? _extractStanzaId(XmppElement? message, String roomJid) {
  if (message == null) {
    return null;
  }
  final stanzaId = message.children
      .firstWhereOrNull(
        (child) =>
            child.name == 'stanza-id' &&
            child.getAttribute('xmlns')?.value == 'urn:xmpp:sid:0' &&
            child.getAttribute('by')?.value == roomJid,
      )
      ?.getAttribute('id')
      ?.value;
  if (stanzaId != null && stanzaId.isNotEmpty) {
    return stanzaId;
  }
  final byMatch = message.children
      .firstWhereOrNull(
        (child) =>
            child.name == 'stanza-id' &&
            child.getAttribute('by')?.value == roomJid,
      )
      ?.getAttribute('id')
      ?.value;
  if (byMatch != null && byMatch.isNotEmpty) {
    return byMatch;
  }
  return null;
}

String? _extractMessageIdAttr(
    XmppElement? forwardedMessage, MessageStanza stanza) {
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

String? _extractReplaceId(XmppElement? element) {
  final replace = element?.children.firstWhereOrNull(
    (child) =>
        child.name == 'replace' &&
        child.getAttribute('xmlns')?.value == 'urn:xmpp:message-correct:0',
  );
  final id = replace?.getAttribute('id')?.value;
  if (id == null || id.isEmpty) {
    return null;
  }
  return id;
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
  final result =
      stanza.children.firstWhereOrNull((child) => child.name == 'result');
  final forwarded = result?.getChild('forwarded');
  final forwardedMessage = forwarded?.getChild('message');
  final from = _parseForwardedFrom(forwardedMessage) ?? stanza.fromJid;
  if (from == null) {
    return null;
  }
  final roomJid = from.userAtDomain;
  final nick = from.resource;
  final rawBody = _extractForwardedBody(forwardedMessage) ?? stanza.body ?? '';
  final replyInfo =
      _extractReplyInfo(forwardedMessage) ?? _extractReplyInfo(stanza);
  final fallbackRange = _extractReplyFallbackRange(forwardedMessage) ??
      _extractReplyFallbackRange(stanza);
  final fallbackBody = (replyInfo != null &&
          fallbackRange != null &&
          fallbackRange.end > fallbackRange.start)
      ? _substringByRunes(rawBody, fallbackRange.start, fallbackRange.end)
          ?.trimRight()
      : null;
  final body = (replyInfo != null &&
          fallbackRange != null &&
          fallbackRange.end > fallbackRange.start)
      ? _removeRuneRange(rawBody, fallbackRange.start, fallbackRange.end)
      : rawBody;
  final oobUrl = _extractOobUrl(forwardedMessage) ?? _extractOobUrl(stanza);
  final reactionsInfo =
      _extractReactions(forwardedMessage) ?? _extractReactions(stanza);
  final subject = _extractForwardedSubject(forwardedMessage) ?? stanza.subject;
  if (subject != null && subject.isNotEmpty && body.trim().isEmpty) {
    return MucParsedGroupMessage.subject(
      MucSubjectUpdate(roomJid: roomJid, subject: subject),
    );
  }
  if (body.trim().isEmpty &&
      (oobUrl == null || oobUrl.isEmpty) &&
      reactionsInfo == null) {
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
  final replaceId =
      _extractReplaceId(forwardedMessage) ?? _extractReplaceId(stanza);
  return MucParsedGroupMessage.message(
    MucMessage(
      roomJid: roomJid,
      nick: nick ?? '',
      body: body,
      oobUrl: oobUrl,
      rawXml: stanza.buildXmlString(),
      replaceId: replaceId,
      reactionTargetId: reactionsInfo?.targetId,
      reactions: reactionsInfo?.reactions ?? const [],
      replyToId: replyInfo?.id,
      replyToJid: replyInfo?.toJid,
      replyFallback:
          (fallbackBody == null || fallbackBody.isEmpty) ? null : fallbackBody,
      mamResultId: mamResultId,
      messageId: messageIdAttr,
      stanzaId: forwardedStanzaId ?? directStanzaId,
      timestamp: timestamp,
    ),
  );
}

class _ReactionInfo {
  const _ReactionInfo(this.targetId, this.reactions);

  final String targetId;
  final List<String> reactions;
}

class _ReplyInfo {
  const _ReplyInfo({required this.id, this.toJid});

  final String id;
  final String? toJid;
}

class _FallbackRange {
  const _FallbackRange(this.start, this.end);

  final int start;
  final int end;
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
    this.replaceId,
    this.reactionTargetId,
    this.reactions = const [],
    this.replyToId,
    this.replyToJid,
    this.replyFallback,
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
  final String? replaceId;
  final String? reactionTargetId;
  final List<String> reactions;
  final String? replyToId;
  final String? replyToJid;
  final String? replyFallback;
}

_ReplyInfo? _extractReplyInfo(XmppElement? message) {
  if (message == null) {
    return null;
  }
  final reply = message.children.firstWhereOrNull(
    (child) =>
        child.name == 'reply' && child.getAttribute('xmlns')?.value == _replyNs,
  );
  final id = reply?.getAttribute('id')?.value?.trim() ?? '';
  if (id.isEmpty) {
    return null;
  }
  final toJid = reply?.getAttribute('to')?.value?.trim();
  return _ReplyInfo(
      id: id, toJid: (toJid == null || toJid.isEmpty) ? null : toJid);
}

_FallbackRange? _extractReplyFallbackRange(XmppElement? message) {
  if (message == null) {
    return null;
  }
  for (final child in message.children) {
    if (child.name != 'fallback') {
      continue;
    }
    final xmlns = child.getAttribute('xmlns')?.value;
    if (xmlns != _featureFallbackNs && xmlns != _legacyFallbackNs) {
      continue;
    }
    final forNamespace = child.getAttribute('for')?.value?.trim();
    if (forNamespace != null &&
        forNamespace.isNotEmpty &&
        forNamespace != _replyNs) {
      continue;
    }
    final body = child.getChild('body');
    if (body == null) {
      continue;
    }
    final start = int.tryParse(body.getAttribute('start')?.value ?? '0') ?? 0;
    final end = int.tryParse(body.getAttribute('end')?.value ?? '') ?? start;
    if (start < 0 || end < start) {
      continue;
    }
    return _FallbackRange(start, end);
  }
  return null;
}

String? _substringByRunes(String input, int start, int end) {
  final runes = input.runes.toList();
  if (start < 0 || start > runes.length || end < start) {
    return null;
  }
  final safeEnd = end > runes.length ? runes.length : end;
  return String.fromCharCodes(runes.sublist(start, safeEnd));
}

String _removeRuneRange(String input, int start, int end) {
  final runes = input.runes.toList();
  if (start < 0 || start > runes.length || end < start) {
    return input;
  }
  final safeEnd = end > runes.length ? runes.length : end;
  if (safeEnd <= start) {
    return input;
  }
  final before = runes.sublist(0, start);
  final after = runes.sublist(safeEnd);
  return String.fromCharCodes(before.followedBy(after));
}

class MucPresenceUpdate {
  MucPresenceUpdate({
    required this.roomJid,
    required this.nick,
    this.role,
    this.affiliation,
    required this.isSelf,
    required this.unavailable,
    required this.statusCodes,
  });

  final String roomJid;
  final String nick;
  final String? role;
  final String? affiliation;
  final bool isSelf;
  final bool unavailable;
  final Set<String> statusCodes;
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
