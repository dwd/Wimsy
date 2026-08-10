import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/bookmarks/bookmarks_manager.dart';
import 'package:wimsy/models/contact_entry.dart';
import 'package:wimsy/models/muc_notify_settings.dart';

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

XmppElement _extensionsPayload() {
  final extensions = XmppElement()..name = 'extensions';
  final note = XmppElement()..name = 'note';
  note.textValue = 'Pinned';
  extensions.addChild(note);
  return extensions;
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

  test('Publish includes publish-options and preserves extensions', () async {
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    final manager = BookmarksManager(
      connection: connection,
      selfBareJid: 'user@example.com',
      onUpdate: (_) {},
    );

    final message = MessageStanza('m1', MessageStanzaType.CHAT);
    final event = XmppElement()..name = 'event';
    event.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#event'));
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', 'urn:xmpp:bookmarks:1'));
    final item = XmppElement()..name = 'item';
    final conference = _conferencePayload(jid: 'team@conference.example', name: 'Team');
    conference.addChild(_extensionsPayload());
    item.addChild(conference);
    items.addChild(item);
    event.addChild(items);
    message.addChild(event);

    manager.handleStanza(message);

    await manager.upsertBookmark(ContactEntry(jid: 'team@conference.example', name: 'Team'));

    final publishIq = connection.written.whereType<IqStanza>().firstWhere((iq) {
      final pubsub = iq.getChild('pubsub');
      return pubsub?.getChild('publish') != null;
    });
    final pubsub = publishIq.getChild('pubsub');
    final publish = pubsub?.getChild('publish');
    final publishOptions = pubsub?.getChild('publish-options');
    expect(publishOptions, isNotNull);
    final x = publishOptions!.getChild('x');
    expect(x?.getAttribute('type')?.value, 'submit');
    final itemElement = publish?.getChild('item');
    final payload = itemElement?.getChild('conference');
    final extensions = payload?.getChild('extensions');
    expect(extensions, isNotNull);
    expect(extensions?.getChild('note')?.textValue, 'Pinned');
  });

  test('Parses MUC notify settings received from a PEP event', () {
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
    final conference = _conferencePayload(jid: 'team@conference.example', name: 'Team', nick: 'dave');
    final extensions = XmppElement()..name = 'extensions';
    const settings = MucNotifySettings(
      mode: MucNotifyMode.all,
      afterOwnMessagePeriod: Duration(minutes: 10),
    );
    extensions.addChild(settings.toXml());
    conference.addChild(extensions);
    item.addChild(conference);
    items.addChild(item);
    event.addChild(items);
    message.addChild(event);

    manager.handleStanza(message);

    expect(updates, hasLength(1));
    expect(updates.first.mucNotifySettings, settings);

    // The setting should also be preserved verbatim when the bookmark is
    // subsequently republished (e.g. after an unrelated edit made locally).
  });

  test('setMucNotifySettings republishes bookmark with updated settings', () async {
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    final manager = BookmarksManager(
      connection: connection,
      selfBareJid: 'user@example.com',
      onUpdate: (_) {},
    );

    await manager.upsertBookmark(ContactEntry(jid: 'team@conference.example', name: 'Team'));
    connection.written.clear();

    const settings = MucNotifySettings(
      mode: MucNotifyMode.mentions,
      alwaysAfterOwnMessage: true,
    );
    await manager.setMucNotifySettings('team@conference.example', settings);

    expect(manager.bookmarks.single.mucNotifySettings, settings);

    final publishIq = connection.written.whereType<IqStanza>().firstWhere((iq) {
      final pubsub = iq.getChild('pubsub');
      return pubsub?.getChild('publish') != null;
    });
    final conference = publishIq
        .getChild('pubsub')
        ?.getChild('publish')
        ?.getChild('item')
        ?.getChild('conference');
    final notifyElement = conference?.getChild('extensions')?.getChild('notify');
    expect(notifyElement?.getAttribute('mode')?.value, 'mentions');
    expect(notifyElement?.getAttribute('after-own')?.value, 'always');
  });

  test('Retract includes notify=true', () async {
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    final manager = BookmarksManager(
      connection: connection,
      selfBareJid: 'user@example.com',
      onUpdate: (_) {},
    );

    await manager.removeBookmark('room@conference.example');

    final retractIq = connection.written.whereType<IqStanza>().firstWhere((iq) {
      final pubsub = iq.getChild('pubsub');
      return pubsub?.getChild('retract') != null;
    });
    final retract = retractIq.getChild('pubsub')?.getChild('retract');
    expect(retract?.getAttribute('notify')?.value, 'true');
  });
}
