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

    test('keeps ambiguous stream endings and resets ambiguous', () {
      expect(describeQuicCloseAttribution(null), 'unknown-clean-stream-end');
      expect(describeQuicCloseAttribution('Reset'), 'server-or-network-reset');
    });
  });
}
