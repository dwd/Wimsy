import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/quic_endpoint_plan.dart';
import 'package:wimsy/xmpp/srv_target.dart';

void main() {
  test('builds QUIC endpoints from SRV candidates in provided order', () {
    final endpoints = buildQuicEndpointPlan(
      domain: 'example.com',
      srvCandidates: [
        XmppSrvTarget(
          host: 'quic1.example.com',
          port: 443,
          priority: 10,
          weight: 20,
          directTls: false,
        ),
        XmppSrvTarget(
          host: 'quic2.example.com',
          port: 4433,
          priority: 20,
          weight: 5,
          directTls: false,
        ),
      ],
    );

    expect(endpoints, hasLength(2));
    expect(endpoints[0].host, 'quic1.example.com');
    expect(endpoints[0].port, 443);
    expect(endpoints[0].tlsHost, 'example.com');
    expect(endpoints[1].host, 'quic2.example.com');
    expect(endpoints[1].port, 4433);
  });

  test('returns empty list when no QUIC SRV candidates are available', () {
    final endpoints = buildQuicEndpointPlan(
      domain: 'example.com',
      srvCandidates: const <XmppSrvTarget>[],
    );
    expect(endpoints, isEmpty);
  });
}
