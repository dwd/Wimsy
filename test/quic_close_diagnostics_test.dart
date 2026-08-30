import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/quic_xmpp_socket.dart';

void main() {
  group('describeQuicCloseAttribution', () {
    test('attributes explicit local and remote closes', () {
      expect(describeQuicCloseAttribution('LocallyClosed'), 'client-initiated');
      expect(
        describeQuicCloseAttribution('ApplicationClosed(0x0)'),
        'server-initiated',
      );
    });

    test('does not claim that a locally observed timeout is server-side', () {
      expect(
        describeQuicCloseAttribution('TimedOut'),
        'client-observed-idle-timeout',
      );
    });

    test('keeps an unobserved stream ending and reset ambiguous', () {
      expect(describeQuicCloseAttribution(null), 'unknown-clean-stream-end');
      expect(describeQuicCloseAttribution('Reset'), 'server-or-network-reset');
    });

    test('distinguishes stream FIN and reset without a connection close', () {
      expect(
        describeQuicCloseAttribution(
          null,
          streamEnd: QuicStreamEndObservation.fin,
        ),
        'control-stream-fin-without-connection-close',
      );
      expect(
        describeQuicCloseAttribution(
          null,
          streamEnd: QuicStreamEndObservation.resetStream,
        ),
        'peer-reset-control-stream',
      );
    });

    test('distinguishes local cancellation and application teardown', () {
      expect(
        describeQuicCloseAttribution(
          null,
          streamEnd: QuicStreamEndObservation.localCancellation,
        ),
        'local-cancellation',
      );
      expect(
        describeQuicCloseAttribution(
          null,
          streamEnd: QuicStreamEndObservation.applicationTeardown,
        ),
        'application-teardown',
      );
    });
  });
}
