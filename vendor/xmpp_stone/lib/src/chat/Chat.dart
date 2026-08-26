import 'dart:async';

import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/chat/Message.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/stanzas/AbstractStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/MessageStanza.dart';

class ChatImpl implements Chat {
  static String TAG = 'Chat';

  final Connection _connection;
  final Jid _jid;

  @override
  Jid get jid => _jid;
  ChatState? _myState;
  @override
  ChatState? get myState => _myState;

  ChatState? _remoteState;
  @override
  ChatState? get remoteState => _remoteState;

  @override
  List<Message>? messages = [];

  final StreamController<Message> _newMessageController =
      StreamController.broadcast();
  final StreamController<ChatState?> _remoteStateController =
      StreamController.broadcast();

  @override
  Stream<Message> get newMessageStream => _newMessageController.stream;
  @override
  Stream<ChatState?> get remoteStateStream => _remoteStateController.stream;

  ChatImpl(this._jid, this._connection);

  void parseMessage(Message message) {
    if (message.type == MessageStanzaType.CHAT) {
      if (isRenderableChatMessage(message)) {
        messages!.add(message);
        _newMessageController.add(message);
      }

      if (message.chatState != null && !(message.isDelayed ?? false)) {
        _remoteState = message.chatState;
        _remoteStateController.add(message.chatState);
      }
    }
  }

  @override
  void sendMessage(String text) {
    var stanza =
        MessageStanza(AbstractStanza.getRandomId(), MessageStanzaType.CHAT);
    stanza.toJid = _jid;
    stanza.fromJid = _connection.fullJid;
    stanza.body = text;
    var receiptRequest = XmppElement();
    receiptRequest.name = 'request';
    receiptRequest.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:receipts'));
    stanza.addChild(receiptRequest);
    var markable = XmppElement();
    markable.name = 'markable';
    markable.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:chat-markers:0'));
    stanza.addChild(markable);
    var message = Message.fromStanza(stanza);
    messages!.add(message);
    _newMessageController.add(message);
    _connection.writeStanza(stanza);
  }

  @override
  set myState(ChatState? state) {
    var stanza =
        MessageStanza(AbstractStanza.getRandomId(), MessageStanzaType.CHAT);
    stanza.toJid = _jid;
    stanza.fromJid = _connection.fullJid;
    var stateElement = XmppElement();
    stateElement.name = state.toString().split('.').last.toLowerCase();
    stateElement.addAttribute(
        XmppAttribute('xmlns', 'http://jabber.org/protocol/chatstates'));
    stanza.addChild(stateElement);
    _connection.writeStanza(stanza);
    _myState = state;
  }
}

/// Whether a chat message carries visible content for the conversation.
///
/// XEP-0249 invitations commonly omit `<body>`, but still need to reach the
/// application so it can render the invitation card.
bool isRenderableChatMessage(Message message) {
  return (message.text != null && message.text!.isNotEmpty) ||
      _containsMucDirectInvite(message.messageStanza);
}

bool _containsMucDirectInvite(XmppElement element) {
  if (element.name == 'x' &&
      element.getAttribute('xmlns')?.value == 'jabber:x:conference' &&
      (element.getAttribute('jid')?.value?.isNotEmpty ?? false)) {
    return true;
  }
  return element.children.any(_containsMucDirectInvite);
}

abstract class Chat {
  Jid get jid;
  ChatState? get myState;
  ChatState? get remoteState;
  Stream<Message> get newMessageStream;
  Stream<ChatState?> get remoteStateStream;
  List<Message>? messages;
  void sendMessage(String text);
  set myState(ChatState? state);
}

enum ChatState { INACTIVE, ACTIVE, GONE, COMPOSING, PAUSED }
