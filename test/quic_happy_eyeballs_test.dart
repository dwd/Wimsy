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
}
