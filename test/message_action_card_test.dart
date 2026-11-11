import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/widgets/message_action_card.dart';

void main() {
  ChatMessage buildMessage({Map<String, List<String>>? reactions}) {
    return ChatMessage(
      from: 'juliet@example.com',
      to: 'romeo@example.com',
      body: 'Wherefore art thou, Romeo?',
      timestamp: DateTime.utc(2026),
      outgoing: false,
      messageId: 'card-test-message',
      reactions: reactions,
    );
  }

  testWidgets('only shows actions whose callback is non-null', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageActionCard(
            message: buildMessage(),
            senderName: 'Juliet',
            senderJid: 'juliet@example.com',
            onReply: () {},
          ),
        ),
      ),
    );

    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Edit message'), findsNothing);
    expect(find.text('Kick'), findsNothing);
    expect(find.text('Ban'), findsNothing);
    expect(find.text('Add reaction'), findsNothing);
    expect(find.text('View reactions'), findsNothing);
  });

  testWidgets('tapping an action icon invokes its callback', (
    WidgetTester tester,
  ) async {
    var replied = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageActionCard(
            message: buildMessage(),
            senderName: 'Juliet',
            senderJid: 'juliet@example.com',
            onReply: () => replied = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Reply'));
    await tester.pump();

    expect(replied, isTrue);
  });

  testWidgets('shows "View reactions" only when the message has reactions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageActionCard(
            message: buildMessage(
              reactions: {
                '👍': ['romeo@example.com'],
              },
            ),
            senderName: 'Juliet',
            senderJid: 'juliet@example.com',
            onViewReactions: () {},
          ),
        ),
      ),
    );

    expect(find.text('View reactions'), findsOneWidget);
  });

  testWidgets('shows contact status: "Added to contacts" when isContact', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageActionCard(
            message: buildMessage(),
            senderName: 'Juliet',
            senderJid: 'juliet@example.com',
            isContact: true,
          ),
        ),
      ),
    );

    expect(find.text('Added to contacts'), findsOneWidget);
    expect(find.text('Add to contacts'), findsNothing);
  });

  testWidgets(
    'shows "Add to contacts" affordance and invokes onAddToRoster when not yet a contact',
    (WidgetTester tester) async {
      var added = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageActionCard(
              message: buildMessage(),
              senderName: 'Juliet',
              senderJid: 'juliet@example.com',
              isContact: false,
              onAddToRoster: () => added = true,
            ),
          ),
        ),
      );

      expect(find.text('Add to contacts'), findsOneWidget);
      await tester.tap(find.text('Add to contacts'));
      await tester.pump();
      expect(added, isTrue);
    },
  );

  testWidgets('shows the sender\'s full JID when known and different', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageActionCard(
            message: buildMessage(),
            senderName: 'Tybalt',
            senderJid: 'tybalt@example.com',
            senderFullJid: 'verona@conference.example.com/tybalt',
          ),
        ),
      ),
    );

    expect(
      find.textContaining('verona@conference.example.com/tybalt'),
      findsOneWidget,
    );
  });

  testWidgets('tapping the scrim dismisses the card', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  showMessageActionCard(
                    context,
                    builder: (dismiss) => MessageActionCard(
                      message: buildMessage(),
                      senderName: 'Juliet',
                      senderJid: 'juliet@example.com',
                      onDismiss: dismiss,
                    ),
                  );
                },
                child: const Text('Open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Juliet'), findsOneWidget);

    // Tap the scrim, well outside the centered card.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.text('Juliet'), findsNothing);
  });
}
