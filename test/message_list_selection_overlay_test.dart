// Regression test for a client crash captured in a field log: rendering the
// message list with a `GlobalKey` attached directly to a widget whose
// subtree contains `SelectableText` (which relies on an `OverlayPortal` for
// its selection handles) corrupts Flutter's element tree as soon as the
// sliding message window shifts indices -- which happens on almost every
// newly-arrived message once a chat has more messages than fit in the
// window (see `messageWindow` in `main.dart`). That one failure then
// cascades into a flood of unrelated-looking rendering/semantics assertion
// failures for the rest of the session.
//
// `main.dart`'s message list itemBuilder now keeps the per-message
// `GlobalKey` (used by `_scrollToMessageById` to jump to a reply target) on
// a zero-size sibling marker instead of on the `MessageBubble` itself, so
// the selectable text is never the thing being reparented. This test
// exercises that exact shape -- a `GlobalKey`-keyed zero-size marker next
// to a `SelectableText`-bearing bubble, inside a `ListView.builder` whose
// window slides forward -- and asserts no `FlutterError` is ever reported.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the structure the message list now builds for each row: an
/// unkeyed widget containing `SelectableText` (so it only ever moves via
/// normal index-based updates), plus a zero-size sibling marker that
/// carries the stable per-message `GlobalKey`.
Widget _buildRow(GlobalKey key, String body) {
  return Stack(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: SelectableText.rich(TextSpan(text: body)),
      ),
      Positioned(
        key: key,
        width: 0,
        height: 0,
        child: const SizedBox.shrink(),
      ),
    ],
  );
}

class _SlidingMessageList extends StatefulWidget {
  const _SlidingMessageList({super.key, required this.windowSize});

  final int windowSize;

  @override
  State<_SlidingMessageList> createState() => _SlidingMessageListState();
}

class _SlidingMessageListState extends State<_SlidingMessageList> {
  final List<String> _ids = [];
  final Map<String, GlobalKey> _keysById = {};

  void addMessage() {
    setState(() {
      _ids.add('m${_ids.length}');
    });
  }

  @override
  Widget build(BuildContext context) {
    final start = _ids.length > widget.windowSize
        ? _ids.length - widget.windowSize
        : 0;
    final visible = _ids.sublist(start);
    return MaterialApp(
      home: Scaffold(
        body: ListView.builder(
          itemCount: visible.length,
          itemBuilder: (context, index) {
            final id = visible[index];
            final key = _keysById.putIfAbsent(id, () => GlobalKey());
            return _buildRow(key, 'Message body for $id');
          },
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'keying only a zero-size marker survives a sliding message window '
    'without any FlutterError (GlobalKey never reparents SelectableText)',
    (tester) async {
      final caughtExceptions = <Object>[];

      const windowSize = 5;
      final state = GlobalKey<_SlidingMessageListState>();
      await tester.pumpWidget(
        _SlidingMessageList(key: state, windowSize: windowSize),
      );
      await tester.pump();

      // Push enough messages that the window slides forward repeatedly:
      // every row's index shifts as soon as there are more than
      // `windowSize` messages, which is exactly the scenario that
      // corrupted the element tree in the field log.
      for (var i = 0; i < windowSize * 4; i += 1) {
        state.currentState!.addMessage();
        await tester.pump();
        final exception = tester.takeException();
        if (exception != null) {
          caughtExceptions.add(exception);
        }
      }

      expect(
        caughtExceptions,
        isEmpty,
        reason:
            'Rendering the sliding message window must not raise any '
            'FlutterError (e.g. "mutated during performLayout"); such '
            'failures previously cascaded into thousands of unrelated '
            'rendering/semantics assertion failures for the rest of the '
            'session.',
      );
    },
  );
}
