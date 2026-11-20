import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/widgets/chat_entry_header.dart';

void main() {
  BoxDecoration decorationOf(WidgetTester tester) {
    final container = tester.widget<Container>(find.byType(Container));
    return container.decoration! as BoxDecoration;
  }

  testWidgets(
    'draws the accent bar only on the left by default',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatEntryHeader(
              accentColor: Colors.red,
              header: const Text('Juliet'),
              body: const Text('Hello'),
            ),
          ),
        ),
      );

      final decoration = decorationOf(tester);
      final border = decoration.border! as Border;
      expect(border.left.width, 3);
      expect(border.left.color, Colors.red);
      expect(border.right, BorderSide.none);
    },
  );

  testWidgets(
    'draws a matching accent bar on both sides when accentBothSides is set',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatEntryHeader(
              accentColor: Colors.blue,
              accentBothSides: true,
              header: const Text('Juliet'),
              body: const Text('Hello'),
            ),
          ),
        ),
      );

      final decoration = decorationOf(tester);
      final border = decoration.border! as Border;
      expect(border.left.width, 3);
      expect(border.left.color, Colors.blue);
      expect(border.right.width, 3);
      expect(border.right.color, Colors.blue);
    },
  );
}
