import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/quic_early_data.dart';

void main() {
  test('rejected early data preserves ordered UTF-8 bytes exactly once', () {
    final buffer = QuicEarlyDataBuffer();
    buffer.add('<stream:stream>');
    buffer.add('<authenticate>é</authenticate>');
    expect(
      utf8.decode(buffer.finish(accepted: false)),
      '<stream:stream><authenticate>é</authenticate>',
    );
    expect(buffer.finish(accepted: false), isEmpty);
  });

  test('accepted early data is discarded without replay', () {
    final buffer = QuicEarlyDataBuffer()..add('<authenticate/>');
    expect(buffer.finish(accepted: true), isEmpty);
    expect(buffer.finish(accepted: false), isEmpty);
  });

  test('early flight has a bounded memory footprint', () {
    final buffer = QuicEarlyDataBuffer();
    expect(
      () => buffer.add('x' * (QuicEarlyDataBuffer.maxBytes + 1)),
      throwsStateError,
    );
  });
}
