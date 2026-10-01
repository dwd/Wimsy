import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/widgets/avatar_with_presence.dart';

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: Center(child: child)));
}

void main() {
  testWidgets('renders initial letter when no avatar bytes are provided', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const AvatarWithPresence(label: 'Alice')),
    );

    expect(find.text('A'), findsOneWidget);
    expect(find.byType(CircleAvatar), findsOneWidget);
  });

  testWidgets('falls back to "?" when the label is empty', (tester) async {
    await tester.pumpWidget(_wrap(const AvatarWithPresence(label: '')));

    expect(find.text('?'), findsOneWidget);
  });

  testWidgets('renders an image avatar when bytes are provided', (
    tester,
  ) async {
    // A minimal 1x1 transparent PNG, enough for MemoryImage to decode.
    final bytes = Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);

    await tester.pumpWidget(
      _wrap(AvatarWithPresence(label: 'Alice', bytes: bytes)),
    );

    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    expect(avatar.backgroundImage, isA<MemoryImage>());
    // No placeholder initial should be rendered when an image is shown.
    expect(find.text('A'), findsNothing);
  });

  testWidgets('does not overlay a dot when showPresenceDot is false', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const AvatarWithPresence(key: Key('avatar'), label: 'Alice')),
    );

    expect(
      find.descendant(
        of: find.byKey(const Key('avatar')),
        matching: find.byType(Stack),
      ),
      findsNothing,
    );
  });

  testWidgets('overlays a presence dot when showPresenceDot is true', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const AvatarWithPresence(
          key: Key('avatar'),
          label: 'Alice',
          showPresenceDot: true,
          presenceShow: PresenceShowElement.CHAT,
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const Key('avatar')),
        matching: find.byType(Stack),
      ),
      findsOneWidget,
    );
  });

  testWidgets('overlays a custom badge instead of a presence dot', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AvatarWithPresence(
          label: 'Room',
          badge: const Icon(Icons.meeting_room, key: Key('room-badge')),
        ),
      ),
    );

    expect(find.byKey(const Key('room-badge')), findsOneWidget);
  });
}
