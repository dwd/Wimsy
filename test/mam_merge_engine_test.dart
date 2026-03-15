import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/xmpp/mam_merge_engine.dart';

ChatMessage _message({
  required DateTime timestamp,
  String? messageId,
  String? mamId,
  String? stanzaId,
  String body = 'hello',
  String from = 'alice@example.com',
  String to = 'bob@example.com',
  String rawXml = '<message/>',
  bool outgoing = false,
}) {
  return ChatMessage(
    from: from,
    to: to,
    body: body,
    outgoing: outgoing,
    timestamp: timestamp,
    messageId: messageId,
    mamId: mamId,
    stanzaId: stanzaId,
    rawXml: rawXml,
    reactions: const {},
  );
}

void main() {
  test('merges ids into message-id match that lacks MAM metadata', () {
    final list = <ChatMessage>[
      _message(
        timestamp: DateTime.utc(2026, 1, 1, 10),
        messageId: 'msg-1',
        rawXml: '<old/>',
      ),
    ];

    final merged = mergeMamIdsIntoExisting(
      list,
      from: 'alice@example.com',
      to: 'bob@example.com',
      body: 'hello',
      outgoing: false,
      timestamp: DateTime.utc(2026, 1, 1, 10, 0, 10),
      messageId: 'msg-1',
      mamId: 'mam-1',
      stanzaId: 'sid-1',
      rawXml: '<new/>',
    );

    expect(merged, isTrue);
    expect(list.single.mamId, 'mam-1');
    expect(list.single.stanzaId, 'sid-1');
    expect(list.single.rawXml, '<new/>');
  });

  test('merges by body/time window when existing has no archive ids', () {
    final list = <ChatMessage>[
      _message(timestamp: DateTime.utc(2026, 1, 1, 10), messageId: 'local-1'),
    ];

    final merged = mergeMamIdsIntoExisting(
      list,
      from: 'alice@example.com',
      to: 'bob@example.com',
      body: 'hello',
      outgoing: false,
      timestamp: DateTime.utc(2026, 1, 1, 10, 1, 30),
      mamId: 'mam-2',
      stanzaId: 'sid-2',
    );

    expect(merged, isTrue);
    expect(list.single.mamId, 'mam-2');
    expect(list.single.stanzaId, 'sid-2');
  });

  test('does not merge by heuristic when existing already has archive ids', () {
    final list = <ChatMessage>[
      _message(
        timestamp: DateTime.utc(2026, 1, 1, 10),
        messageId: 'local-1',
        mamId: 'existing',
      ),
    ];

    final merged = mergeMamIdsIntoExisting(
      list,
      from: 'alice@example.com',
      to: 'bob@example.com',
      body: 'hello',
      outgoing: false,
      timestamp: DateTime.utc(2026, 1, 1, 10, 1),
      mamId: 'mam-3',
      stanzaId: 'sid-3',
    );

    expect(merged, isFalse);
    expect(list.single.mamId, 'existing');
  });

  test('does not merge when message is outside merge window', () {
    final list = <ChatMessage>[
      _message(timestamp: DateTime.utc(2026, 1, 1, 10), messageId: 'local-1'),
    ];

    final merged = mergeMamIdsIntoExisting(
      list,
      from: 'alice@example.com',
      to: 'bob@example.com',
      body: 'hello',
      outgoing: false,
      timestamp: DateTime.utc(2026, 1, 1, 10, 3, 1),
      mamId: 'mam-4',
      stanzaId: 'sid-4',
    );

    expect(merged, isFalse);
    expect(list.single.mamId, isNull);
    expect(list.single.stanzaId, isNull);
  });
}
