import 'package:flutter_test/flutter_test.dart';

import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/models/contact_entry.dart';
import 'package:wimsy/models/muc_notify_settings.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

ChatMessage _roomMessage({
  required String from,
  required String body,
  DateTime? timestamp,
}) {
  return ChatMessage(
    from: from,
    to: 'room@conference.example',
    body: body,
    timestamp: timestamp ?? DateTime(2026, 1, 1, 12),
    outgoing: false,
  );
}

void main() {
  const roomJid = 'room@conference.example';

  test('defaults to mentions-only mode when the bookmark has no explicit settings', () {
    final service = XmppService();
    service.seedBookmarks([
      ContactEntry(jid: roomJid, isBookmark: true, bookmarkNick: 'dave'),
    ]);
    final mention = _roomMessage(from: 'someone', body: 'dave: hi there');
    final unrelated = _roomMessage(from: 'someone', body: 'just chatting');

    expect(service.shouldNotifyForRoomContent(roomJid, mention), isTrue);
    expect(service.shouldNotifyForRoomContent(roomJid, unrelated), isFalse);
  });

  test('with no bookmark at all, falls back to mentions mode with an empty nick', () {
    final service = XmppService();
    final unrelated = _roomMessage(from: 'someone', body: 'just chatting');

    expect(service.shouldNotifyForRoomContent(roomJid, unrelated), isFalse);
  });

  test('mode=all notifies for every message regardless of mentions', () {
    final service = XmppService();
    service.seedBookmarks([
      ContactEntry(
        jid: roomJid,
        isBookmark: true,
        bookmarkNick: 'dave',
        mucNotifySettings: const MucNotifySettings(mode: MucNotifyMode.all),
      ),
    ]);

    final unrelated = _roomMessage(from: 'someone', body: 'just chatting');
    expect(service.shouldNotifyForRoomContent(roomJid, unrelated), isTrue);
  });

  test('mode=mentions only notifies for messages mentioning the nickname', () {
    final service = XmppService();
    service.seedBookmarks([
      ContactEntry(
        jid: roomJid,
        isBookmark: true,
        bookmarkNick: 'dave',
        mucNotifySettings: const MucNotifySettings(mode: MucNotifyMode.mentions),
      ),
    ]);

    final mention = _roomMessage(from: 'someone', body: 'hey @dave look at this');
    final unrelated = _roomMessage(from: 'someone', body: 'just chatting');

    expect(service.shouldNotifyForRoomContent(roomJid, mention), isTrue);
    expect(service.shouldNotifyForRoomContent(roomJid, unrelated), isFalse);
  });

  test('notifies for unrelated messages within the after-own-message window', () {
    final service = XmppService();
    service.seedBookmarks([
      ContactEntry(
        jid: roomJid,
        isBookmark: true,
        bookmarkNick: 'dave',
        mucNotifySettings: const MucNotifySettings(
          mode: MucNotifyMode.mentions,
          afterOwnMessagePeriod: Duration(minutes: 10),
        ),
      ),
    ]);
    final ownMessageAt = DateTime(2026, 1, 1, 12);
    service.seedRoomLastOwnMessageAtForTesting(roomJid, ownMessageAt);

    final withinWindow = _roomMessage(
      from: 'someone',
      body: 'just chatting',
      timestamp: ownMessageAt.add(const Duration(minutes: 5)),
    );
    final afterWindow = _roomMessage(
      from: 'someone',
      body: 'just chatting',
      timestamp: ownMessageAt.add(const Duration(minutes: 20)),
    );

    expect(service.shouldNotifyForRoomContent(roomJid, withinWindow), isTrue);
    expect(service.shouldNotifyForRoomContent(roomJid, afterWindow), isFalse);
  });

  test('alwaysAfterOwnMessage notifies for any later message, however long after', () {
    final service = XmppService();
    service.seedBookmarks([
      ContactEntry(
        jid: roomJid,
        isBookmark: true,
        bookmarkNick: 'dave',
        mucNotifySettings: const MucNotifySettings(
          mode: MucNotifyMode.mentions,
          alwaysAfterOwnMessage: true,
        ),
      ),
    ]);
    final ownMessageAt = DateTime(2026, 1, 1, 12);
    service.seedRoomLastOwnMessageAtForTesting(roomJid, ownMessageAt);

    final muchLater = _roomMessage(
      from: 'someone',
      body: 'just chatting',
      timestamp: ownMessageAt.add(const Duration(days: 3)),
    );

    expect(service.shouldNotifyForRoomContent(roomJid, muchLater), isTrue);
  });

  test('messages before the own message are not covered by the after-own window', () {
    final service = XmppService();
    service.seedBookmarks([
      ContactEntry(
        jid: roomJid,
        isBookmark: true,
        bookmarkNick: 'dave',
        mucNotifySettings: const MucNotifySettings(
          mode: MucNotifyMode.mentions,
          alwaysAfterOwnMessage: true,
        ),
      ),
    ]);
    final ownMessageAt = DateTime(2026, 1, 1, 12);
    service.seedRoomLastOwnMessageAtForTesting(roomJid, ownMessageAt);

    final earlier = _roomMessage(
      from: 'someone',
      body: 'just chatting',
      timestamp: ownMessageAt.subtract(const Duration(minutes: 1)),
    );

    expect(service.shouldNotifyForRoomContent(roomJid, earlier), isFalse);
  });
}
