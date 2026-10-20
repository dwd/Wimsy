import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal self-contained model of the "private PEP node auto-reconfigure on
// precondition-not-met" logic extracted from XmppService._doPrivatePepPublish,
// so the concurrency behaviour can be tested without a real XMPP stack.
//
// The production code lives in xmpp_service.dart:
//   - `_doPrivatePepPublish` sends a publish IQ for a private PEP node (e.g.
//     the XEP-0490 MDS node). If the server replies with
//     `<precondition-not-met/>` (the node's configuration doesn't match our
//     `<publish-options>`), it sends a `pubsub#owner` configure IQ and
//     retries the publish once.
//   - `_replayControlMessageOutbox()` kicks off one such publish per pending
//     chat *concurrently* (via `unawaited`) after every reconnect. Before
//     the `_pepNodeReconfigureInFlight` guard was added, every one of those
//     concurrent publishes independently observed the same
//     precondition-not-met error and sent its own redundant reconfigure IQ —
//     visible in wimsy.log as a burst of a dozen or more "misconfigured;
//     reconfiguring and retrying" warnings on every reconnect.
//   - With the guard, only the first caller to hit precondition-not-met for
//     a given node sends the reconfigure IQ; every other concurrent caller
//     awaits that same in-flight reconfigure before retrying its own
//     publish, so reconfiguration happens at most once per node per
//     misconfiguration episode.
// ---------------------------------------------------------------------------

class _FakePepServer {
  _FakePepServer({required this.misconfiguredNodes});

  final Set<String> misconfiguredNodes;
  int reconfigureCount = 0;
  final List<String> reconfiguredNodes = [];

  /// Simulates a publish IQ round-trip: returns `true` on success, `false`
  /// when the node is currently misconfigured (precondition-not-met).
  Future<bool> publish(String node) async {
    await Future<void>.delayed(Duration.zero);
    return !misconfiguredNodes.contains(node);
  }

  /// Simulates a `pubsub#owner` configure IQ round-trip that fixes the node.
  Future<void> reconfigure(String node) async {
    reconfigureCount++;
    reconfiguredNodes.add(node);
    await Future<void>.delayed(Duration.zero);
    misconfiguredNodes.remove(node);
  }
}

class _PepPublishModel {
  _PepPublishModel(this.server);

  final _FakePepServer server;
  final Map<String, Future<void>> _reconfigureInFlight = {};
  final List<String> publishSucceeded = [];

  /// Mirrors `_doPrivatePepPublish`: publish, and on precondition-not-met,
  /// reconfigure (sharing one in-flight reconfigure per node) then retry once.
  Future<bool> doPrivatePepPublish({
    required String node,
    required String itemId,
  }) async {
    final ok = await server.publish(node);
    if (ok) {
      publishSucceeded.add('$node:$itemId');
      return true;
    }
    final existingReconfigure = _reconfigureInFlight[node];
    if (existingReconfigure != null) {
      await existingReconfigure;
    } else {
      final reconfigure = server.reconfigure(node);
      _reconfigureInFlight[node] = reconfigure;
      try {
        await reconfigure;
      } finally {
        _reconfigureInFlight.remove(node);
      }
    }
    final retryOk = await server.publish(node);
    if (retryOk) {
      publishSucceeded.add('$node:$itemId');
    }
    return retryOk;
  }
}

void main() {
  group('Private PEP node reconfigure guard', () {
    test(
      'a single misconfigured-node publish reconfigures once and succeeds '
      'on retry',
      () async {
        final server = _FakePepServer(misconfiguredNodes: {'urn:xmpp:mds:displayed:0'});
        final model = _PepPublishModel(server);

        final ok = await model.doPrivatePepPublish(
          node: 'urn:xmpp:mds:displayed:0',
          itemId: 'alice@example.com',
        );

        expect(ok, isTrue);
        expect(server.reconfigureCount, 1);
        expect(model.publishSucceeded, ['urn:xmpp:mds:displayed:0:alice@example.com']);
      },
    );

    test(
      'many concurrent publishes to the same misconfigured node share a '
      'single reconfigure instead of each sending their own',
      () async {
        const node = 'urn:xmpp:mds:displayed:0';
        final server = _FakePepServer(misconfiguredNodes: {node});
        final model = _PepPublishModel(server);

        final chats = List.generate(12, (i) => 'chat$i@example.com');
        final results = await Future.wait([
          for (final chat in chats)
            model.doPrivatePepPublish(node: node, itemId: chat),
        ]);

        expect(results, everyElement(isTrue));
        expect(
          server.reconfigureCount,
          1,
          reason:
              'only the first concurrent caller to hit precondition-not-met '
              'should reconfigure the node; the rest must await that same '
              'in-flight reconfigure instead of sending redundant ones',
        );
        expect(model.publishSucceeded.length, chats.length);
      },
    );

    test(
      'publishes to two different misconfigured nodes each get their own '
      'reconfigure',
      () async {
        const nodeA = 'urn:xmpp:mds:displayed:0';
        const nodeB = 'urn:some:other:private:node';
        final server = _FakePepServer(misconfiguredNodes: {nodeA, nodeB});
        final model = _PepPublishModel(server);

        final results = await Future.wait([
          model.doPrivatePepPublish(node: nodeA, itemId: 'a1'),
          model.doPrivatePepPublish(node: nodeA, itemId: 'a2'),
          model.doPrivatePepPublish(node: nodeB, itemId: 'b1'),
          model.doPrivatePepPublish(node: nodeB, itemId: 'b2'),
        ]);

        expect(results, everyElement(isTrue));
        expect(server.reconfigureCount, 2);
        expect(server.reconfiguredNodes.toSet(), {nodeA, nodeB});
      },
    );

    test(
      'a publish to an already-correctly-configured node never reconfigures',
      () async {
        final server = _FakePepServer(misconfiguredNodes: {});
        final model = _PepPublishModel(server);

        final ok = await model.doPrivatePepPublish(
          node: 'urn:xmpp:mds:displayed:0',
          itemId: 'alice@example.com',
        );

        expect(ok, isTrue);
        expect(server.reconfigureCount, 0);
      },
    );
  });
}
