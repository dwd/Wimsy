import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/encryption/encryption_manager.dart';
import 'package:wimsy/widgets/encryption_selector.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  testWidgets(
    'unsupported protocols are greyed out but remain tappable/selectable',
    (tester) async {
      EncryptionProtocol? picked;
      await tester.pumpWidget(
        wrap(
          EncryptionSelector(
            selected: EncryptionProtocol.none,
            onSelected: (protocol) => picked = protocol,
            isProtocolSupported: (protocol) =>
                protocol != EncryptionProtocol.omemo2,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('encryption-selector')));
      await tester.pumpAndSettle();

      final omemo2Text = tester.widget<Text>(find.text('OMEMO2'));
      expect(omemo2Text.style?.color, isNotNull);

      final noneText = tester.widget<Text>(find.text('None'));
      expect(noneText.style, isNull);

      await tester.tap(find.text('OMEMO2'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(picked, EncryptionProtocol.omemo2);
    },
  );

  testWidgets('all options render normally when no support callback given', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        EncryptionSelector(
          selected: EncryptionProtocol.none,
          onSelected: (_) {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('encryption-selector')));
    await tester.pumpAndSettle();

    final omemo2Text = tester.widget<Text>(find.text('OMEMO2'));
    expect(omemo2Text.style, isNull);
  });
}
