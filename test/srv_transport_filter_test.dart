import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/srv_target.dart';

XmppSrvTarget _target({required bool directTls, String host = 'h', int port = 0}) {
  return XmppSrvTarget(
    host: host,
    port: port,
    priority: 0,
    weight: 1,
    directTls: directTls,
  );
}

void main() {
  group('filterTcpSrvCandidatesByTransport', () {
    final directTls = _target(directTls: true, host: 'tls.example.org', port: 5223);
    final plainTcp = _target(directTls: false, host: 'tcp.example.org', port: 5222);
    final candidates = <XmppSrvTarget>[directTls, plainTcp];

    test('keeps both when both flags are on', () {
      final result = filterTcpSrvCandidatesByTransport(
        candidates,
        allowDirectTls: true,
        allowPlainTcp: true,
      );
      expect(result, equals(candidates));
    });

    test('drops plain-TCP records when plain TCP is off', () {
      final result = filterTcpSrvCandidatesByTransport(
        candidates,
        allowDirectTls: true,
        allowPlainTcp: false,
      );
      expect(result.map((c) => c.host).toList(), equals(['tls.example.org']));
    });

    test('drops Direct TLS records when Direct TLS is off', () {
      final result = filterTcpSrvCandidatesByTransport(
        candidates,
        allowDirectTls: false,
        allowPlainTcp: true,
      );
      expect(result.map((c) => c.host).toList(), equals(['tcp.example.org']));
    });

    test('returns empty when both flags are off', () {
      final result = filterTcpSrvCandidatesByTransport(
        candidates,
        allowDirectTls: false,
        allowPlainTcp: false,
      );
      expect(result, isEmpty);
    });

    test('preserves original order within each transport bucket', () {
      // Two plain-TCP records ordered by priority should keep that order.
      final first = _target(directTls: false, host: 'one', port: 5222);
      final second = _target(directTls: false, host: 'two', port: 5222);
      final result = filterTcpSrvCandidatesByTransport(
        <XmppSrvTarget>[first, second],
        allowDirectTls: false,
        allowPlainTcp: true,
      );
      expect(result.map((c) => c.host).toList(), equals(['one', 'two']));
    });
  });
}
