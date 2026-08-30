enum ConnectionHealth { healthy, degraded, dead }

/// Coordinates transport and application liveness signals without allowing
/// independent probes to race each other or tear a lossy connection down.
class LivenessController {
  LivenessController({
    required this.onProbeRequested,
    required this.onHealthChanged,
    this.minimumDeadline = const Duration(seconds: 45),
    this.highLossDeadline = const Duration(seconds: 90),
    this.maximumDeadline = const Duration(minutes: 3),
    this.failuresBeforeDead = 2,
    DateTime? now,
  }) : _lastProgressAt = now ?? DateTime.now();

  final void Function() onProbeRequested;
  final void Function(ConnectionHealth health) onHealthChanged;
  final Duration minimumDeadline;
  final Duration highLossDeadline;
  final Duration maximumDeadline;
  final int failuresBeforeDead;

  DateTime _lastProgressAt;
  DateTime? _nextFailureAt;
  Duration _smoothedRtt = Duration.zero;
  double _recentLoss = 0;
  int _consecutiveFailures = 0;
  bool _probeOutstanding = false;
  ConnectionHealth _health = ConnectionHealth.healthy;

  ConnectionHealth get health => _health;
  Duration get currentDeadline => adaptiveLivenessDeadline(
    smoothedRtt: _smoothedRtt,
    recentLoss: _recentLoss,
    minimum: minimumDeadline,
    highLossMinimum: highLossDeadline,
    maximum: maximumDeadline,
  );

  void updateMetrics({required Duration smoothedRtt, required double loss}) {
    _smoothedRtt = smoothedRtt;
    _recentLoss = loss.clamp(0, 1);
  }

  /// Any newly received transport datagram or successful application probe is
  /// forward progress. Local writes and retransmission attempts must not call
  /// this method.
  void observeProgress({DateTime? now}) {
    _lastProgressAt = now ?? DateTime.now();
    _nextFailureAt = null;
    _consecutiveFailures = 0;
    _probeOutstanding = false;
    _setHealth(ConnectionHealth.healthy);
  }

  void checkSilence({DateTime? now}) {
    final current = now ?? DateTime.now();
    final eligibleAt = _nextFailureAt ?? _lastProgressAt.add(currentDeadline);
    if (current.isBefore(eligibleAt) || _health == ConnectionHealth.dead) {
      return;
    }
    reportProbeFailure(now: current);
  }

  void reportProbeFailure({DateTime? now}) {
    if (_health == ConnectionHealth.dead) return;
    final current = now ?? DateTime.now();
    _consecutiveFailures++;
    _probeOutstanding = false;
    if (_consecutiveFailures >= failuresBeforeDead) {
      _setHealth(ConnectionHealth.dead);
      return;
    }
    _setHealth(ConnectionHealth.degraded);
    _nextFailureAt = current.add(currentDeadline);
    _requestProbe();
  }

  void reportDefinitiveClose() => _setHealth(ConnectionHealth.dead);

  void _requestProbe() {
    if (_probeOutstanding || _health == ConnectionHealth.dead) return;
    _probeOutstanding = true;
    onProbeRequested();
  }

  void _setHealth(ConnectionHealth next) {
    if (_health == next) return;
    _health = next;
    onHealthChanged(next);
  }
}

Duration adaptiveLivenessDeadline({
  required Duration smoothedRtt,
  required double recentLoss,
  Duration minimum = const Duration(seconds: 45),
  Duration highLossMinimum = const Duration(seconds: 90),
  Duration maximum = const Duration(minutes: 3),
}) {
  final rttBudget = smoothedRtt * 12;
  var candidate = rttBudget > minimum ? rttBudget : minimum;
  if (recentLoss >= 0.3 && candidate < highLossMinimum) {
    candidate = highLossMinimum;
  }
  return candidate > maximum ? maximum : candidate;
}
