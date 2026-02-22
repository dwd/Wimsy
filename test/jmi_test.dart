import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/jmi.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('build and parse JMI propose', () {
    final description = const JingleRtpDescription(
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

    final propose = buildJmiProposeElement(sid: 'sid1', description: description);
    final message = XmppElement()..name = 'message';
    message.addChild(propose);

    final parsed = parseJmiPropose(message);

    expect(parsed, isNotNull);
    expect(parsed!.sid, 'sid1');
    expect(parsed.description.payloadTypes.first.parameters['minptime'], '10');
  });

  test('parseJmiAction detects proceed', () {
    final proceed = buildJmiProceedElement(sid: 'sid2');
    final message = XmppElement()..name = 'message';
    message.addChild(proceed);

    expect(parseJmiAction(message), JmiAction.proceed);
    expect(parseJmiSid(message), 'sid2');
  });
}
