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
      );

      expect(changed, isTrue);
      expect(list.single.reactions, {
        '😀': ['carol@example.com'],
        '👍': ['alice@example.com'],
      });
    },
  );
}
