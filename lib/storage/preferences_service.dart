import 'package:shared_preferences/shared_preferences.dart';

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
}
