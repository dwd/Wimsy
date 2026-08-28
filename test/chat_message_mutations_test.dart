import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/xmpp/chat_message_mutations.dart';
import 'package:wimsy/xmpp/message_intent_builder.dart';

ChatMessage _message({
  required String from,
  required String to,
  required String body,
  required String id,
  String? stanzaId,
  Map<String, List<String>>? reactions,
  bool edited = false,
}) {
  return ChatMessage(
    from: from,
    to: to,
    body: body,
    timestamp: DateTime.utc(2026, 1, 1),
    outgoing: false,
    messageId: id,
    stanzaId: stanzaId,
    rawXml: '<message/>',
    reactions: reactions,
    edited: edited,
  );
}

void main() {
  test(
    'applyCorrectionInList matches sender by bare JID and updates payload',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice@example.com/phone',
          to: 'bob@example.com/desktop',
          body: 'old',
          id: 'm1',
        ),
      ];
      final editedAt = DateTime.utc(2026, 1, 2);

      final applied = ChatMessageMutations.applyCorrectionInList(
        list,
        sender: 'alice@example.com/laptop',
        replaceId: 'm1',
        newBody: 'new',
        rawXml: '<message id="m1"/>',
        timestamp: editedAt,
        matchSenderBare: true,
        bareJid: (jid) => jid.split('/').first,
        oobUrl: 'https://example.com/new.png',
        oobDescription: 'New image',
      );

      expect(applied, isTrue);
      expect(list.single.body, 'new');
      expect(list.single.edited, isTrue);
      expect(list.single.editedAt, editedAt);
      expect(list.single.oobUrl, 'https://example.com/new.png');
      expect(list.single.oobDescription, 'New image');
    },
  );

  test(
    'updateReactionsInList rewrites sender reactions for target message',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice@example.com',
          to: 'bob@example.com',
          body: 'hello',
          id: 'm2',
          stanzaId: 's2',
          reactions: {
            '😀': ['alice@example.com', 'carol@example.com'],
            '🔥': ['alice@example.com'],
          },
        ),
      ];

      final changed = ChatMessageMutations.updateReactionsInList(
        list,
        'alice@example.com',
        ReactionUpdate('s2', ['👍']),
        isRoom: true,
      );

      expect(changed, isTrue);
      expect(list.single.reactions, {
        '😀': ['carol@example.com'],
        '👍': ['alice@example.com'],
      });
    },
  );

  test('updateReactionsInList keeps multiple reactions for one sender', () {
    final list = <ChatMessage>[
      _message(
        from: 'alice@example.com',
        to: 'bob@example.com',
        body: 'hello',
        id: 'm3',
        stanzaId: 's3',
        reactions: {
          '😀': ['alice@example.com', 'carol@example.com'],
        },
      ),
    ];

    final changed = ChatMessageMutations.updateReactionsInList(
      list,
      'alice@example.com',
      ReactionUpdate('s3', ['😀', '🔥']),
      isRoom: true,
    );

    expect(changed, isTrue);
    expect(list.single.reactions, {
      '😀': ['alice@example.com', 'carol@example.com'],
      '🔥': ['alice@example.com'],
    });
  });

  test('applyCorrectionInList returns false when replaceId not found', () {
    final list = <ChatMessage>[
      _message(
        from: 'alice@example.com',
        to: 'bob@example.com',
        body: 'original',
        id: 'm-existing',
      ),
    ];

    final applied = ChatMessageMutations.applyCorrectionInList(
      list,
      sender: 'alice@example.com',
      replaceId: 'no-such-id',
      newBody: 'updated',
      rawXml: '<message/>',
      timestamp: DateTime.utc(2026, 1, 2),
      matchSenderBare: false,
      bareJid: (jid) => jid.split('/').first,
    );

    expect(applied, isFalse);
    expect(list.single.body, 'original');
  });

  test(
    'applyCorrectionInList returns false when sender bare JID does not match',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice@example.com/phone',
          to: 'bob@example.com',
          body: 'original',
          id: 'm-sender-mismatch',
        ),
      ];

      final applied = ChatMessageMutations.applyCorrectionInList(
        list,
        sender: 'eve@example.com/laptop',
        replaceId: 'm-sender-mismatch',
        newBody: 'spoofed',
        rawXml: '<message/>',
        timestamp: DateTime.utc(2026, 1, 2),
        matchSenderBare: true,
        bareJid: (jid) => jid.split('/').first,
      );

      expect(applied, isFalse);
      expect(list.single.body, 'original');
    },
  );

  test('applyCorrectionInList returns false when exact sender does not match '
      'and matchSenderBare is false', () {
    final list = <ChatMessage>[
      _message(
        from: 'alice@example.com/phone',
        to: 'bob@example.com',
        body: 'original',
        id: 'm-exact-mismatch',
      ),
    ];

    // Same bare JID but different resource — must not match when
    // matchSenderBare is false.
    final applied = ChatMessageMutations.applyCorrectionInList(
      list,
      sender: 'alice@example.com/laptop',
      replaceId: 'm-exact-mismatch',
      newBody: 'updated',
      rawXml: '<message/>',
      timestamp: DateTime.utc(2026, 1, 2),
      matchSenderBare: false,
      bareJid: (jid) => jid.split('/').first,
    );

    expect(applied, isFalse);
    expect(list.single.body, 'original');
  });

  test(
    'applyCorrectionInList applies correction to most-recent matching message',
    () {
      // Two messages with the same ID (shouldn't happen in practice, but the
      // implementation iterates from the end — verify it picks the last one).
      final list = <ChatMessage>[
        _message(
          from: 'alice@example.com',
          to: 'bob@example.com',
          body: 'first',
          id: 'm-dup',
        ),
        _message(
          from: 'alice@example.com',
          to: 'bob@example.com',
          body: 'second',
          id: 'm-dup',
        ),
      ];

      ChatMessageMutations.applyCorrectionInList(
        list,
        sender: 'alice@example.com',
        replaceId: 'm-dup',
        newBody: 'corrected',
        rawXml: '<message/>',
        timestamp: DateTime.utc(2026, 1, 2),
        matchSenderBare: false,
        bareJid: (jid) => jid.split('/').first,
      );

      expect(list[0].body, 'first');
      expect(list[1].body, 'corrected');
    },
  );

  test('updateReactionsInList returns false when stanza ID not found', () {
    final list = <ChatMessage>[
      _message(
        from: 'alice@example.com',
        to: 'bob@example.com',
        body: 'hello',
        id: 'm5',
        stanzaId: 's5',
      ),
    ];

    final changed = ChatMessageMutations.updateReactionsInList(
      list,
      'alice@example.com',
      ReactionUpdate('no-such-stanza', ['👍']),
      isRoom: true,
    );

    expect(changed, isFalse);
    expect(list.single.reactions, isNull);
  });

  test('updateReactionsInList returns false for empty sender', () {
    final list = <ChatMessage>[
      _message(
        from: 'alice@example.com',
        to: 'bob@example.com',
        body: 'hello',
        id: 'm6',
        stanzaId: 's6',
      ),
    ];

    final changed = ChatMessageMutations.updateReactionsInList(
      list,
      '',
      ReactionUpdate('s6', ['👍']),
      isRoom: true,
    );

    expect(changed, isFalse);
  });

  test('updateReactionsInList matches by messageId when stanzaId absent', () {
    final list = <ChatMessage>[
      _message(
        from: 'alice@example.com',
        to: 'bob@example.com',
        body: 'hello',
        id: 'm7',
        // no stanzaId
      ),
    ];

    final changed = ChatMessageMutations.updateReactionsInList(
      list,
      'bob@example.com',
      ReactionUpdate('m7', ['❤️']),
      isRoom: false,
    );

    expect(changed, isTrue);
    expect(list.single.reactions, {
      '❤️': ['bob@example.com'],
    });
  });

  test('direct reactions do not match a private stanzaId', () {
    final list = <ChatMessage>[
      _message(
        from: 'alice@example.com',
        to: 'bob@example.com',
        body: 'hello',
        id: 'message-id',
        stanzaId: 'private-server-id',
      ),
    ];

    final changed = ChatMessageMutations.updateReactionsInList(
      list,
      'bob@example.com',
      ReactionUpdate('private-server-id', ['❤️']),
      isRoom: false,
    );

    expect(changed, isFalse);
    expect(list.single.reactions, isNull);
  });

  test(
    'updateReactionsInList removes sender reactions when reaction list is empty',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice@example.com',
          to: 'bob@example.com',
          body: 'hello',
          id: 'm4',
          stanzaId: 's4',
          reactions: {
            '😀': ['alice@example.com', 'carol@example.com'],
            '🔥': ['alice@example.com'],
          },
        ),
      ];

      final changed = ChatMessageMutations.updateReactionsInList(
        list,
        'alice@example.com',
        ReactionUpdate('s4', const []),
        isRoom: true,
      );

      expect(changed, isTrue);
      expect(list.single.reactions, {
        '😀': ['carol@example.com'],
      });
    },
  );
}
