import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/bookmarks/bookmarks_manager.dart';
import 'package:wimsy/models/contact_entry.dart';
import 'package:wimsy/models/muc_notify_settings.dart';

class TestConnection extends Connection {
  TestConnection(super.account);

  final List<AbstractStanza> written = [];

  /// Optional hook letting tests control the synthetic response sent back
  /// for every GET/SET IQ written via [writeStanza], simulating the server
  /// side of the round-trip that `publishToPrivatePepNodeWithRetry` (used by
  /// `BookmarksManager._publishBookmark`) waits on via `IqRouter`. By default
  /// every such IQ gets an immediate `RESULT` echoing its id - as if the
  /// server accepted everything - so existing tests that don't care about
  /// the publish round-trip don't need to set this up. Tests exercising the
  /// `precondition-not-met` retry path override this to return an `ERROR`
  /// for specific requests.
  IqStanza Function(IqStanza request)? respond;

  @override
  void writeStanza(AbstractStanza stanza) {
    written.add(stanza);
    if (stanza is IqStanza &&
        (stanza.type == IqStanzaType.SET || stanza.type == IqStanzaType.GET) &&
        stanza.id != null) {
      final response = respond?.call(stanza) ?? IqStanza(stanza.id, IqStanzaType.RESULT);
      fireNewStanzaEvent(response);
    }
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

  test(
    'Retries bookmark publish after precondition-not-met by reconfiguring '
    'the node, then succeeds',
    () async {
      final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
      final connection = TestConnection(account);
      final manager = BookmarksManager(
        connection: connection,
        selfBareJid: 'user@example.com',
        onUpdate: (_) {},
      );

      // Regression test for the bug where the server rejects every bookmark
      // publish with `<precondition-not-met/>` (e.g. because the node
      // doesn't support one of the asserted publish-options preconditions)
      // and `BookmarksManager` had no retry/reconfigure handling at all, so
      // bookmarks silently never made it into the standards-based
      // `urn:xmpp:bookmarks:1` node.
      var publishAttempts = 0;
      connection.respond = (request) {
        final pubsub = request.getChild('pubsub');
        if (pubsub?.getAttribute('xmlns')?.value == 'http://jabber.org/protocol/pubsub' &&
            pubsub?.getChild('publish') != null) {
          publishAttempts++;
          if (publishAttempts == 1) {
            final error = IqStanza(request.id, IqStanzaType.ERROR);
            final errorElement = XmppElement()..name = 'error';
            errorElement.addAttribute(XmppAttribute('type', 'cancel'));
            final conflict = XmppElement()..name = 'conflict';
            conflict.addAttribute(
                XmppAttribute('xmlns', 'urn:ietf:params:xml:ns:xmpp-stanzas'));
            errorElement.addChild(conflict);
            final precondition = XmppElement()..name = 'precondition-not-met';
            precondition.addAttribute(
                XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#errors'));
            errorElement.addChild(precondition);
            error.addChild(errorElement);
            return error;
          }
        }
        return IqStanza(request.id, IqStanzaType.RESULT);
      };

      await manager.upsertBookmark(ContactEntry(jid: 'team@conference.example', name: 'Team'));

      expect(
        publishAttempts,
        2,
        reason: 'should retry the publish once after reconfiguring',
      );
      final configureIq = connection.written.whereType<IqStanza>().firstWhere((iq) {
        final pubsub = iq.getChild('pubsub');
        return pubsub?.getAttribute('xmlns')?.value ==
                'http://jabber.org/protocol/pubsub#owner' &&
            pubsub?.getChild('configure') != null;
      });
      expect(
        configureIq.getChild('pubsub')?.getChild('configure')?.getAttribute('node')?.value,
        'urn:xmpp:bookmarks:1',
      );
    },
  );

  test(
    'Omits pubsub#send_last_published_item from publish-options when the '
    'bookmarks node configuration does not advertise it',
    () async {
      final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
      final connection = TestConnection(account);
      final manager = BookmarksManager(
        connection: connection,
        selfBareJid: 'user@example.com',
        onUpdate: (_) {},
      );

      // Mirrors the real-world MDS/bookmarks node config form that never
      // lists `pubsub#send_last_published_item` at all; once learned,
      // publishes must omit it instead of asserting an unsatisfiable
      // precondition.
      final configMessage = MessageStanza('cfg1', MessageStanzaType.CHAT);
      final event = XmppElement()..name = 'event';
      event.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#event'));
      final configuration = XmppElement()..name = 'configuration';
      configuration.addAttribute(XmppAttribute('node', 'urn:xmpp:bookmarks:1'));
      final x = XmppElement()..name = 'x';
      x.addAttribute(XmppAttribute('xmlns', 'jabber:x:data'));
      x.addAttribute(XmppAttribute('type', 'result'));
      for (final varName in [
        'FORM_TYPE',
        'pubsub#persist_items',
        'pubsub#access_model',
        'pubsub#max_items',
      ]) {
        final field = XmppElement()..name = 'field';
        field.addAttribute(XmppAttribute('var', varName));
        x.addChild(field);
      }
      configuration.addChild(x);
      event.addChild(configuration);
      configMessage.addChild(event);

      manager.handleStanza(configMessage);

      await manager.upsertBookmark(ContactEntry(jid: 'team@conference.example', name: 'Team'));

      final publishIq = connection.written.whereType<IqStanza>().firstWhere((iq) {
        final pubsub = iq.getChild('pubsub');
        return pubsub?.getChild('publish') != null;
      });
      final publishOptionsForm =
          publishIq.getChild('pubsub')?.getChild('publish-options')?.getChild('x');
      final fieldVars = publishOptionsForm?.children
          .where((c) => c.name == 'field')
          .map((f) => f.getAttribute('var')?.value)
          .toSet();
      expect(fieldVars, isNot(contains('pubsub#send_last_published_item')));
      expect(fieldVars, contains('pubsub#persist_items'));
    },
  );
}
