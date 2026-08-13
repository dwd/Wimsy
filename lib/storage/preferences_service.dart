import 'package:shared_preferences/shared_preferences.dart';

import '../models/keepalive_tuning.dart';

/// Centralises all [SharedPreferences] access for Wimsy.
///
/// Construct once at app startup via [PreferencesService.load] and pass the
/// instance down to widgets that need it.  All preference key strings live
/// here so there is a single source of truth.
class PreferencesService {
  PreferencesService._(this._prefs);

  /// Loads [SharedPreferences] and returns a ready-to-use [PreferencesService].
  static Future<PreferencesService> load() async {
    final prefs = await SharedPreferences.getInstance();
    return PreferencesService._(prefs);
  }

  final SharedPreferences _prefs;

  // ── Key constants ──────────────────────────────────────────────────────────

  static const _sentryOptInKey = 'sentry_opt_in';
  static const _pinIgnoredKey = 'wimsy_pin_ignored';
  static const _lastJidKey = 'wimsy_last_jid';
  static const _audioInputKey = 'wimsy_audio_input';
  static const _videoInputKey = 'wimsy_video_input';

  // ── Sentry opt-in ──────────────────────────────────────────────────────────

  bool get sentryOptIn => _prefs.getBool(_sentryOptInKey) ?? false;

  Future<void> setSentryOptIn(bool value) =>
      _prefs.setBool(_sentryOptInKey, value);

  // ── PIN screen ─────────────────────────────────────────────────────────────

  bool get pinIgnored => _prefs.getBool(_pinIgnoredKey) ?? false;

  Future<void> setPinIgnored(bool value) =>
      _prefs.setBool(_pinIgnoredKey, value);

  // ── Last signed-in JID ─────────────────────────────────────────────────────

  String? get lastJid => _prefs.getString(_lastJidKey);

  Future<void> setLastJid(String jid) => _prefs.setString(_lastJidKey, jid);

  // ── Media device preferences ───────────────────────────────────────────────

  String? get audioInputId => _prefs.getString(_audioInputKey);

  Future<void> setAudioInputId(String deviceId) =>
      _prefs.setString(_audioInputKey, deviceId);

  String? get videoInputId => _prefs.getString(_videoInputKey);

  Future<void> setVideoInputId(String deviceId) =>
      _prefs.setString(_videoInputKey, deviceId);

  // ── Keepalive/ping/reconnect timer tuning ─────────────────────────────────
  //
  // Each duration is stored as its millisecond count so the values can be
  // edited from a control panel without needing a custom Hive adapter. The
  // jitter ratio is the only non-duration field and is stored as a double.

  static const _smAckIntervalForegroundMsKey = 'keepalive_sm_ack_fg_ms';
  static const _smAckIntervalBackgroundMsKey = 'keepalive_sm_ack_bg_ms';
  static const _pingIntervalForegroundMsKey = 'keepalive_ping_fg_ms';
  static const _pingIntervalBackgroundMsKey = 'keepalive_ping_bg_ms';
  static const _pendingAckRequestDelayMsKey = 'keepalive_pending_ack_delay_ms';
  static const _keepaliveMaxTimeoutMsKey = 'keepalive_max_timeout_ms';
  static const _mucSelfPingIdleMsKey = 'keepalive_muc_self_ping_idle_ms';
  static const _mucSelfPingCheckIntervalMsKey =
      'keepalive_muc_self_ping_check_interval_ms';
  static const _mucSelfPingTimeoutMsKey = 'keepalive_muc_self_ping_timeout_ms';
  static const _csiIdleDelayMsKey = 'keepalive_csi_idle_delay_ms';
  static const _connectRetryDelayMsKey = 'keepalive_connect_retry_delay_ms';
  static const _reconnectBaseDelayMsKey = 'keepalive_reconnect_base_delay_ms';
  static const _reconnectMaxDelayMsKey = 'keepalive_reconnect_max_delay_ms';
  static const _reconnectJitterRatioKey = 'keepalive_reconnect_jitter_ratio';
  static const _quicPingIntervalDefaultMsKey =
      'keepalive_quic_ping_interval_default_ms';
  static const _quicPingIntervalMinFloorMsKey =
      'keepalive_quic_ping_interval_min_floor_ms';
  static const _outgoingCallTimeoutMsKey = 'keepalive_outgoing_call_timeout_ms';
  static const _incomingCallTimeoutMsKey = 'keepalive_incoming_call_timeout_ms';
  static const _callStatsIntervalMsKey = 'keepalive_call_stats_interval_ms';

  Duration _durationOrDefault(String key, Duration fallback) {
    final ms = _prefs.getInt(key);
    return ms == null ? fallback : Duration(milliseconds: ms);
  }

  /// The currently persisted keepalive tuning, falling back to
  /// [KeepaliveTuning.defaults] for any value that has never been set.
  KeepaliveTuning get keepaliveTuning {
    const d = KeepaliveTuning.defaults;
    return KeepaliveTuning(
      smAckIntervalForeground: _durationOrDefault(
        _smAckIntervalForegroundMsKey,
        d.smAckIntervalForeground,
      ),
      smAckIntervalBackground: _durationOrDefault(
        _smAckIntervalBackgroundMsKey,
        d.smAckIntervalBackground,
      ),
      pingIntervalForeground: _durationOrDefault(
        _pingIntervalForegroundMsKey,
        d.pingIntervalForeground,
      ),
      pingIntervalBackground: _durationOrDefault(
        _pingIntervalBackgroundMsKey,
        d.pingIntervalBackground,
      ),
      pendingAckRequestDelay: _durationOrDefault(
        _pendingAckRequestDelayMsKey,
        d.pendingAckRequestDelay,
      ),
      keepaliveMaxTimeout: _durationOrDefault(
        _keepaliveMaxTimeoutMsKey,
        d.keepaliveMaxTimeout,
      ),
      mucSelfPingIdle: _durationOrDefault(
        _mucSelfPingIdleMsKey,
        d.mucSelfPingIdle,
      ),
      mucSelfPingCheckInterval: _durationOrDefault(
        _mucSelfPingCheckIntervalMsKey,
        d.mucSelfPingCheckInterval,
      ),
      mucSelfPingTimeout: _durationOrDefault(
        _mucSelfPingTimeoutMsKey,
        d.mucSelfPingTimeout,
      ),
      csiIdleDelay: _durationOrDefault(_csiIdleDelayMsKey, d.csiIdleDelay),
      connectRetryDelay: _durationOrDefault(
        _connectRetryDelayMsKey,
        d.connectRetryDelay,
      ),
      reconnectBaseDelay: _durationOrDefault(
        _reconnectBaseDelayMsKey,
        d.reconnectBaseDelay,
      ),
      reconnectMaxDelay: _durationOrDefault(
        _reconnectMaxDelayMsKey,
        d.reconnectMaxDelay,
      ),
      reconnectJitterRatio:
          _prefs.getDouble(_reconnectJitterRatioKey) ?? d.reconnectJitterRatio,
      quicPingIntervalDefault: _durationOrDefault(
        _quicPingIntervalDefaultMsKey,
        d.quicPingIntervalDefault,
      ),
      quicPingIntervalMinFloor: _durationOrDefault(
        _quicPingIntervalMinFloorMsKey,
        d.quicPingIntervalMinFloor,
      ),
      outgoingCallTimeout: _durationOrDefault(
        _outgoingCallTimeoutMsKey,
        d.outgoingCallTimeout,
      ),
      incomingCallTimeout: _durationOrDefault(
        _incomingCallTimeoutMsKey,
        d.incomingCallTimeout,
      ),
      callStatsInterval: _durationOrDefault(
        _callStatsIntervalMsKey,
        d.callStatsInterval,
      ),
    );
  }

  /// Persists [tuning], replacing any previously stored values.
  Future<void> setKeepaliveTuning(KeepaliveTuning tuning) async {
    await Future.wait([
      _prefs.setInt(
        _smAckIntervalForegroundMsKey,
        tuning.smAckIntervalForeground.inMilliseconds,
      ),
      _prefs.setInt(
        _smAckIntervalBackgroundMsKey,
        tuning.smAckIntervalBackground.inMilliseconds,
      ),
      _prefs.setInt(
        _pingIntervalForegroundMsKey,
        tuning.pingIntervalForeground.inMilliseconds,
      ),
      _prefs.setInt(
        _pingIntervalBackgroundMsKey,
        tuning.pingIntervalBackground.inMilliseconds,
      ),
      _prefs.setInt(
        _pendingAckRequestDelayMsKey,
        tuning.pendingAckRequestDelay.inMilliseconds,
      ),
      _prefs.setInt(
        _keepaliveMaxTimeoutMsKey,
        tuning.keepaliveMaxTimeout.inMilliseconds,
      ),
      _prefs.setInt(
        _mucSelfPingIdleMsKey,
        tuning.mucSelfPingIdle.inMilliseconds,
      ),
      _prefs.setInt(
        _mucSelfPingCheckIntervalMsKey,
        tuning.mucSelfPingCheckInterval.inMilliseconds,
      ),
      _prefs.setInt(
        _mucSelfPingTimeoutMsKey,
        tuning.mucSelfPingTimeout.inMilliseconds,
      ),
      _prefs.setInt(_csiIdleDelayMsKey, tuning.csiIdleDelay.inMilliseconds),
      _prefs.setInt(
        _connectRetryDelayMsKey,
        tuning.connectRetryDelay.inMilliseconds,
      ),
      _prefs.setInt(
        _reconnectBaseDelayMsKey,
        tuning.reconnectBaseDelay.inMilliseconds,
      ),
      _prefs.setInt(
        _reconnectMaxDelayMsKey,
        tuning.reconnectMaxDelay.inMilliseconds,
      ),
      _prefs.setDouble(_reconnectJitterRatioKey, tuning.reconnectJitterRatio),
      _prefs.setInt(
        _quicPingIntervalDefaultMsKey,
        tuning.quicPingIntervalDefault.inMilliseconds,
      ),
      _prefs.setInt(
        _quicPingIntervalMinFloorMsKey,
        tuning.quicPingIntervalMinFloor.inMilliseconds,
      ),
      _prefs.setInt(
        _outgoingCallTimeoutMsKey,
        tuning.outgoingCallTimeout.inMilliseconds,
      ),
      _prefs.setInt(
        _incomingCallTimeoutMsKey,
        tuning.incomingCallTimeout.inMilliseconds,
      ),
      _prefs.setInt(
        _callStatsIntervalMsKey,
        tuning.callStatsInterval.inMilliseconds,
      ),
    ]);
  }
}
