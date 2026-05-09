import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/quic_xmpp_socket.dart';

void main() {
  group('buildQuicHappyEyeballsPlan', () {
    test('interleaves with IPv6 preference when first record is IPv6', () {
      final addresses = <InternetAddress>[
        InternetAddress('2001:db8::1'),
        InternetAddress('2001:db8::2'),
        InternetAddress('192.0.2.1'),
        InternetAddress('192.0.2.2'),
      ];

      final plan = buildQuicHappyEyeballsPlan(addresses);

      expect(
        plan.map((address) => address.address).toList(),
        equals(['2001:db8::1', '192.0.2.1', '2001:db8::2', '192.0.2.2']),
      );
    });

    test('interleaves with IPv4 preference when first record is IPv4', () {
      final addresses = <InternetAddress>[
        InternetAddress('192.0.2.1'),
        InternetAddress('2001:db8::1'),
        InternetAddress('192.0.2.2'),
        InternetAddress('2001:db8::2'),
      ];

      final plan = buildQuicHappyEyeballsPlan(addresses);

      expect(
        plan.map((address) => address.address).toList(),
        equals(['192.0.2.1', '2001:db8::1', '192.0.2.2', '2001:db8::2']),
      );
    });
  });

  group('QuicCapableXmppSocket connect tuning defaults', () {
    test('defaults expose increased timeout and 3 retry attempts', () {
      final socket = QuicCapableXmppSocket();

      // Per-attempt timeout was bumped from 3s to 5s so QUIC handshakes
      // (which can include packet loss + RTT * 2 for the TLS round trip)
      // get a realistic budget on both IPv4 and IPv6.
      expect(socket.quicConnectTimeout, const Duration(seconds: 5));

      // Happy Eyeballs stagger between candidate launches.
      expect(socket.happyEyeballsDelay, const Duration(milliseconds: 250));

      // The whole Happy Eyeballs round is retried up to 3 times before
      // we give up and fall back to TCP.
      expect(socket.quicConnectMaxAttempts, 3);
    });

    test('explicit overrides are honoured', () {
      final socket = QuicCapableXmppSocket(
        quicConnectTimeout: const Duration(seconds: 10),
        happyEyeballsDelay: const Duration(milliseconds: 100),
        quicConnectMaxAttempts: 7,
      );
      expect(socket.quicConnectTimeout, const Duration(seconds: 10));
      expect(socket.happyEyeballsDelay, const Duration(milliseconds: 100));
      expect(socket.quicConnectMaxAttempts, 7);
    });
  });
}
