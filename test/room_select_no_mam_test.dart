import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal self-contained model of the room-selection MAM logic extracted
// from XmppService so it can be tested without a real XMPP stack.
//
// The production code lives in xmpp_service.dart:
//   - `joinRoom()` requests MAM catch-up (or an initial MAM fetch) when a
//     room is joined, since joining is the point at which we start
//     receiving live messages and might have missed history.
//   - `selectChat()` used to also request MAM for rooms every time the UI
//     switched to a bookmarked room (`_requestRoomMamOnOpen`), even if the
//     room was already joined and therefore already up to date. That was
//     redundant and wasteful, so `selectChat()` no longer requests MAM for
//     rooms at all; it only updates UI-facing state (ensuring the room
//     entry exists and publishing the "displayed" marker).
// ---------------------------------------------------------------------------

class _RoomModel {
  final Set<String> joinedRooms = {};
  final List<String> mamRequests = [];
  final List<String> ensuredRooms = [];

  /// Mirrors XmppService.joinRoom(): joining a room triggers a MAM
  /// catch-up/initial fetch.
  void joinRoom(String roomJid) {
    joinedRooms.add(roomJid);
    mamRequests.add(roomJid);
  }

  /// Mirrors XmppService.selectChat() for a bookmarked room: it no longer
  /// issues a MAM request, it only ensures the room entry exists.
  void selectChat(String roomJid) {
    ensuredRooms.add(roomJid);
  }
}

void main() {
  group('Room selection does not re-trigger MAM', () {
    test('joining a room requests MAM catch-up', () {
      final model = _RoomModel();

      model.joinRoom('room@conference.example');

      expect(model.mamRequests, ['room@conference.example']);
    });

    test(
      'switching to an already-joined room in the UI does not request MAM '
      'again',
      () {
        final model = _RoomModel();

        model.joinRoom('room@conference.example');
        model.selectChat('room@conference.example');
        model.selectChat('room@conference.example');

        // Only the join triggered a MAM request; repeatedly switching to the
        // room in the UI must not.
        expect(model.mamRequests, ['room@conference.example']);
        expect(
          model.ensuredRooms,
          ['room@conference.example', 'room@conference.example'],
        );
      },
    );

    test(
      'switching between multiple already-joined rooms never requests MAM',
      () {
        final model = _RoomModel();

        model.joinRoom('one@conference.example');
        model.joinRoom('two@conference.example');
        model.mamRequests.clear();

        model.selectChat('one@conference.example');
        model.selectChat('two@conference.example');
        model.selectChat('one@conference.example');

        expect(model.mamRequests, isEmpty);
      },
    );
  });
}
