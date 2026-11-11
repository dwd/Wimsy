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
  String? senderOccupantId,
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
    senderOccupantId: senderOccupantId,
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
    'applyRetractionInList marks a matching message retracted and keeps body',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice@example.com/phone',
          to: 'bob@example.com/desktop',
          body: 'oops, wrong channel',
          id: 'm-retract-1',
        ),
      ];
      final retractedAt = DateTime.utc(2026, 1, 3);

      final applied = ChatMessageMutations.applyRetractionInList(
        list,
        sender: 'alice@example.com/laptop',
        retractId: 'm-retract-1',
        timestamp: retractedAt,
        matchSenderBare: true,
        bareJid: (jid) => jid.split('/').first,
      );

      expect(applied, isTrue);
      expect(list.single.retracted, isTrue);
      expect(list.single.retractedAt, retractedAt);
      // The original body is preserved so the UI can render it struck
      // through, rather than being cleared.
      expect(list.single.body, 'oops, wrong channel');
    },
  );

  test('applyRetractionInList returns false when no message matches', () {
    final list = <ChatMessage>[
      _message(
        from: 'alice@example.com',
        to: 'bob@example.com',
        body: 'hello',
        id: 'm-retract-2',
      ),
    ];

    final applied = ChatMessageMutations.applyRetractionInList(
      list,
      sender: 'alice@example.com',
      retractId: 'does-not-exist',
      timestamp: DateTime.utc(2026, 1, 3),
      matchSenderBare: false,
      bareJid: (jid) => jid,
    );

    expect(applied, isFalse);
    expect(list.single.retracted, isFalse);
  });

  test(
    'applyRetractionInList does not match when sender differs',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice@example.com',
          to: 'bob@example.com',
          body: 'hello',
          id: 'm-retract-3',
        ),
      ];

      final applied = ChatMessageMutations.applyRetractionInList(
        list,
        sender: 'mallory@example.com',
        retractId: 'm-retract-3',
        timestamp: DateTime.utc(2026, 1, 3),
        matchSenderBare: true,
        bareJid: (jid) => jid,
      );

      expect(applied, isFalse);
      expect(list.single.retracted, isFalse);
    },
  );

  test(
    'applyRetractionInList (MUC) matches by occupant-id even if the '
    'nickname changed',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice-old-nick',
          to: 'room@conference.example.com',
          body: 'hello room',
          id: 'm-retract-occ-1',
          senderOccupantId: 'occ-alice-1',
        ),
      ];

      final applied = ChatMessageMutations.applyRetractionInList(
        list,
        sender: 'alice-new-nick',
        retractId: 'm-retract-occ-1',
        timestamp: DateTime.utc(2026, 1, 3),
        matchSenderBare: false,
        bareJid: (jid) => jid,
        senderOccupantId: 'occ-alice-1',
      );

      expect(applied, isTrue);
      expect(list.single.retracted, isTrue);
    },
  );

  test(
    'applyRetractionInList (MUC) rejects a retraction from a different '
    'occupant-id, even if the nickname matches (impersonation/reused nick)',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice',
          to: 'room@conference.example.com',
          body: 'hello room',
          id: 'm-retract-occ-2',
          senderOccupantId: 'occ-alice-1',
        ),
      ];

      final applied = ChatMessageMutations.applyRetractionInList(
        list,
        sender: 'alice',
        retractId: 'm-retract-occ-2',
        timestamp: DateTime.utc(2026, 1, 3),
        matchSenderBare: false,
        bareJid: (jid) => jid,
        senderOccupantId: 'occ-mallory-1',
      );

      expect(applied, isFalse);
      expect(list.single.retracted, isFalse);
    },
  );

  test(
    'applyRetractionInList (MUC) falls back to nickname match when no '
    'occupant-id is available',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice',
          to: 'room@conference.example.com',
          body: 'hello room',
          id: 'm-retract-occ-3',
        ),
      ];

      final rejected = ChatMessageMutations.applyRetractionInList(
        list,
        sender: 'mallory',
        retractId: 'm-retract-occ-3',
        timestamp: DateTime.utc(2026, 1, 3),
        matchSenderBare: false,
        bareJid: (jid) => jid,
      );
      expect(rejected, isFalse);

      final applied = ChatMessageMutations.applyRetractionInList(
        list,
        sender: 'alice',
        retractId: 'm-retract-occ-3',
        timestamp: DateTime.utc(2026, 1, 3),
        matchSenderBare: false,
        bareJid: (jid) => jid,
      );
      expect(applied, isTrue);
      expect(list.single.retracted, isTrue);
    },
  );

  test(
    'applyModerationInList (XEP-0425) marks a matching message moderated '
    'and strikes it through when no reason is given',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice',
          to: 'room@conference.example.com',
          body: 'hello room',
          id: 'm-mod-1',
          stanzaId: 'archive-stanza-1',
        ),
      ];
      final moderatedAt = DateTime.utc(2026, 1, 4);

      final applied = ChatMessageMutations.applyModerationInList(
        list,
        applyToId: 'archive-stanza-1',
        timestamp: moderatedAt,
      );

      expect(applied, isTrue);
      expect(list.single.retracted, isTrue);
      expect(list.single.moderated, isTrue);
      expect(list.single.retractedAt, moderatedAt);
      expect(list.single.moderationReason, isNull);
      // No reason given, so the original body is preserved (to be struck
      // through by the UI), rather than being cleared.
      expect(list.single.body, 'hello room');
    },
  );

  test(
    'applyModerationInList (XEP-0425) replaces the body entirely with the '
    'moderator-supplied reason, when given',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice',
          to: 'room@conference.example.com',
          body: 'hello room',
          id: 'm-mod-2',
          stanzaId: 'archive-stanza-2',
        ),
      ];

      final applied = ChatMessageMutations.applyModerationInList(
        list,
        applyToId: 'archive-stanza-2',
        timestamp: DateTime.utc(2026, 1, 4),
        reason: 'Insults',
      );

      expect(applied, isTrue);
      expect(list.single.moderated, isTrue);
      expect(list.single.moderationReason, 'Insults');
      expect(list.single.body, 'Insults');
    },
  );

  test(
    'applyModerationInList matches by the archive stanza-id, not the '
    'origin messageId',
    () {
      final list = <ChatMessage>[
        _message(
          from: 'alice',
          to: 'room@conference.example.com',
          body: 'hello room',
          id: 'm-mod-3',
          stanzaId: 'archive-stanza-3',
        ),
      ];

      final applied = ChatMessageMutations.applyModerationInList(
        list,
        applyToId: 'm-mod-3',
        timestamp: DateTime.utc(2026, 1, 4),
      );

      expect(applied, isFalse);
      expect(list.single.moderated, isFalse);
    },
  );

  test('applyModerationInList returns false when no message matches', () {
    final list = <ChatMessage>[
      _message(
        from: 'alice',
        to: 'room@conference.example.com',
        body: 'hello room',
        id: 'm-mod-4',
        stanzaId: 'archive-stanza-4',
      ),
    ];

    final applied = ChatMessageMutations.applyModerationInList(
      list,
      applyToId: 'does-not-exist',
      timestamp: DateTime.utc(2026, 1, 4),
    );

    expect(applied, isFalse);
    expect(list.single.moderated, isFalse);
  });

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

  test(
    'applyWebxdcUpdateInList merges non-empty fields onto the last matching thread',
    () {
      final list = <ChatMessage>[
        ChatMessage(
          from: 'alice@example.com',
          to: 'bob@example.com',
          body: 'offer',
          timestamp: DateTime.utc(2026, 1, 1),
          outgoing: false,
          messageId: 'offer-1',
          rawXml: '<message/>',
          webxdcThreadId: 'thread-1',
          isWebxdcWidget: true,
          webxdcDocument: 'Old Doc',
        ),
        ChatMessage(
          from: 'alice@example.com',
          to: 'bob@example.com',
          body: 'later offer',
          timestamp: DateTime.utc(2026, 1, 2),
          outgoing: false,
          messageId: 'offer-2',
          rawXml: '<message/>',
          webxdcThreadId: 'thread-1',
          isWebxdcWidget: true,
        ),
      ];

      final changed = ChatMessageMutations.applyWebxdcUpdateInList(
        list,
        threadId: 'thread-1',
        document: 'New Doc',
        summary: '3 events',
        jsonPayload: '{"n":3}',
      );

      expect(changed, isTrue);
      expect(list[0].webxdcDocument, 'Old Doc');
      expect(list[1].webxdcDocument, 'New Doc');
      expect(list[1].webxdcSummary, '3 events');
      expect(list[1].webxdcJsonPayload, '{"n":3}');

      final unchanged = ChatMessageMutations.applyWebxdcUpdateInList(
        list,
        threadId: 'thread-1',
        document: null,
        summary: '',
        jsonPayload: null,
      );
      expect(unchanged, isTrue);
      expect(list[1].webxdcDocument, 'New Doc');
      expect(list[1].webxdcSummary, '3 events');

      final missing = ChatMessageMutations.applyWebxdcUpdateInList(
        list,
        threadId: 'missing',
        document: 'x',
      );
      expect(missing, isFalse);
    },
  );
}
