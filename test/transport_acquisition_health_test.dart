import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

void main() {
  test('repeated TCP wins lengthen but do not disable the QUIC head start', () {
    final health = TransportAcquisitionHealth();
    expect(health.quicHeadStart, const Duration(seconds: 12));

    health
      ..recordWinner(false)
      ..recordWinner(false);

    expect(health.quicHeadStart, const Duration(seconds: 15));
    health.recordWinner(true);
    expect(health.quicHeadStart, const Duration(seconds: 15));
  });
}
