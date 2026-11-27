import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/storage/storage_service.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

class _StorageWithUnresolvedMarker extends StorageService {
  @override
  Map<String, String> loadDisplayedSync() => {'alice@example.com': 'missing'};
}

void main() {
  test('selecting a cached direct chat does not restart catch-up', () {
    final service = XmppService();
    addTearDown(service.dispose);
    service.attachStorage(_StorageWithUnresolvedMarker());
    service.seedMessages({
      'alice@example.com': [
        ChatMessage(
          from: 'alice@example.com',
          to: 'bob@example.com',
          body: 'hello',
          outgoing: false,
          timestamp: DateTime.utc(2026),
          messageId: 'message',
        ),
      ],
    });

    expect(service.isMamCatchUpCompleteFor('alice@example.com'), isTrue);
    service.selectChat('alice@example.com');
    expect(service.isMamCatchUpCompleteFor('alice@example.com'), isTrue);
  });
}