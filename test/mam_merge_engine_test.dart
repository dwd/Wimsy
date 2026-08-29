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
  bool receiptReceived = false,
}) {
  return ChatMessage(
    from: from,
    to: to,
    body: body,
    outgoing: outgoing,
    receiptReceived: receiptReceived,
    timestamp: timestamp,
    messageId: messageId,
    mamId: mamId,
    stanzaId: stanzaId,
    rawXml: rawXml,
    reactions: const {},
  );
}

void main() {
  test('outgoing MAM enrichment defaults to delivered tick state', () {
    final list = <ChatMessage>[
      _message(
        timestamp: DateTime.utc(2026, 1, 1, 10),
        messageId: 'local-1',
        from: 'me@example.com',
        to: 'alice@example.com',
        outgoing: true,
      ),
    ];

    final merged = mergeMamIdsIntoExisting(
      list,
      from: 'me@example.com',
      to: 'alice@example.com',
      body: 'hello',
      outgoing: true,
      timestamp: DateTime.utc(2026, 1, 1, 10, 0, 10),
      messageId: 'local-1',
      mamId: 'mam-1',
      stanzaId: 'sid-1',
    );

    expect(merged, isTrue);
    expect(list.single.receiptReceived, isTrue);
  });

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

  test('MAM enrichment fills a missing stanza attribute messageId', () {
    final list = <ChatMessage>[
      _message(timestamp: DateTime.utc(2026, 1, 1, 10)),
    ];

    final merged = mergeMamIdsIntoExisting(
      list,
      from: 'alice@example.com',
      to: 'bob@example.com',
      body: 'hello',
      outgoing: false,
      timestamp: DateTime.utc(2026, 1, 1, 10, 0, 30),
      messageId: 'peer-message-id',
      mamId: 'mam-2',
      stanzaId: 'private-server-id',
    );

    expect(merged, isTrue);
    expect(list.single.messageId, 'peer-message-id');
    expect(list.single.stanzaId, 'private-server-id');
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

  test('does not merge by heuristic when body differs', () {
    final list = <ChatMessage>[
      _message(timestamp: DateTime.utc(2026, 1, 1, 10), body: 'hello'),
    ];

    final merged = mergeMamIdsIntoExisting(
      list,
      from: 'alice@example.com',
      to: 'bob@example.com',
      body: 'different body',
      outgoing: false,
      timestamp: DateTime.utc(2026, 1, 1, 10, 0, 30),
      mamId: 'mam-x',
      stanzaId: 'sid-x',
    );

    expect(merged, isFalse);
    expect(list.single.mamId, isNull);
  });

  test('does not merge by heuristic when sender differs', () {
    final list = <ChatMessage>[
      _message(
        timestamp: DateTime.utc(2026, 1, 1, 10),
        from: 'alice@example.com',
      ),
    ];

    final merged = mergeMamIdsIntoExisting(
      list,
      from: 'eve@example.com',
      to: 'bob@example.com',
      body: 'hello',
      outgoing: false,
      timestamp: DateTime.utc(2026, 1, 1, 10, 0, 30),
      mamId: 'mam-y',
      stanzaId: 'sid-y',
    );

    expect(merged, isFalse);
    expect(list.single.mamId, isNull);
  });

  test('merges oobUrl and oobDescription via message-id match', () {
    final list = <ChatMessage>[
      _message(timestamp: DateTime.utc(2026, 1, 1, 10), messageId: 'msg-oob'),
    ];

    final merged = mergeMamIdsIntoExisting(
      list,
      from: 'alice@example.com',
      to: 'bob@example.com',
      body: 'hello',
      outgoing: false,
      timestamp: DateTime.utc(2026, 1, 1, 10, 0, 5),
      messageId: 'msg-oob',
      mamId: 'mam-oob',
      stanzaId: 'sid-oob',
      oobDescription: 'A photo',
      rawXml: '<message id="msg-oob"/>',
    );

    expect(merged, isTrue);
    expect(list.single.mamId, 'mam-oob');
    expect(list.single.oobDescription, 'A photo');
    expect(list.single.rawXml, '<message id="msg-oob"/>');
  });

  test(
    'does not merge by message-id when both mamId and stanzaId already set',
    () {
      final list = <ChatMessage>[
        _message(
          timestamp: DateTime.utc(2026, 1, 1, 10),
          messageId: 'msg-full',
          mamId: 'existing-mam',
          stanzaId: 'existing-sid',
        ),
      ];

      final merged = mergeMamIdsIntoExisting(
        list,
        from: 'alice@example.com',
        to: 'bob@example.com',
        body: 'hello',
        outgoing: false,
        timestamp: DateTime.utc(2026, 1, 1, 10, 0, 5),
        messageId: 'msg-full',
        mamId: 'new-mam',
        stanzaId: 'new-sid',
      );

      // Message-id matched but both IDs already present — no overwrite.
      expect(merged, isFalse);
      expect(list.single.mamId, 'existing-mam');
      expect(list.single.stanzaId, 'existing-sid');
    },
  );

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
