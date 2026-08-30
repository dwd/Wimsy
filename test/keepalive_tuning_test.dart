import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/keepalive_tuning.dart';

void main() {
  group('KeepaliveTuning', () {
    test('defaults reproduce the historical hard-coded values', () {
      const d = KeepaliveTuning.defaults;
      expect(d.smAckIntervalForeground, const Duration(minutes: 1));
      expect(d.smAckIntervalBackground, const Duration(minutes: 5));
      expect(d.pingIntervalForeground, const Duration(seconds: 30));
      expect(d.pingIntervalBackground, const Duration(minutes: 5));
      expect(d.pendingAckRequestDelay, const Duration(seconds: 15));
      expect(d.keepaliveMaxTimeout, const Duration(seconds: 90));
      expect(d.mucSelfPingIdle, const Duration(minutes: 10));
      expect(d.mucSelfPingCheckInterval, const Duration(minutes: 1));
      expect(d.mucSelfPingTimeout, const Duration(seconds: 30));
      expect(d.csiIdleDelay, const Duration(minutes: 1));
      expect(d.connectRetryDelay, const Duration(minutes: 1));
      expect(d.reconnectBaseDelay, const Duration(seconds: 5));
      expect(d.reconnectMaxDelay, const Duration(minutes: 10));
      expect(d.reconnectJitterRatio, 0.25);
      expect(d.quicPingIntervalDefault, const Duration(minutes: 5));
      expect(d.quicPingIntervalMinFloor, const Duration(seconds: 10));
      expect(d.outgoingCallTimeout, const Duration(seconds: 45));
      expect(d.incomingCallTimeout, const Duration(seconds: 60));
      expect(d.callStatsInterval, const Duration(seconds: 5));
    });

    test('copyWith overrides only the specified fields', () {
      const d = KeepaliveTuning.defaults;
      final updated = d.copyWith(
        smAckIntervalForeground: const Duration(seconds: 5),
        reconnectJitterRatio: 0.1,
      );

      expect(updated.smAckIntervalForeground, const Duration(seconds: 5));
      expect(updated.reconnectJitterRatio, 0.1);
      // Everything else is unchanged.
      expect(updated.smAckIntervalBackground, d.smAckIntervalBackground);
      expect(updated.pingIntervalForeground, d.pingIntervalForeground);
      expect(updated.keepaliveMaxTimeout, d.keepaliveMaxTimeout);
    });

    test('copyWith with no arguments returns an equal instance', () {
      const d = KeepaliveTuning.defaults;
      final copy = d.copyWith();
      expect(copy, d);
    });

    test('equality and hashCode are value-based', () {
      const a = KeepaliveTuning.defaults;
      final b = KeepaliveTuning.defaults.copyWith();
      final c = KeepaliveTuning.defaults.copyWith(
        outgoingCallTimeout: const Duration(seconds: 1),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });
  });
}
