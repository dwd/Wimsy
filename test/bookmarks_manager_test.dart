import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/bookmarks/bookmarks_manager.dart';
import 'package:wimsy/models/contact_entry.dart';

class TestConnection extends Connection {
  TestConnection(super.account);

  final List<AbstractStanza> written = [];

  @override
  void writeStanza(AbstractStanza stanza) {
    written.add(stanza);
  }

  @override
  void writeNonza(Nonza nonza) {}

  @override
  void write(Object? message) {}
}

XmppElement _conferencePayload({required String jid, String? name, bool autoJoin = false, String? nick}) {
  final conference = XmppElement()..name = 'conference';
  conference.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bookmarks:1'));
  conference.addAttribute(XmppAttribute('jid', jid));
  if (name != null) {
    conference.addAttribute(XmppAttribute('name', name));
  }
  if (autoJoin) {
    conference.addAttribute(XmppAttribute('autojoin', 'true'));
  }
  if (nick != null) {
    final nickElement = XmppElement()..name = 'nick';
    nickElement.textValue = nick;
    conference.addChild(nickElement);
  }
  return conference;
}

void main() {
  test('Request bookmarks sends pubsub items query', () {
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    final manager = BookmarksManager(
      connection: connection,
      selfBareJid: 'user@example.com',
      onUpdate: (_) {},
    );

    manager.requestBookmarks();

    expect(connection.written, isNotEmpty);
    final iq = connection.written.last as IqStanza;
    expect(iq.type, IqStanzaType.GET);
    final pubsub = iq.getChild('pubsub');
    expect(pubsub?.getAttribute('xmlns')?.value, 'http://jabber.org/protocol/pubsub');
    final items = pubsub?.getChild('items');
    expect(items?.getAttribute('node')?.value, 'urn:xmpp:bookmarks:1');
  });

  test('Parses bookmark payload from IQ result', () {
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    List<ContactEntry> updates = [];
    final manager = BookmarksManager(
      connection: connection,
      selfBareJid: 'user@example.com',
      onUpdate: (bookmarks) => updates = bookmarks,
    );

    final iq = IqStanza('abc', IqStanzaType.RESULT);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', 'urn:xmpp:bookmarks:1'));
    final item = XmppElement()..name = 'item';
    item.addChild(_conferencePayload(jid: 'room@conference.example', name: 'Team Room', autoJoin: true));
    items.addChild(item);
    pubsub.addChild(items);
    iq.addChild(pubsub);

    manager.handleStanza(iq);

    expect(updates, hasLength(1));
    expect(updates.first.jid, 'room@conference.example');
    expect(updates.first.isBookmark, isTrue);
    expect(updates.first.bookmarkAutoJoin, isTrue);
    expect(updates.first.displayName, 'Team Room');
  });

  test('Parses bookmark payload from pubsub event storage', () {
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    List<ContactEntry> updates = [];
    final manager = BookmarksManager(
      connection: connection,
      selfBareJid: 'user@example.com',
      onUpdate: (bookmarks) => updates = bookmarks,
    );

    final message = MessageStanza('m1', MessageStanzaType.CHAT);
    final event = XmppElement()..name = 'event';
    event.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#event'));
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', 'urn:xmpp:bookmarks:1'));
    final item = XmppElement()..name = 'item';
    final storage = XmppElement()..name = 'storage';
    storage.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bookmarks:1'));
    storage.addChild(_conferencePayload(jid: 'lounge@conference.example', name: 'Lounge', nick: 'wimsy'));
    item.addChild(storage);
    items.addChild(item);
    event.addChild(items);
    message.addChild(event);

    manager.handleStanza(message);

    expect(updates, hasLength(1));
    expect(updates.first.jid, 'lounge@conference.example');
    expect(updates.first.bookmarkNick, 'wimsy');
  });
}
