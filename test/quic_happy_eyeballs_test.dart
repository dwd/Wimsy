import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';
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
    test(
      'defaults expose increased timeout, 3 retry attempts, and 3 parallel attempts',
      () {
        final socket = QuicCapableXmppSocket();

        // Per-attempt timeout is 15s so QUIC handshakes on high-loss paths
        // (where multiple Initial packets may be dropped before one gets
        // through) have a realistic budget.
        expect(socket.quicConnectTimeout, const Duration(seconds: 15));

        // Happy Eyeballs stagger between candidate launches.
        expect(socket.happyEyeballsDelay, const Duration(milliseconds: 250));

        // The whole Happy Eyeballs round is retried up to 3 times before
        // we give up and fall back to TCP.
        expect(socket.quicConnectMaxAttempts, 3);

        // Each candidate address is attempted 3 times in parallel (staggered
        // by happyEyeballsDelay) so that multiple QUIC Initial packets are
        // in-flight simultaneously on lossy paths.
        expect(socket.quicConnectParallelAttempts, 3);
      },
    );

    test('explicit overrides are honoured', () {
      final socket = QuicCapableXmppSocket(
        quicConnectTimeout: const Duration(seconds: 10),
        happyEyeballsDelay: const Duration(milliseconds: 100),
        quicConnectMaxAttempts: 7,
        quicConnectParallelAttempts: 5,
      );
      expect(socket.quicConnectTimeout, const Duration(seconds: 10));
      expect(socket.happyEyeballsDelay, const Duration(milliseconds: 100));
      expect(socket.quicConnectMaxAttempts, 7);
      expect(socket.quicConnectParallelAttempts, 5);
    });
  });

  group('QUIC connection generations', () {
    test('new generations supersede all earlier async work', () {
      final socket = QuicCapableXmppSocket();

      final first = socket.beginConnectionGenerationForTesting();
      final second = socket.beginConnectionGenerationForTesting();

      expect(second, first + 1);
      expect(socket.isConnectionGenerationCurrentForTesting(first), isFalse);
      expect(socket.isConnectionGenerationCurrentForTesting(second), isTrue);

      socket.close();
      expect(socket.isConnectionGenerationCurrentForTesting(second), isFalse);
    });
  });

  group('buildQuicHappyEyeballsPlan parallel schedule', () {
    test('single candidate repeated parallelAttempts times', () {
      // With 1 candidate and parallelAttempts=3 the schedule should be
      // [A, A, A] — three staggered attempts to the same address.
      final addresses = [InternetAddress('192.0.2.1')];
      final plan = buildQuicHappyEyeballsPlan(addresses);
      // The plan itself is just the address ordering; the repetition is
      // applied inside _raceQuicCandidates. Verify the plan is correct.
      expect(plan.map((a) => a.address).toList(), equals(['192.0.2.1']));
    });

    test('two candidates interleaved across repetitions', () {
      // With candidates [A, B] and parallelAttempts=3 the expanded schedule
      // built inside _raceQuicCandidates is [A, B, A, B, A, B].
      // We verify buildQuicHappyEyeballsPlan returns [A, B] so the caller
      // can expand it correctly.
      final addresses = [
        InternetAddress('192.0.2.1'),
        InternetAddress('2001:db8::1'),
      ];
      final plan = buildQuicHappyEyeballsPlan(addresses);
      // IPv4-first because first address is IPv4.
      expect(
        plan.map((a) => a.address).toList(),
        equals(['192.0.2.1', '2001:db8::1']),
      );
    });
  });
}
