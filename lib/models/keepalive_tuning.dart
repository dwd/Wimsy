/// Tunable keepalive/ping/reconnect timers used across the XMPP client.
///
/// The client has several independent timers that all serve a similar
/// purpose — detecting a dead connection quickly while not wasting battery
/// or bandwidth on chatty background traffic. Historically these lived as
/// hard-coded constants scattered across `StreamManagementModule`,
/// `ReconnectionManager`, `XmppService`, and the QUIC socket. This class
/// collects every one of them into a single, user-adjustable configuration
/// object that can be surfaced in a settings/control panel and persisted.
///
/// All durations default to the values that were previously hard-coded, so
/// constructing [KeepaliveTuning.defaults] reproduces the historical
/// behaviour exactly.
class KeepaliveTuning {
  const KeepaliveTuning({
    required this.smAckIntervalForeground,
    required this.smAckIntervalBackground,
    required this.pingIntervalForeground,
    required this.pingIntervalBackground,
    required this.pendingAckRequestDelay,
    required this.keepaliveMaxTimeout,
    required this.mucSelfPingIdle,
    required this.mucSelfPingCheckInterval,
    required this.mucSelfPingTimeout,
    required this.csiIdleDelay,
    required this.connectRetryDelay,
    required this.reconnectBaseDelay,
    required this.reconnectMaxDelay,
    required this.reconnectJitterRatio,
    required this.quicPingIntervalDefault,
    required this.quicPingIntervalMinFloor,
    required this.outgoingCallTimeout,
    required this.incomingCallTimeout,
    required this.callStatsInterval,
  });

  /// XEP-0198 Stream Management `<r/>` request cadence while the app is in
  /// the foreground.
  final Duration smAckIntervalForeground;

  /// XEP-0198 Stream Management `<r/>` request cadence while the app is in
  /// the background.
  final Duration smAckIntervalBackground;

  /// XEP-0199 XMPP Ping cadence (used when Stream Management is not
  /// available) while the app is in the foreground.
  final Duration pingIntervalForeground;

  /// XEP-0199 XMPP Ping cadence while the app is in the background.
  final Duration pingIntervalBackground;

  /// How long to wait for outstanding stanzas to be acked before requesting
  /// an ack proactively.
  final Duration pendingAckRequestDelay;

  /// Upper bound applied to the latency-derived keepalive timeout, so a
  /// single slow probe can't leave the client waiting indefinitely.
  final Duration keepaliveMaxTimeout;

  /// How long a MUC must be idle (no traffic) before we start self-pinging
  /// it to confirm we're still joined.
  final Duration mucSelfPingIdle;

  /// How often the idle-MUC self-ping sweep runs.
  final Duration mucSelfPingCheckInterval;

  /// How long to wait for a MUC self-ping response before treating the room
  /// as possibly left.
  final Duration mucSelfPingTimeout;

  /// Delay before sending Client State Indication (XEP-0352) `<inactive/>`
  /// after the app goes to the background.
  final Duration csiIdleDelay;

  /// Delay before automatically retrying a fully failed initial connection
  /// attempt.
  final Duration connectRetryDelay;

  /// Base delay for the first reconnection attempt (exponential backoff
  /// grows from here).
  final Duration reconnectBaseDelay;

  /// Upper bound on the reconnection backoff delay.
  final Duration reconnectMaxDelay;

  /// Fraction of the computed backoff delay used as random jitter, in the
  /// range `[0, 1]`.
  final double reconnectJitterRatio;

  /// Default QUIC transport-level PING interval used when neither the QUIC
  /// idle timeout nor the XMPP stream idle timeout is known.
  final Duration quicPingIntervalDefault;

  /// Minimum QUIC PING interval floor, to avoid excessive traffic when the
  /// negotiated idle timeout is very short.
  final Duration quicPingIntervalMinFloor;

  /// How long an outgoing A/V call may ring before it's treated as
  /// unanswered.
  final Duration outgoingCallTimeout;

  /// How long an incoming A/V call may ring before it's treated as missed.
  final Duration incomingCallTimeout;

  /// How often call quality statistics are sampled during an active call.
  final Duration callStatsInterval;

  /// The historical hard-coded values, reproduced exactly.
  static const KeepaliveTuning defaults = KeepaliveTuning(
    smAckIntervalForeground: Duration(minutes: 1),
    smAckIntervalBackground: Duration(minutes: 5),
    pingIntervalForeground: Duration(seconds: 30),
    pingIntervalBackground: Duration(minutes: 5),
    pendingAckRequestDelay: Duration(seconds: 15),
    keepaliveMaxTimeout: Duration(seconds: 90),
    mucSelfPingIdle: Duration(minutes: 10),
    mucSelfPingCheckInterval: Duration(minutes: 1),
    mucSelfPingTimeout: Duration(seconds: 30),
    csiIdleDelay: Duration(minutes: 1),
    connectRetryDelay: Duration(minutes: 1),
    reconnectBaseDelay: Duration(seconds: 5),
    reconnectMaxDelay: Duration(minutes: 10),
    reconnectJitterRatio: 0.25,
    quicPingIntervalDefault: Duration(minutes: 5),
    quicPingIntervalMinFloor: Duration(seconds: 10),
    outgoingCallTimeout: Duration(seconds: 45),
    incomingCallTimeout: Duration(seconds: 60),
    callStatsInterval: Duration(seconds: 5),
  );

  KeepaliveTuning copyWith({
    Duration? smAckIntervalForeground,
    Duration? smAckIntervalBackground,
    Duration? pingIntervalForeground,
    Duration? pingIntervalBackground,
    Duration? pendingAckRequestDelay,
    Duration? keepaliveMaxTimeout,
    Duration? mucSelfPingIdle,
    Duration? mucSelfPingCheckInterval,
    Duration? mucSelfPingTimeout,
    Duration? csiIdleDelay,
    Duration? connectRetryDelay,
    Duration? reconnectBaseDelay,
    Duration? reconnectMaxDelay,
    double? reconnectJitterRatio,
    Duration? quicPingIntervalDefault,
    Duration? quicPingIntervalMinFloor,
    Duration? outgoingCallTimeout,
    Duration? incomingCallTimeout,
    Duration? callStatsInterval,
  }) {
    return KeepaliveTuning(
      smAckIntervalForeground:
          smAckIntervalForeground ?? this.smAckIntervalForeground,
      smAckIntervalBackground:
          smAckIntervalBackground ?? this.smAckIntervalBackground,
      pingIntervalForeground:
          pingIntervalForeground ?? this.pingIntervalForeground,
      pingIntervalBackground:
          pingIntervalBackground ?? this.pingIntervalBackground,
      pendingAckRequestDelay:
          pendingAckRequestDelay ?? this.pendingAckRequestDelay,
      keepaliveMaxTimeout: keepaliveMaxTimeout ?? this.keepaliveMaxTimeout,
      mucSelfPingIdle: mucSelfPingIdle ?? this.mucSelfPingIdle,
      mucSelfPingCheckInterval:
          mucSelfPingCheckInterval ?? this.mucSelfPingCheckInterval,
      mucSelfPingTimeout: mucSelfPingTimeout ?? this.mucSelfPingTimeout,
      csiIdleDelay: csiIdleDelay ?? this.csiIdleDelay,
      connectRetryDelay: connectRetryDelay ?? this.connectRetryDelay,
      reconnectBaseDelay: reconnectBaseDelay ?? this.reconnectBaseDelay,
      reconnectMaxDelay: reconnectMaxDelay ?? this.reconnectMaxDelay,
      reconnectJitterRatio: reconnectJitterRatio ?? this.reconnectJitterRatio,
      quicPingIntervalDefault:
          quicPingIntervalDefault ?? this.quicPingIntervalDefault,
      quicPingIntervalMinFloor:
          quicPingIntervalMinFloor ?? this.quicPingIntervalMinFloor,
      outgoingCallTimeout: outgoingCallTimeout ?? this.outgoingCallTimeout,
      incomingCallTimeout: incomingCallTimeout ?? this.incomingCallTimeout,
      callStatsInterval: callStatsInterval ?? this.callStatsInterval,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is KeepaliveTuning &&
        other.smAckIntervalForeground == smAckIntervalForeground &&
        other.smAckIntervalBackground == smAckIntervalBackground &&
        other.pingIntervalForeground == pingIntervalForeground &&
        other.pingIntervalBackground == pingIntervalBackground &&
        other.pendingAckRequestDelay == pendingAckRequestDelay &&
        other.keepaliveMaxTimeout == keepaliveMaxTimeout &&
        other.mucSelfPingIdle == mucSelfPingIdle &&
        other.mucSelfPingCheckInterval == mucSelfPingCheckInterval &&
        other.mucSelfPingTimeout == mucSelfPingTimeout &&
        other.csiIdleDelay == csiIdleDelay &&
        other.connectRetryDelay == connectRetryDelay &&
        other.reconnectBaseDelay == reconnectBaseDelay &&
        other.reconnectMaxDelay == reconnectMaxDelay &&
        other.reconnectJitterRatio == reconnectJitterRatio &&
        other.quicPingIntervalDefault == quicPingIntervalDefault &&
        other.quicPingIntervalMinFloor == quicPingIntervalMinFloor &&
        other.outgoingCallTimeout == outgoingCallTimeout &&
        other.incomingCallTimeout == incomingCallTimeout &&
        other.callStatsInterval == callStatsInterval;
  }

  @override
  int get hashCode => Object.hashAll([
    smAckIntervalForeground,
    smAckIntervalBackground,
    pingIntervalForeground,
    pingIntervalBackground,
    pendingAckRequestDelay,
    keepaliveMaxTimeout,
    mucSelfPingIdle,
    mucSelfPingCheckInterval,
    mucSelfPingTimeout,
    csiIdleDelay,
    connectRetryDelay,
    reconnectBaseDelay,
    reconnectMaxDelay,
    reconnectJitterRatio,
    quicPingIntervalDefault,
    quicPingIntervalMinFloor,
    outgoingCallTimeout,
    incomingCallTimeout,
    callStatsInterval,
  ]);
}
