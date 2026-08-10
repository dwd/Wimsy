import 'package:flutter_test/flutter_test.dart';

import 'package:wimsy/models/muc_notify_settings.dart';

void main() {
  group('MucNotifySettings XML round-trip', () {
    test('default settings serialize to mentions mode with no after-own attribute', () {
      const settings = MucNotifySettings.defaultSettings;
      final xml = settings.toXml();
      expect(xml.name, 'notify');
      expect(xml.getAttribute('xmlns')?.value, 'https://wimsy.cridland.io/muc-notify');
      expect(xml.getAttribute('mode')?.value, 'mentions');
      expect(xml.getAttribute('after-own'), isNull);

      final parsed = MucNotifySettings.fromXml(xml);
      expect(parsed, settings);
    });

    test('all-messages mode with timed after-own period round-trips', () {
      const settings = MucNotifySettings(
        mode: MucNotifyMode.all,
        afterOwnMessagePeriod: Duration(minutes: 15),
      );
      final xml = settings.toXml();
      expect(xml.getAttribute('mode')?.value, 'all');
      expect(xml.getAttribute('after-own')?.value, '900');

      final parsed = MucNotifySettings.fromXml(xml);
      expect(parsed, settings);
    });

    test('always-after-own overrides any timed period on serialization', () {
      const settings = MucNotifySettings(
        mode: MucNotifyMode.mentions,
        afterOwnMessagePeriod: Duration(minutes: 5),
        alwaysAfterOwnMessage: true,
      );
      final xml = settings.toXml();
      expect(xml.getAttribute('after-own')?.value, 'always');

      final parsed = MucNotifySettings.fromXml(xml);
      expect(parsed!.alwaysAfterOwnMessage, isTrue);
      expect(parsed.afterOwnMessagePeriod, isNull);
    });

    test('fromXml returns null for unrelated elements', () {
      expect(MucNotifySettings.fromXml(null), isNull);
    });
  });

  group('MucNotifySettings map round-trip', () {
    test('round-trips through toMap/fromMap', () {
      const settings = MucNotifySettings(
        mode: MucNotifyMode.all,
        afterOwnMessagePeriod: Duration(seconds: 42),
      );
      final map = settings.toMap();
      final parsed = MucNotifySettings.fromMap(map);
      expect(parsed, settings);
    });

    test('fromMap returns null for null input', () {
      expect(MucNotifySettings.fromMap(null), isNull);
    });
  });

  group('bodyMentionsNick', () {
    test('matches nickname followed by colon at start of message', () {
      expect(MucNotifySettings.bodyMentionsNick('dave: hi there', 'dave'), isTrue);
    });

    test('matches nickname followed by comma at start of message', () {
      expect(MucNotifySettings.bodyMentionsNick('dave, are you around?', 'dave'), isTrue);
    });

    test('matches @ followed by nickname anywhere in the message', () {
      expect(MucNotifySettings.bodyMentionsNick('hey @dave check this out', 'dave'), isTrue);
    });

    test('is case-insensitive', () {
      expect(MucNotifySettings.bodyMentionsNick('DAVE: hi', 'dave'), isTrue);
      expect(MucNotifySettings.bodyMentionsNick('hi @Dave', 'dave'), isTrue);
    });

    test('does not match unrelated messages', () {
      expect(MucNotifySettings.bodyMentionsNick('just chatting about stuff', 'dave'), isFalse);
    });

    test('does not match a different nickname as a prefix of another', () {
      expect(MucNotifySettings.bodyMentionsNick('daveson: hi', 'dave'), isFalse);
      expect(MucNotifySettings.bodyMentionsNick('hi @daveson', 'dave'), isFalse);
    });

    test('returns false for empty body or nickname', () {
      expect(MucNotifySettings.bodyMentionsNick('', 'dave'), isFalse);
      expect(MucNotifySettings.bodyMentionsNick('dave: hi', ''), isFalse);
    });
  });
}
