import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal self-contained model of the MUC reconnect-rejoin logic extracted
// from XmppService so it can be tested without a real XMPP stack.
//
// The production code lives in xmpp_service.dart:
//   - `Ready` only fires for a freshly-bound session (a resumed stream
//     instead reports `Resumed`), meaning the server has forgotten any MUC
//     occupancy we previously held even though `_rooms` still marks those
//     rooms `joined` from before the disconnect.
//   - `_rejoinRoomsAfterReconnect()` is called on `Ready`, before bookmark
//     autojoin and before `_sendInitialPresence()`. It re-sends a real join
//     (via `joinRoom`, which writes a presence stanza carrying the
//     `http://jabber.org/protocol/muc` `x` element) for every room still
//     marked `joined`, instead of leaving that stale state in place, which
//     previously caused a later plain presence update to be sent to a room
//     we were no longer actually in.
//   - `_autojoinRooms()` skips any bookmark whose room is already marked
//     `joined`, so bookmarked autojoin rooms handled by the reconnect-rejoin
//     step above are not joined a second time.
// ---------------------------------------------------------------------------

class _RoomEntry {
  _RoomEntry({required this.roomJid, this.nick, this.joined = false});

  final String roomJid;
  final String? nick;
  final bool joined;

  _RoomEntry copyWith({String? nick, bool? joined}) => _RoomEntry(
        roomJid: roomJid,
        nick: nick ?? this.nick,
        joined: joined ?? this.joined,
      );
}

class _Bookmark {
  _Bookmark({required this.jid, required this.autoJoin});

  final String jid;
  final bool autoJoin;
}

/// Records every join request as either a real "join" (proper MUC join
/// presence) or a plain "presence" update, mirroring the distinction between
/// `MucManager.joinRoom` and a bare directed presence stanza.
class _JoinRecorder {
  final List<String> realJoins = [];
  final List<String> presenceUpdates = [];
}

class _RoomModel {
  _RoomModel(this.recorder);

  final _JoinRecorder recorder;
  final Map<String, _RoomEntry> rooms = {};
  final List<_Bookmark> bookmarks = [];

  /// Mirrors XmppService.joinRoom(): sends a real join and marks the room
  /// as joined.
  void joinRoom(String roomJid, {String? nick}) {
    recorder.realJoins.add(roomJid);
    final existing = rooms[roomJid] ?? _RoomEntry(roomJid: roomJid);
    rooms[roomJid] = existing.copyWith(joined: true, nick: nick ?? existing.nick ?? 'nick');
  }

  /// Mirrors XmppService._sendDirectedPresenceToJoinedRooms(): sends a plain
  /// presence update to every room currently marked `joined`.
  void sendDirectedPresenceToJoinedRooms() {
    for (final entry in rooms.values) {
      if (entry.joined && entry.nick != null && entry.nick!.isNotEmpty) {
        recorder.presenceUpdates.add(entry.roomJid);
      }
    }
  }

  /// Mirrors XmppService._autojoinRooms(): joins every autojoin bookmark
  /// whose room isn't already marked `joined`.
  void autojoinRooms() {
    for (final bookmark in bookmarks) {
      if (!bookmark.autoJoin) {
        continue;
      }
      final existing = rooms[bookmark.jid];
      if (existing?.joined == true) {
        continue;
      }
      joinRoom(bookmark.jid);
    }
  }

  /// Mirrors XmppService._rejoinRoomsAfterReconnect(): re-sends a real join
  /// for every room still marked `joined` from before a fresh session bind.
  void rejoinRoomsAfterReconnect() {
    final previouslyJoined = rooms.values
        .where((entry) => entry.joined && entry.nick != null && entry.nick!.isNotEmpty)
        .toList(growable: false);
    for (final entry in previouslyJoined) {
      joinRoom(entry.roomJid, nick: entry.nick);
    }
  }
}

void main() {
  group('MUC reconnect rejoin', () {
    test(
      'without the reconnect-rejoin fix, a fresh session sends a plain '
      'presence update instead of a real join to a stale-joined room',
      () {
        final recorder = _JoinRecorder();
        final model = _RoomModel(recorder);

        // Simulate state left over from before the disconnect: the room is
        // still marked joined even though the server has forgotten us.
        model.rooms['room@conference.example'] =
            _RoomEntry(roomJid: 'room@conference.example', nick: 'alice', joined: true);

        // Ready fires but the reconnect-rejoin step is skipped (the bug).
        model.sendDirectedPresenceToJoinedRooms();

        expect(recorder.realJoins, isEmpty);
        expect(recorder.presenceUpdates, ['room@conference.example']);
      },
    );

    test(
      'on a fresh session, previously-joined rooms are re-joined with a '
      'real join before any presence update is sent',
      () {
        final recorder = _JoinRecorder();
        final model = _RoomModel(recorder);

        model.rooms['room@conference.example'] =
            _RoomEntry(roomJid: 'room@conference.example', nick: 'alice', joined: true);

        // Ready fires: rejoin happens first, then the initial presence pass.
        model.rejoinRoomsAfterReconnect();
        model.sendDirectedPresenceToJoinedRooms();

        expect(recorder.realJoins, ['room@conference.example']);
        expect(recorder.presenceUpdates, ['room@conference.example']);
      },
    );

    test('rooms that were not joined before reconnect are left untouched', () {
      final recorder = _JoinRecorder();
      final model = _RoomModel(recorder);

      model.rooms['left@conference.example'] =
          _RoomEntry(roomJid: 'left@conference.example', nick: 'alice', joined: false);

      model.rejoinRoomsAfterReconnect();

      expect(recorder.realJoins, isEmpty);
    });

    test(
      'autojoin bookmarks are not double-joined for rooms already handled '
      'by the reconnect-rejoin step',
      () {
        final recorder = _JoinRecorder();
        final model = _RoomModel(recorder);
        model.bookmarks.add(_Bookmark(jid: 'room@conference.example', autoJoin: true));
        model.rooms['room@conference.example'] =
            _RoomEntry(roomJid: 'room@conference.example', nick: 'alice', joined: true);

        model.rejoinRoomsAfterReconnect();
        model.autojoinRooms();

        expect(recorder.realJoins, ['room@conference.example']);
      },
    );

    test(
      'autojoin still joins bookmarked rooms that were not previously '
      'joined in this session',
      () {
        final recorder = _JoinRecorder();
        final model = _RoomModel(recorder);
        model.bookmarks.add(_Bookmark(jid: 'new@conference.example', autoJoin: true));

        model.rejoinRoomsAfterReconnect();
        model.autojoinRooms();

        expect(recorder.realJoins, ['new@conference.example']);
      },
    );
  });
}
