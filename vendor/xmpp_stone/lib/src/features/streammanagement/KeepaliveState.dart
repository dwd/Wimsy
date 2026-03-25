class KeepaliveState {
  const KeepaliveState({
    required this.healthy,
    required this.smEnabled,
    required this.backgroundMode,
    required this.awaitingSmAck,
    required this.awaitingPing,
    required this.lastLatency,
    this.lastSuccessAt,
    this.lastFailureAt,
  });

  final bool healthy;
  final bool smEnabled;
  final bool backgroundMode;
  final bool awaitingSmAck;
  final bool awaitingPing;
  final Duration? lastLatency;
  final DateTime? lastSuccessAt;
  final DateTime? lastFailureAt;
}

enum KeepaliveFailureReason { smAckTimeout, pingTimeout }

class KeepaliveFailure {
  const KeepaliveFailure({
    required this.reason,
    required this.shortTimeout,
    required this.occurredAt,
  });

  final KeepaliveFailureReason reason;
  final bool shortTimeout;
  final DateTime occurredAt;
}
