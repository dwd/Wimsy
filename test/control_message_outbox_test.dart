import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/control_message_outbox.dart';

ControlMessageOperation _marker(String id) => ControlMessageOperation(
  kind: ControlMessageKind.marker,
  toJid: 'chat@example.com',
  referencedId: id,
  markerName: 'displayed',
);

void main() {
  test('receipts remain distinct while displayed markers coalesce', () {
    final outbox = ControlMessageOutbox(onChanged: (_) {});
    outbox.put(
      const ControlMessageOperation(
        kind: ControlMessageKind.receipt,
        toJid: 'chat@example.com',
        referencedId: 'message-1',
      ),
    );
    outbox.put(
      const ControlMessageOperation(
        kind: ControlMessageKind.receipt,
        toJid: 'chat@example.com',
        referencedId: 'message-2',
      ),
    );
    outbox.put(_marker('old'));
    outbox.put(_marker('new'));

    expect(outbox.pending, hasLength(3));
    expect(
      outbox.pending
          .where((entry) => entry.kind == ControlMessageKind.marker)
          .single
          .referencedId,
      'new',
    );
  });

  test('SM or QUIC stanza acknowledgement removes its operation', () {
    final outbox = ControlMessageOutbox(onChanged: (_) {});
    final operation = _marker('displayed-id');
    outbox.put(operation);
    outbox.correlate('wire-id', operation);

    outbox.acknowledgeStanza('wire-id');

    expect(outbox.pending, isEmpty);
  });

  test('late acknowledgement cannot remove a newer coalesced marker', () {
    final outbox = ControlMessageOutbox(onChanged: (_) {});
    final old = _marker('old');
    outbox.put(old);
    outbox.correlate('old-wire-id', old);
    outbox.put(_marker('new'));

    outbox.acknowledgeStanza('old-wire-id');

    expect(outbox.pending.single.referencedId, 'new');
  });

  test('persisted operations restore without transient stanza correlation', () {
    List<Map<String, dynamic>> stored = [];
    final first = ControlMessageOutbox(
      onChanged: (entries) => stored = entries,
    );
    first.put(
      const ControlMessageOperation(
        kind: ControlMessageKind.mds,
        toJid: 'room@example.com',
        referencedId: 'room-stanza-id',
        byValue: 'room@example.com',
      ),
    );

    final restored = ControlMessageOutbox(onChanged: (_) {});
    restored.restore(stored);

    expect(restored.pending.single.kind, ControlMessageKind.mds);
    expect(restored.pending.single.referencedId, 'room-stanza-id');
  });
}
