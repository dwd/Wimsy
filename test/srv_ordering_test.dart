import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/srv_ordering.dart';
import 'package:wimsy/xmpp/srv_target.dart';

XmppSrvTarget _record(
  String host, {
  required int priority,
  required int weight,
  required bool directTls,
}) {
  return XmppSrvTarget(
    host: host,
    port: directTls ? 5223 : 5222,
    priority: priority,
    weight: weight,
    directTls: directTls,
  );
}

void main() {
  test('orders by priority ascending', () {
    final ordered = orderXmppSrvTargets([
      _record('p20.example', priority: 20, weight: 10, directTls: false),
      _record('p10.example', priority: 10, weight: 10, directTls: false),
      _record('p30.example', priority: 30, weight: 10, directTls: true),
    ], random: Random(1));

    expect(ordered.map((record) => record.host), [
      'p10.example',
      'p20.example',
      'p30.example',
    ]);
  });

  test('prefers direct TLS records when priority ties', () {
    final ordered = orderXmppSrvTargets([
      _record('starttls-a.example', priority: 10, weight: 10, directTls: false),
      _record('directtls-a.example', priority: 10, weight: 10, directTls: true),
      _record('starttls-b.example', priority: 10, weight: 10, directTls: false),
      _record('directtls-b.example', priority: 10, weight: 10, directTls: true),
    ], random: Random(2));

    expect(ordered.take(2).every((record) => record.directTls), isTrue);
    expect(ordered.skip(2).every((record) => !record.directTls), isTrue);
  });

  test('uses weighted random ordering within a bucket', () {
    final ordered = orderXmppSrvTargets([
      _record('high.example', priority: 10, weight: 100, directTls: true),
      _record('low.example', priority: 10, weight: 1, directTls: true),
    ], random: Random(0));

    expect(ordered.first.host, 'high.example');
    expect(ordered.last.host, 'low.example');
  });

  test('handles zero-weight records', () {
    final ordered = orderXmppSrvTargets([
      _record('zero-a.example', priority: 10, weight: 0, directTls: true),
      _record('zero-b.example', priority: 10, weight: 0, directTls: true),
    ], random: Random(3));

    expect(ordered.map((record) => record.host).toSet(), {
      'zero-a.example',
      'zero-b.example',
    });
  });
}
