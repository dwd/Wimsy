import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/liveness_controller.dart';

void main() {
  test('deadline expands under extreme loss and is capped', () {
    expect(
      adaptiveLivenessDeadline(
        smoothedRtt: const Duration(milliseconds: 100),
        recentLoss: 0,
      ),
      const Duration(seconds: 45),
    );
    expect(
      adaptiveLivenessDeadline(
        smoothedRtt: const Duration(milliseconds: 100),
        recentLoss: 0.5,
      ),
      const Duration(seconds: 90),
    );
    expect(
      adaptiveLivenessDeadline(
        smoothedRtt: const Duration(seconds: 30),
        recentLoss: 0.5,
      ),
      const Duration(minutes: 3),
    );
  });

  test('requires repeated failures and permits only one probe per window', () {
    final start = DateTime.utc(2026);
    var probes = 0;
    final states = <ConnectionHealth>[];
    final controller = LivenessController(
      now: start,
      onProbeRequested: () => probes++,
      onHealthChanged: states.add,
    );

    controller.checkSilence(now: start.add(const Duration(seconds: 46)));
    controller.checkSilence(now: start.add(const Duration(seconds: 47)));
    expect(controller.health, ConnectionHealth.degraded);
    expect(probes, 1);

    controller.checkSilence(now: start.add(const Duration(seconds: 92)));
    expect(controller.health, ConnectionHealth.degraded);
    expect(probes, 2);

    controller.checkSilence(now: start.add(const Duration(seconds: 138)));
    expect(controller.health, ConnectionHealth.dead);
    expect(states, [ConnectionHealth.degraded, ConnectionHealth.dead]);
  });

  test('forward progress restores health and resets accumulated failures', () {
    final start = DateTime.utc(2026);
    final controller = LivenessController(
      now: start,
      onProbeRequested: () {},
      onHealthChanged: (_) {},
    );
    controller.reportProbeFailure(now: start);
    controller.observeProgress(now: start.add(const Duration(seconds: 1)));
    controller.reportProbeFailure(now: start.add(const Duration(seconds: 50)));

    expect(controller.health, ConnectionHealth.degraded);
  });

  test('definitive transport close bypasses the repeated-failure policy', () {
    final controller = LivenessController(
      onProbeRequested: () {},
      onHealthChanged: (_) {},
    );
    controller.reportDefinitiveClose();
    expect(controller.health, ConnectionHealth.dead);
  });

  test(
    'updateTuning retunes the maximum deadline and failure threshold in place',
    () {
      final start = DateTime.utc(2026);
      final controller = LivenessController(
        now: start,
        onProbeRequested: () {},
        onHealthChanged: (_) {},
        maximumDeadline: const Duration(minutes: 3),
        failuresBeforeDead: 2,
      );
      controller.updateMetrics(
        smoothedRtt: const Duration(seconds: 30),
        loss: 0.5,
      );
      expect(controller.currentDeadline, const Duration(minutes: 3));

      controller.updateTuning(
        maximumDeadline: const Duration(minutes: 10),
        failuresBeforeDead: 3,
      );

      // rttBudget = 30s * 12 = 6 minutes, which is below the new 10-minute
      // ceiling, so the deadline reflects the RTT-derived budget, not the
      // ceiling itself.
      expect(controller.currentDeadline, const Duration(minutes: 6));
      expect(controller.failuresBeforeDead, 3);

      controller.reportProbeFailure(now: start);
      controller.reportProbeFailure(now: start.add(const Duration(seconds: 1)));
      expect(controller.health, ConnectionHealth.degraded);
      controller.reportProbeFailure(now: start.add(const Duration(seconds: 2)));
      expect(controller.health, ConnectionHealth.dead);
    },
  );
}
