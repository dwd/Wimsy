import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';
import 'package:wimsy/widgets/message_bubble.dart';

void main() {
  Widget buildBubble(ChatMessage message) {
    return MaterialApp(
      home: Scaffold(
        body: MessageBubble(
          message: message,
          senderName: 'Juliet',
          timestamp: '12:30',
          avatarBytes: null,
          chatBareJid: 'juliet@example.com',
          isRoom: false,
          service: XmppService(),
          replySenderName: null,
          replyBody: null,
          onReplyTargetTap: null,
          inviteRoomJid: null,
          inviteRoomName: null,
          inviteAvatarBytes: null,
          inviteReason: null,
          onJoinInvite: null,
          selfReactionSenderId: 'juliet@example.com',
          recentReactionOptions: const [],
          onReact: null,
          onEdit: null,
          onReply: null,
          onAcceptFile: null,
          onDeclineFile: null,
          onFallbackUpload: null,
        ),
      ),
    );
  }

  ChatMessage buildMessage({
    required DateTime timestamp,
    bool edited = false,
    DateTime? editedAt,
    bool retracted = false,
    DateTime? retractedAt,
  }) {
    return ChatMessage(
      from: 'juliet@example.com',
      to: 'romeo@example.com',
      body: 'Wherefore art thou, Romeo?',
      timestamp: timestamp,
      outgoing: false,
      messageId: 'bubble-test-message',
      edited: edited,
      editedAt: editedAt,
      retracted: retracted,
      retractedAt: retractedAt,
    );
  }

  testWidgets(
    'shows a low-contrast "[edited]" label in the footer, without a '
    'timestamp when the edit happened within two minutes',
    (WidgetTester tester) async {
      final original = DateTime(2026, 1, 1, 12, 30);
      await tester.pumpWidget(
        buildBubble(
          buildMessage(
            timestamp: original,
            edited: true,
            editedAt: original.add(const Duration(seconds: 30)),
          ),
        ),
      );

      expect(find.text('[edited]'), findsOneWidget);
    },
  );

  testWidgets(
    'appends the edit timestamp when the edit happened more than two '
    'minutes after the original message',
    (WidgetTester tester) async {
      final original = DateTime(2026, 1, 1, 12, 30);
      await tester.pumpWidget(
        buildBubble(
          buildMessage(
            timestamp: original,
            edited: true,
            editedAt: original.add(const Duration(minutes: 5)),
          ),
        ),
      );

      expect(find.text('[edited]'), findsNothing);
      expect(find.textContaining('[edited] '), findsOneWidget);
    },
  );

  testWidgets(
    'shows a "[retracted]" label in the footer rather than a chip next '
    'to the sender name',
    (WidgetTester tester) async {
      final original = DateTime(2026, 1, 1, 12, 30);
      await tester.pumpWidget(
        buildBubble(
          buildMessage(
            timestamp: original,
            retracted: true,
            retractedAt: original.add(const Duration(seconds: 10)),
          ),
        ),
      );

      expect(find.text('[retracted]'), findsOneWidget);
    },
  );

  testWidgets('shows neither label for a plain, unedited message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildBubble(buildMessage(timestamp: DateTime(2026, 1, 1, 12, 30))),
    );

    expect(find.textContaining('[edited]'), findsNothing);
    expect(find.textContaining('[retracted]'), findsNothing);
  });
}
