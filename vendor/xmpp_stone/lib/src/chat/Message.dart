import 'package:collection/collection.dart' show IterableExtension;
import 'package:xmpp_stone/src/chat/Chat.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/stanzas/MessageStanza.dart';

import '../elements/XmppElement.dart';
import '../logger/Log.dart';

class Message {
  static String TAG = 'Message';
  MessageStanza messageStanza;
  Jid? to;
  Jid? from;
  String? text;
  DateTime time;

  //TODO: check purpose vs stanza_id
  String? _messageId;
  String? _stanzaId;
  String? _threadId;
  String? _queryId; //To be determined if needed
  String? _mamResultId;
  bool? _isDelayed;
  bool? _isForwarded;
  MessageStanzaType? _type;
  // The actual `<message/>` element this [Message] represents - either
  // [messageStanza] itself (for a plain, unwrapped stanza), or the inner
  // `<forwarded><message/></forwarded>` element when [messageStanza] is a
  // XEP-0280 carbon or XEP-0313 MAM wrapper. Used to serialize/persist
  // only the real message, not the enclosing envelope.
  XmppElement? _innerMessageElement;

  ChatState? _chatState; // optional element

  String? get messageId => _messageId;

  Message(this.messageStanza, this.to, this.from, this.text, this.time,
      {String? stanzaId = '',
      String? threadId = '',
      bool isForwarded = false,
      bool? isDelayed,
      String? queryId,
      String? messageId,
      String? mamResultId,
      MessageStanzaType? type,
      ChatState? chatState,
      XmppElement? innerMessageElement}) {
    _stanzaId = stanzaId;
    _threadId = threadId;
    _isForwarded = isForwarded;
    _isDelayed = isDelayed;
    _queryId = queryId;
    _messageId = messageId;
    _mamResultId = mamResultId;
    _type = type;
    _chatState = chatState;
    _innerMessageElement = innerMessageElement;
  }

  // The actual message stanza to serialize/persist: the inner forwarded
  // message for a carbon/MAM-wrapped [Message], or [messageStanza] itself
  // otherwise. Callers that need to drop the carbon/MAM envelope (e.g. when
  // persisting raw XML for display) should use this instead of
  // [messageStanza] directly.
  XmppElement get innerMessageStanza => _innerMessageElement ?? messageStanza;

  // Where this message came from: 'mam' when parsed out of a XEP-0313
  // `<result/>` archive wrapper, 'live' otherwise (including XEP-0280
  // carbons, which mirror a live send/receive on another resource rather
  // than an archived one).
  String get source =>
      (_mamResultId != null && _mamResultId!.isNotEmpty) ? 'mam' : 'live';

  ChatState? get chatState => _chatState;

  static Message fromStanza(MessageStanza stanza) {
    Message? message;
    var isCarbon = stanza.children.any(
        (element) => (element.name == 'sent' || element.name == 'received'));
    var isArchivedMessage =
        stanza.children.any((element) => (element.name == 'result'));
    if (isCarbon) {
      message = _parseCarbon(stanza);
    } else if (isArchivedMessage) {
      message = _parseArchived(stanza);
    }
    message ??= _parseRegularMessage(stanza);
    return message;
  }

  static Message? _parseCarbon(MessageStanza stanza) {
    var carbon = stanza.children.firstWhereOrNull(
        (element) => (element.name == 'sent' || element.name == 'received'))!;
    try {
      var forwarded = carbon.getChild('forwarded');
      if (forwarded != null) {
        var message = forwarded.getChild('message');
        if (message != null) {
          Jid? to;
          if (message.getAttribute('to') != null &&
              message.getAttribute('to')!.value != null) {
            to = Jid.fromFullJid(message.getAttribute('to')!.value!);
          }

          Jid? from;
          if (message.getAttribute('from') != null &&
              message.getAttribute('from')!.value != null) {
            from = Jid.fromFullJid(message.getAttribute('from')!.value!);
          }

          var body = message.getChild('body')?.textValue;
          var messageId = message.getAttribute('id')?.value;
          var type = (_parseType(message));
          var chatState = _parseState(message);
          var threadId = message.getChild('thread')?.textValue;
          var dateTime = _parseDelayed(forwarded);
          var delayed = dateTime != null;
          dateTime ??= DateTime.now();
          return Message(stanza, to, from, body, dateTime,
              threadId: threadId,
              isForwarded: true,
              isDelayed: delayed,
              messageId: messageId,
              chatState: chatState,
              type: type,
              innerMessageElement: message);
        }
      }
    } catch (e) {
      Log.e(TAG, 'Error while parsing message');
    }
    return null;
  }

  static Message? _parseArchived(MessageStanza stanza) {
    var result = stanza.children
        .firstWhereOrNull((element) => (element.name == 'result'));

    try {
      var queryId = result?.getAttribute('queryId')?.value;
      var mamResultId = result?.getAttribute('id')?.value;
      var forwarded = result?.getChild('forwarded');
      if (forwarded != null) {
        var message = forwarded.getChild('message');
        if (message != null) {
          Jid? to;
          if (message.getAttribute('to') != null &&
              message.getAttribute('to')!.value != null) {
            to = Jid.fromFullJid(message.getAttribute('to')!.value!);
          }

          Jid? from;
          if (message.getAttribute('from') != null &&
              message.getAttribute('from')!.value != null) {
            from = Jid.fromFullJid(message.getAttribute('from')!.value!);
          }

          var body = message.getChild('body')?.textValue;
          var messageId = message.getAttribute('id')?.value;
          var threadId = message.getChild('thread')?.textValue;
          var stanzaId =
              message.getChild('stanza-id')?.getAttribute('id')?.value;
          var type = (_parseType(message));
          var dateTime = _parseDelayed(forwarded);
          var delayed = dateTime != null;
          dateTime ??= DateTime.now();
          var chatState = _parseState(message);
          return Message(stanza, to, from, body, dateTime,
              threadId: threadId,
              isForwarded: true,
              queryId: queryId,
              isDelayed: delayed,
              messageId: messageId,
              stanzaId: stanzaId,
              mamResultId: mamResultId,
              chatState: chatState,
              type: type,
              innerMessageElement: message);
        }
      }
    } catch (e) {
      Log.e(TAG, 'Error while parsing archived message $e');
    }
    return null;
  }

  static MessageStanzaType? _parseType(XmppElement element) {
    var typeString = element.getAttribute('type');
    MessageStanzaType? type;
    if (typeString == null) {
      Log.w(TAG, 'No type found for iq stanza');
    } else {
      switch (typeString.value) {
        case 'chat':
          type = MessageStanzaType.CHAT;
          break;
        case 'error':
          type = MessageStanzaType.ERROR;
          break;
        case 'groupchat':
          type = MessageStanzaType.GROUPCHAT;
          break;
        case 'headline':
          type = MessageStanzaType.HEADLINE;
          break;
        case 'normal':
          type = MessageStanzaType.NORMAL;
          break;
      }
    }
    return type;
  }

  static ChatState? _parseState(XmppElement element) {
    var stateElement = element.children.firstWhereOrNull((element) =>
        element.getAttribute('xmlns')?.value ==
        'http://jabber.org/protocol/chatstates');
    if (stateElement != null) {
      return _stateFromString(stateElement.name);
    } else {
      return null;
    }
  }

  static ChatState _stateFromString(String? chatStateString) {
    switch (chatStateString) {
      case 'inactive':
        return ChatState.INACTIVE;
      case 'active':
        return ChatState.ACTIVE;
      case 'gone':
        return ChatState.GONE;
      case 'composing':
        return ChatState.COMPOSING;
      case 'paused':
        return ChatState.PAUSED;
    }
    return ChatState.INACTIVE;
  }

  static Message _parseRegularMessage(MessageStanza stanza) {
    return Message(
        stanza, stanza.toJid, stanza.fromJid, stanza.body, DateTime.now(),
        chatState: _parseState(stanza),
        threadId: stanza.thread,
        type: _parseType(stanza),
        messageId: stanza.id);
  }

  static DateTime? _parseDelayed(XmppElement element) {
    var delayed = element.getChild('delay');
    if (delayed != null) {
      var stamped = delayed.getAttribute('stamp')!.value!;
      try {
        var dateTime = DateTime.parse(stamped);
        return dateTime;
      } catch (e) {
        Log.e(TAG, 'Date Parsing problem');
      }
    }
    return null;
  }

  String? get stanzaId => _stanzaId;

  String? get threadId => _threadId;

  String? get queryId => _queryId;
  String? get mamResultId => _mamResultId;

  bool? get isDelayed => _isDelayed;

  bool? get isForwarded => _isForwarded;

  MessageStanzaType? get type => _type;
}
