import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/keepalive_tuning.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

void main() {
  group('XmppService.applyKeepaliveTuning', () {
    test('service starts with KeepaliveTuning.defaults', () {
      final service = XmppService();
      expect(service.keepaliveTuning, KeepaliveTuning.defaults);
    });

    test('applyKeepaliveTuning updates keepaliveTuning without a live connection', () {
      final service = XmppService();
      final custom = KeepaliveTuning.defaults.copyWith(
        pingIntervalForeground: const Duration(seconds: 8),
        mucSelfPingIdle: const Duration(minutes: 2),
      );

      // No connection has been established, so this must not throw even
      // though it would normally also push the config down to the
      // underlying Stream Management module.
      service.applyKeepaliveTuning(custom);

      expect(service.keepaliveTuning, custom);
      expect(
        service.keepaliveTuning.pingIntervalForeground,
        const Duration(seconds: 8),
      );
      expect(
        service.keepaliveTuning.mucSelfPingIdle,
        const Duration(minutes: 2),
      );
    });

    test('applyKeepaliveTuning notifies listeners', () {
      final service = XmppService();
      var notified = false;
      service.addListener(() => notified = true);

      service.applyKeepaliveTuning(
        KeepaliveTuning.defaults.copyWith(
          callStatsInterval: const Duration(seconds: 1),
        ),
      );

      expect(notified, isTrue);
    });
  });
}
