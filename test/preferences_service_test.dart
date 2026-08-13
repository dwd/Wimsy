import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wimsy/models/keepalive_tuning.dart';
import 'package:wimsy/storage/preferences_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<PreferencesService> load() => PreferencesService.load();

  group('sentryOptIn', () {
    test('defaults to false', () async {
      final prefs = await load();
      expect(prefs.sentryOptIn, isFalse);
    });

    test('round-trips true', () async {
      final prefs = await load();
      await prefs.setSentryOptIn(true);
      expect(prefs.sentryOptIn, isTrue);
    });

    test('round-trips false after true', () async {
      final prefs = await load();
      await prefs.setSentryOptIn(true);
      await prefs.setSentryOptIn(false);
      expect(prefs.sentryOptIn, isFalse);
    });
  });

  group('pinIgnored', () {
    test('defaults to false', () async {
      final prefs = await load();
      expect(prefs.pinIgnored, isFalse);
    });

    test('round-trips true', () async {
      final prefs = await load();
      await prefs.setPinIgnored(true);
      expect(prefs.pinIgnored, isTrue);
    });
  });

  group('lastJid', () {
    test('defaults to null', () async {
      final prefs = await load();
      expect(prefs.lastJid, isNull);
    });

    test('round-trips a JID string', () async {
      final prefs = await load();
      await prefs.setLastJid('alice@example.com');
      expect(prefs.lastJid, 'alice@example.com');
    });
  });

  group('audioInputId', () {
    test('defaults to null', () async {
      final prefs = await load();
      expect(prefs.audioInputId, isNull);
    });

    test('round-trips a device ID', () async {
      final prefs = await load();
      await prefs.setAudioInputId('mic-device-1');
      expect(prefs.audioInputId, 'mic-device-1');
    });
  });

  group('videoInputId', () {
    test('defaults to null', () async {
      final prefs = await load();
      expect(prefs.videoInputId, isNull);
    });

    test('round-trips a device ID', () async {
      final prefs = await load();
      await prefs.setVideoInputId('cam-device-2');
      expect(prefs.videoInputId, 'cam-device-2');
    });
  });

  group('keepaliveTuning', () {
    test('defaults to KeepaliveTuning.defaults when nothing is stored',
        () async {
      final prefs = await load();
      expect(prefs.keepaliveTuning, KeepaliveTuning.defaults);
    });

    test('round-trips a fully customized tuning', () async {
      final prefs = await load();
      const custom = KeepaliveTuning(
        smAckIntervalForeground: Duration(seconds: 20),
        smAckIntervalBackground: Duration(minutes: 3),
        pingIntervalForeground: Duration(seconds: 15),
        pingIntervalBackground: Duration(minutes: 2),
        pendingAckRequestDelay: Duration(seconds: 5),
        keepaliveMaxTimeout: Duration(seconds: 45),
        mucSelfPingIdle: Duration(minutes: 5),
        mucSelfPingCheckInterval: Duration(seconds: 30),
        mucSelfPingTimeout: Duration(seconds: 20),
        csiIdleDelay: Duration(seconds: 90),
        connectRetryDelay: Duration(seconds: 30),
        reconnectBaseDelay: Duration(seconds: 2),
        reconnectMaxDelay: Duration(minutes: 5),
        reconnectJitterRatio: 0.5,
        quicPingIntervalDefault: Duration(minutes: 2),
        quicPingIntervalMinFloor: Duration(seconds: 5),
        outgoingCallTimeout: Duration(seconds: 30),
        incomingCallTimeout: Duration(seconds: 40),
        callStatsInterval: Duration(seconds: 2),
      );

      await prefs.setKeepaliveTuning(custom);

      expect(prefs.keepaliveTuning, custom);
    });

    test('only overrides values that were explicitly saved', () async {
      final prefs = await load();
      final partiallyCustom = KeepaliveTuning.defaults.copyWith(
        pingIntervalForeground: const Duration(seconds: 7),
      );

      await prefs.setKeepaliveTuning(partiallyCustom);
      final reloaded = prefs.keepaliveTuning;

      expect(reloaded.pingIntervalForeground, const Duration(seconds: 7));
      expect(
        reloaded.pingIntervalBackground,
        KeepaliveTuning.defaults.pingIntervalBackground,
      );
    });
  });
}
