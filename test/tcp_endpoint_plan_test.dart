import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/srv_target.dart';
import 'package:wimsy/xmpp/tcp_endpoint_plan.dart';

void main() {
  test('builds endpoints from SRV candidates in provided order', () {
    final endpoints = buildTcpEndpointPlan(
      domain: 'example.com',
      resolvedHost: '',
      resolvedPort: 5222,
      directTls: false,
      srvCandidates: [
        XmppSrvTarget(
          host: 'srv1.example.com',
          port: 5223,
          priority: 10,
          weight: 10,
          directTls: true,
        ),
        XmppSrvTarget(
          host: 'srv2.example.com',
          port: 5222,
          priority: 10,
          weight: 5,
          directTls: false,
        ),
      ],
    );

    expect(endpoints.length, 2);
    expect(endpoints[0].host, 'srv1.example.com');
    expect(endpoints[0].directTls, isTrue);
    expect(endpoints[0].tlsHost, 'example.com');
    expect(endpoints[1].host, 'srv2.example.com');
    expect(endpoints[1].directTls, isFalse);
  });

  test('falls back to resolved host when no SRV candidates', () {
    final endpoints = buildTcpEndpointPlan(
      domain: 'example.com',
      resolvedHost: 'manual.example.com',
      resolvedPort: 5225,
      directTls: true,
    );

    expect(endpoints.length, 1);
    expect(endpoints.single.host, 'manual.example.com');
    expect(endpoints.single.port, 5225);
    expect(endpoints.single.directTls, isTrue);
    expect(endpoints.single.tlsHost, 'example.com');
  });

  test('falls back to domain when host is empty and no SRV candidates', () {
    final endpoints = buildTcpEndpointPlan(
      domain: 'example.com',
      resolvedHost: '',
      resolvedPort: 5222,
      directTls: false,
    );

    expect(endpoints.length, 1);
    expect(endpoints.single.host, 'example.com');
    expect(endpoints.single.directTls, isFalse);
    expect(endpoints.single.port, 5222);
  });
}
