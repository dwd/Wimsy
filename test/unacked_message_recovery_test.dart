import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/xmpp/unacked_message_recovery.dart';

ChatMessage _outgoing(
  String id, {
  bool acked = false,
  bool received = false,
  String? mamId,
  DateTime? timestamp,
}) {
  return ChatMessage(
    from: 'me@example.com',
    to: 'you@example.com',
    body: id,
    timestamp: timestamp ?? DateTime.utc(2026),
    outgoing: true,
    messageId: id,
    acked: acked,
    receiptReceived: received,
    mamId: mamId,
  );
}

void main() {
  test('resends only messages still unacknowledged and absent from MAM', () {
    final recovery = UnackedMessageRecovery();
    final messages = <String, List<ChatMessage>>{
      'you@example.com': [
        _outgoing('lost'),
        _outgoing('already-acked', acked: true),
        _outgoing('older', timestamp: DateTime.utc(2025)),
      ],
    };
    recovery.capture(messages, const {});

    // MAM returned one of the candidates while catch-up was running.
    messages['you@example.com']![2] = messages['you@example.com']![2].copyWith(
      mamId: 'archive-1',
    );
    final sentAt = DateTime.utc(2026, 8, 30, 12);
    final resends = recovery.reconcile(
      directMessages: messages,
      roomMessages: const {},
      now: () => sentAt,
    );

    expect(resends.map((item) => item.message.messageId), ['lost']);
    expect(resends.single.message.timestamp, sentAt);
    expect(messages['you@example.com']!.last.messageId, 'lost');
    expect(
      messages['you@example.com']!.last.messageId,
      resends.single.message.messageId,
    );
  });

  test('a receipt arriving during MAM catch-up prevents resend', () {
    final recovery = UnackedMessageRecovery();
    final messages = <String, List<ChatMessage>>{
      'you@example.com': [_outgoing('delivered-later')],
    };
    recovery.capture(messages, const {});
    messages['you@example.com']![0] = messages['you@example.com']![0].copyWith(
      receiptReceived: true,
    );

    expect(
      recovery.reconcile(
        directMessages: messages,
        roomMessages: const {},
        now: DateTime.now,
      ),
      isEmpty,
    );
  });

  test('chat-scoped reconciliation leaves other candidates pending', () {
    final recovery = UnackedMessageRecovery();
    final messages = <String, List<ChatMessage>>{
      'one@example.com': [_outgoing('one')],
      'two@example.com': [_outgoing('two')],
    };
    recovery.capture(messages, const {});

    final first = recovery.reconcile(
      directMessages: messages,
      roomMessages: const {},
      now: DateTime.now,
      onlyJid: 'one@example.com',
      onlyRooms: false,
    );
    final second = recovery.reconcile(
      directMessages: messages,
      roomMessages: const {},
      now: DateTime.now,
    );

    expect(first.single.message.messageId, 'one');
    expect(second.single.message.messageId, 'two');
  });
}
