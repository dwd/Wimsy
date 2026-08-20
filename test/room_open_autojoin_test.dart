import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal self-contained model of the "open room chat -> join -> enable
// bookmark autojoin" logic extracted from XmppService so it can be tested
// without a real XMPP stack.
//
// The production code lives in xmpp_service.dart:
//   - `selectChat()` now immediately calls `joinRoom()` when the bookmarked
//     room being opened is not already marked `joined`, instead of only
//     ensuring the room entry exists. Rooms already marked `joined` are left
//     untouched (no redundant join request).
//   - The MUC self-presence handler (in `_listenToMucEvents`'s
//     `roomPresenceStream` listener) enables `bookmarkAutoJoin` for the
//     corresponding bookmark, and persists it via `upsertBookmark()`, once a
//     join is confirmed by the server (`presence.isSelf && !unavailable`).
//     This mirrors `_handleMucJoinError`, which does the opposite (disables
//     autojoin) on a join failure.
// ---------------------------------------------------------------------------

class _RoomEntry {
  _RoomEntry({required this.roomJid, this.joined = false});

  final String roomJid;
  final bool joined;

  _RoomEntry copyWith({bool? joined}) =>
      _RoomEntry(roomJid: roomJid, joined: joined ?? this.joined);
}

class _Bookmark {
  _Bookmark({required this.jid, required this.autoJoin});

  final String jid;
  final bool autoJoin;

  _Bookmark copyWith({bool? autoJoin}) =>
      _Bookmark(jid: jid, autoJoin: autoJoin ?? this.autoJoin);
}

class _RoomModel {
  final Map<String, _RoomEntry> rooms = {};
  final List<_Bookmark> bookmarks = [];
  final List<String> realJoins = [];
  final List<String> persistedBookmarkUpdates = [];

  bool isBookmark(String jid) => bookmarks.any((b) => b.jid == jid);

  /// Mirrors XmppService.joinRoom(): optimistically marks the room joined
  /// and records that a real join was sent.
  void joinRoom(String roomJid) {
    realJoins.add(roomJid);
    final existing = rooms[roomJid] ?? _RoomEntry(roomJid: roomJid);
    rooms[roomJid] = existing.copyWith(joined: true);
  }

  /// Mirrors XmppService.selectChat() for a bookmarked room: it joins the
  /// room immediately if it isn't already joined.
  void selectChat(String jid) {
    if (!isBookmark(jid)) {
      return;
    }
    rooms.putIfAbsent(jid, () => _RoomEntry(roomJid: jid));
    if (rooms[jid]?.joined != true) {
      joinRoom(jid);
    }
  }

  /// Mirrors the self-presence success handling: once a join is confirmed,
  /// enable and persist bookmark autojoin if it wasn't already enabled.
  void confirmJoinSuccess(String roomJid) {
    final index = bookmarks.indexWhere((b) => b.jid == roomJid);
    if (index < 0 || bookmarks[index].autoJoin) {
      return;
    }
    bookmarks[index] = bookmarks[index].copyWith(autoJoin: true);
    persistedBookmarkUpdates.add(roomJid);
  }
}

void main() {
  group('Opening a room chat joins it and enables bookmark autojoin', () {
    test('opening a room that is not joined triggers an immediate join', () {
      final model = _RoomModel();
      model.bookmarks.add(_Bookmark(jid: 'room@conference.example', autoJoin: false));

      model.selectChat('room@conference.example');

      expect(model.realJoins, ['room@conference.example']);
    });

    test('opening a room that is already joined does not re-join it', () {
      final model = _RoomModel();
      model.bookmarks.add(_Bookmark(jid: 'room@conference.example', autoJoin: false));
      model.rooms['room@conference.example'] =
          _RoomEntry(roomJid: 'room@conference.example', joined: true);

      model.selectChat('room@conference.example');

      expect(model.realJoins, isEmpty);
    });

    test('a successful join enables autojoin for a bookmark that had it disabled', () {
      final model = _RoomModel();
      model.bookmarks.add(_Bookmark(jid: 'room@conference.example', autoJoin: false));

      model.selectChat('room@conference.example');
      model.confirmJoinSuccess('room@conference.example');

      expect(model.bookmarks.single.autoJoin, isTrue);
      expect(model.persistedBookmarkUpdates, ['room@conference.example']);
    });

    test('a successful join does not re-persist a bookmark that already has autojoin enabled', () {
      final model = _RoomModel();
      model.bookmarks.add(_Bookmark(jid: 'room@conference.example', autoJoin: true));

      model.selectChat('room@conference.example');
      model.confirmJoinSuccess('room@conference.example');

      expect(model.bookmarks.single.autoJoin, isTrue);
      expect(model.persistedBookmarkUpdates, isEmpty);
    });

    test('a non-bookmarked chat is never joined as a room', () {
      final model = _RoomModel();

      model.selectChat('friend@example.com');

      expect(model.realJoins, isEmpty);
      expect(model.rooms, isEmpty);
    });
  });
}
