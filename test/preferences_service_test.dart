import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
}
