enum ReconnectionPhase {
  idle,
  suspended,
  scheduled,
  reconnecting,
  terminal,
}

enum ReconnectionReason {
  forcefulClose,
  keepaliveTimeout,
  streamError,
  networkChanged,
  manualRequest,
}

class ReconnectionPolicy {
  const ReconnectionPolicy({
    this.baseDelay = const Duration(seconds: 5),
    this.maxDelay = const Duration(minutes: 10),
    this.jitterRatio = 0.25,
    this.unboundedRetries = true,
    this.maxAttempts,
  });

  final Duration baseDelay;
  final Duration maxDelay;
  final double jitterRatio;
  final bool unboundedRetries;
  final int? maxAttempts;
}

class ReconnectionState {
  const ReconnectionState({
    required this.phase,
    this.reason,
    this.attempt = 0,
    this.nextDelay,
    required this.updatedAt,
    this.message,
  });

  final ReconnectionPhase phase;
  final ReconnectionReason? reason;
  final int attempt;
  final Duration? nextDelay;
  final DateTime updatedAt;
  final String? message;
}
