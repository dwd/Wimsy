import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/call_ice.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

JingleIceCandidate _candidate({required String ip, String type = 'host'}) {
  return JingleIceCandidate(
    foundation: '1',
    component: 1,
    protocol: 'udp',
    priority: 2122260223,
    ip: ip,
    port: 12345,
    type: type,
  );
}

void main() {
  group('isLikelyVirtualBridgeCandidate', () {
    test('flags Docker default/custom bridge addresses', () {
      expect(
        isLikelyVirtualBridgeCandidate(_candidate(ip: '172.17.0.1')),
        isTrue,
      );
      expect(
        isLikelyVirtualBridgeCandidate(_candidate(ip: '172.18.0.1')),
        isTrue,
      );
      expect(
        isLikelyVirtualBridgeCandidate(_candidate(ip: '172.31.255.254')),
        isTrue,
      );
    });

    test('flags libvirt default/secondary NAT network addresses', () {
      expect(
        isLikelyVirtualBridgeCandidate(_candidate(ip: '192.168.122.1')),
        isTrue,
      );
      expect(
        isLikelyVirtualBridgeCandidate(_candidate(ip: '192.168.123.1')),
        isTrue,
      );
    });

    test('does not flag ordinary LAN or public addresses', () {
      expect(
        isLikelyVirtualBridgeCandidate(_candidate(ip: '10.42.211.7')),
        isFalse,
      );
      expect(
        isLikelyVirtualBridgeCandidate(_candidate(ip: '192.168.1.42')),
        isFalse,
      );
      expect(
        isLikelyVirtualBridgeCandidate(_candidate(ip: '88.98.37.178')),
        isFalse,
      );
    });

    test('does not flag addresses just outside the ranges', () {
      // Just below Docker's 172.16.0.0/12 range.
      expect(
        isLikelyVirtualBridgeCandidate(_candidate(ip: '172.15.255.255')),
        isFalse,
      );
      // Just above Docker's 172.16.0.0/12 range.
      expect(
        isLikelyVirtualBridgeCandidate(_candidate(ip: '172.32.0.0')),
        isFalse,
      );
      // Different /24 than libvirt's default NAT network.
      expect(
        isLikelyVirtualBridgeCandidate(_candidate(ip: '192.168.124.1')),
        isFalse,
      );
    });

    test('only considers host candidates, not srflx/relay', () {
      expect(
        isLikelyVirtualBridgeCandidate(
          _candidate(ip: '172.18.0.1', type: 'srflx'),
        ),
        isFalse,
      );
      expect(
        isLikelyVirtualBridgeCandidate(
          _candidate(ip: '172.18.0.1', type: 'relay'),
        ),
        isFalse,
      );
    });
  });
}
