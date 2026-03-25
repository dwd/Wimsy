/// Snapshot of connection keepalive health exposed to higher-level clients.
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

  /// True when the most recent probe outcome is considered healthy.
  final bool healthy;

  /// True when Stream Management (XEP-0198) keepalive is active.
  final bool smEnabled;

  /// True when the app requested background keepalive cadence.
  final bool backgroundMode;

  /// True while waiting for an `<a/>` response to a pending `<r/>` request.
  final bool awaitingSmAck;

  /// True while waiting for an IQ response to a pending XEP-0199 ping.
  final bool awaitingPing;

  /// Most recent successful probe latency, if known.
  final Duration? lastLatency;

  /// Timestamp of the most recent successful probe.
  final DateTime? lastSuccessAt;

  /// Timestamp of the most recent probe failure.
  final DateTime? lastFailureAt;
}

/// Keepalive failure categories emitted by [KeepaliveFailure].
enum KeepaliveFailureReason { smAckTimeout, pingTimeout }

/// A keepalive probe failure event.
class KeepaliveFailure {
  const KeepaliveFailure({
    required this.reason,
    required this.shortTimeout,
    required this.occurredAt,
  });

  /// Failure category for the probe.
  final KeepaliveFailureReason reason;

  /// Whether the probe used short timeout mode.
  final bool shortTimeout;

  /// Timestamp when the failure was detected.
  final DateTime occurredAt;
}
