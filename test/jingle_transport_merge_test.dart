import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/call_ice.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('mergeIceTransports preserves fingerprint and merges candidates', () {
    const fingerprint = JingleDtlsFingerprint(
      hash: 'sha-256',
      fingerprint: 'AA:BB:CC',
      setup: 'actpass',
    );
    const existing = JingleIceTransport(
      ufrag: 'oldUfrag',
      password: 'oldPwd',
      candidates: [
        JingleIceCandidate(
          foundation: '1',
          component: 1,
          protocol: 'udp',
          priority: 100,
          ip: '10.0.0.1',
          port: 5000,
          type: 'host',
          generation: 0,
        ),
      ],
      fingerprint: fingerprint,
    );
    const update = JingleIceTransport(
      ufrag: '',
      password: '',
      candidates: [
        JingleIceCandidate(
          foundation: '2',
          component: 2,
          protocol: 'udp',
          priority: 200,
          ip: '10.0.0.2',
          port: 6000,
          type: 'host',
          generation: 0,
        ),
      ],
    );

    final merged = mergeIceTransports(existing, update);

    expect(merged.ufrag, 'oldUfrag');
    expect(merged.password, 'oldPwd');
    expect(merged.fingerprint, fingerprint);
    expect(merged.candidates.length, 2);
    expect(merged.candidates.first.foundation, '2');
    expect(merged.candidates.last.foundation, '1');
  });

  test('transportInfoTransport strips fingerprint and keeps credentials', () {
    const fingerprint = JingleDtlsFingerprint(
      hash: 'sha-256',
      fingerprint: '11:22:33',
    );
    const base = JingleIceTransport(
      ufrag: 'uf',
      password: 'pw',
      candidates: [],
      fingerprint: fingerprint,
    );
    const candidate = JingleIceCandidate(
      foundation: '1',
      component: 1,
      protocol: 'udp',
      priority: 100,
      ip: '10.0.0.3',
      port: 7000,
      type: 'host',
    );

    final transport = transportInfoTransport(base, candidate);

    expect(transport.ufrag, 'uf');
    expect(transport.password, 'pw');
    expect(transport.fingerprint, isNull);
    expect(transport.candidates, [candidate]);
  });

  test(
    'parseIceCandidate parses candidate line and buildCandidateLine round-trips',
    () {
      const line =
          'candidate:1 1 udp 2122260223 192.168.1.10 54545 typ host generation 0';

      final parsed = parseIceCandidate(line);

      expect(parsed, isNotNull);
      expect(parsed!.foundation, '1');
      expect(parsed.component, 1);
      expect(parsed.protocol, 'udp');
      expect(parsed.priority, 2122260223);
      expect(parsed.ip, '192.168.1.10');
      expect(parsed.port, 54545);
      expect(parsed.type, 'host');
      expect(
        buildCandidateLine(parsed),
        'candidate:1 1 udp 2122260223 192.168.1.10 54545 typ host',
      );
    },
  );

  test('parseIceCandidate returns null for malformed input', () {
    expect(parseIceCandidate('candidate:bad line'), isNull);
    expect(parseIceCandidate(null), isNull);
  });
}
