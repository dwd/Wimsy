import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/jmi.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('build and parse JMI propose', () {
    final audio = const JingleRtpDescription(
      media: 'audio',
      payloadTypes: [
        JingleRtpPayloadType(
          id: 111,
          name: 'opus',
          clockRate: 48000,
          channels: 2,
          parameters: {'minptime': '10'},
        ),
      ],
    );
    final video = const JingleRtpDescription(
      media: 'video',
      payloadTypes: [
        JingleRtpPayloadType(id: 96, name: 'VP8', clockRate: 90000),
      ],
    );

    final propose = buildJmiProposeElement(
      sid: 'sid1',
      descriptions: [audio, video],
    );
    final message = XmppElement()..name = 'message';
    message.addChild(propose);

    final parsed = parseJmiPropose(message);

    expect(parsed, isNotNull);
    expect(parsed!.sid, 'sid1');
    expect(parsed.descriptions, hasLength(2));
    expect(
      parsed.descriptions
          .firstWhere((desc) => desc.media == 'audio')
          .payloadTypes
          .first
          .parameters['minptime'],
      '10',
    );
  });

  test('parseJmiAction detects proceed', () {
    final proceed = buildJmiProceedElement(sid: 'sid2');
    final message = XmppElement()..name = 'message';
    message.addChild(proceed);

    expect(parseJmiAction(message), JmiAction.proceed);
    expect(parseJmiSid(message), 'sid2');
  });

  test('JMI fallback removes the complete generic body', () {
    const body = 'Incoming video call';
    final fallback = buildJmiFallbackElement(body);

    expect(fallback.getAttribute('xmlns')?.value, fallbackNamespace);
    expect(fallback.getAttribute('for')?.value, jmiNamespace);
    final range = fallback.getChild('body');
    expect(range?.getAttribute('start')?.value, '0');
    expect(range?.getAttribute('end')?.value, '${body.runes.length}');
  });
}
