import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/xmpp/mam_merge_engine.dart';

ChatMessage _message({
  required String messageId,
  required DateTime timestamp,
  String? mamId,
  String body = 'same body',
}) {
  return ChatMessage(
    from: 'alice@example.com',
    to: 'bob@example.com',
    body: body,
    outgoing: false,
    timestamp: timestamp,
    messageId: messageId,
    mamId: mamId,
    rawXml: '<message/>',
    reactions: const {},
  );
}

void main() {
  test(
    'characterization: distinct messageId can collapse into existing message',
    () {
      final list = <ChatMessage>[
        _message(
          messageId: 'local-1',
          timestamp: DateTime.utc(2026, 1, 1, 12, 0),
        ),
      ];

      final merged = mergeMamIdsIntoExisting(
        list,
        from: 'alice@example.com',
        to: 'bob@example.com',
        body: 'same body',
        outgoing: false,
        timestamp: DateTime.utc(2026, 1, 1, 12, 1),
        messageId: 'remote-distinct',
        mamId: 'mam-middle',
        stanzaId: 'sid-middle',
      );

      // Current behavior: the incoming archived message is folded into
      // the existing local row, so list growth is suppressed.
      expect(merged, isTrue);
      expect(list, hasLength(1));
    expect(list.single.messageId, isNull);
      expect(list.single.mamId, 'mam-middle');
      expect(list.single.stanzaId, 'sid-middle');
    },
  );
}
