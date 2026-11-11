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

  testWidgets(
    'expands the full reaction set inline when the message has reactions',
    (WidgetTester tester) async {
      var viewed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageActionCard(
              message: buildMessage(
                reactions: {
                  '👍': ['romeo@example.com', 'tybalt@example.com'],
                },
              ),
              senderName: 'Juliet',
              senderJid: 'juliet@example.com',
              onViewReactions: () => viewed = true,
            ),
          ),
        ),
      );

      expect(find.text('👍'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      await tester.tap(find.text('👍'));
      await tester.pump();
      expect(viewed, isTrue);
    },
  );

  testWidgets('shows no reaction chips when the message has no reactions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageActionCard(
            message: buildMessage(),
            senderName: 'Juliet',
            senderJid: 'juliet@example.com',
          ),
        ),
      ),
    );

    expect(find.text('👍'), findsNothing);
  });

  testWidgets(
    'shows quick-pick reaction chips at the bottom and reacts on tap',
    (WidgetTester tester) async {
      String? reactedWith;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageActionCard(
              message: buildMessage(),
              senderName: 'Juliet',
              senderJid: 'juliet@example.com',
              recentReactionOptions: const ['👍', '❤️'],
              onReact: (emoji) => reactedWith = emoji,
            ),
          ),
        ),
      );

      expect(find.text('👍'), findsOneWidget);
      expect(find.text('❤️'), findsOneWidget);

      await tester.tap(find.text('❤️'));
      await tester.pump();

      expect(reactedWith, '❤️');
    },
  );

  testWidgets(
    'hides the add-reaction row entirely when onReact is not supplied',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageActionCard(
              message: buildMessage(),
              senderName: 'Juliet',
              senderJid: 'juliet@example.com',
              recentReactionOptions: const ['👍', '❤️'],
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.add_reaction_outlined), findsNothing);
    },
  );

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

  testWidgets('View XML is off by default, showing the message preview', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageActionCard(
            message: ChatMessage(
              from: 'juliet@example.com',
              to: 'romeo@example.com',
              body: 'Wherefore art thou, Romeo?',
              timestamp: DateTime.utc(2026),
              outgoing: false,
              messageId: 'card-test-message',
              rawXml: '<message id="card-test-message"/>',
            ),
            senderName: 'Juliet',
            senderJid: 'juliet@example.com',
          ),
        ),
      ),
    );

    expect(find.text('Wherefore art thou, Romeo?'), findsOneWidget);
    expect(find.text('<message id="card-test-message"/>'), findsNothing);
  });

  testWidgets(
    'toggling View XML on replaces the JID info and message preview with the raw XML',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageActionCard(
              message: ChatMessage(
                from: 'juliet@example.com',
                to: 'romeo@example.com',
                body: 'Wherefore art thou, Romeo?',
                timestamp: DateTime.utc(2026),
                outgoing: false,
                messageId: 'card-test-message',
                rawXml: '<message id="card-test-message"/>',
              ),
              senderName: 'Juliet',
              senderJid: 'juliet@example.com',
              isContact: true,
            ),
          ),
        ),
      );

      await tester.tap(find.text('View XML'));
      await tester.pump();

      expect(find.text('<message id="card-test-message"/>'), findsOneWidget);
      expect(find.text('Wherefore art thou, Romeo?'), findsNothing);
      expect(find.text('juliet@example.com'), findsNothing);
      expect(find.text('Added to contacts'), findsNothing);

      // Toggling it off again restores the original rendering.
      await tester.tap(find.text('View XML'));
      await tester.pump();

      expect(find.text('Wherefore art thou, Romeo?'), findsOneWidget);
      expect(find.text('<message id="card-test-message"/>'), findsNothing);
    },
  );

  testWidgets(
    'View XML pretty-prints nested stanzas and applies syntax highlighting',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageActionCard(
              message: ChatMessage(
                from: 'juliet@example.com',
                to: 'romeo@example.com',
                body: 'Wherefore art thou, Romeo?',
                timestamp: DateTime.utc(2026),
                outgoing: false,
                messageId: 'card-test-message',
                rawXml:
                    '<message id="card-test-message" type="chat"><body>Hi</body></message>',
              ),
              senderName: 'Juliet',
              senderJid: 'juliet@example.com',
            ),
          ),
        ),
      );

      await tester.tap(find.text('View XML'));
      await tester.pump();

      // Pretty-printing should put the nested <body> element on its own,
      // indented line rather than inline with the parent tag.
      expect(find.textContaining('<message'), findsOneWidget);
      expect(find.textContaining('  <body>Hi</body>'), findsOneWidget);

      // Syntax highlighting should render the text as multiple differently
      // styled spans rather than one flat span.
      final selectableText = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      final rootSpan = selectableText.textSpan!;
      expect(rootSpan.children, isNotNull);
      expect(rootSpan.children!.length, greaterThan(1));
    },
  );

  testWidgets('shows a placeholder when no raw XML is cached', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageActionCard(
            message: buildMessage(),
            senderName: 'Juliet',
            senderJid: 'juliet@example.com',
          ),
        ),
      ),
    );

    await tester.tap(find.text('View XML'));
    await tester.pump();

    expect(find.text('No XML cached for this message.'), findsOneWidget);
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
