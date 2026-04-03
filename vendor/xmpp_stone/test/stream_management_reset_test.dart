import 'package:test/test.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';
import 'package:xmpp_stone/src/features/Negotiator.dart';
import 'package:xmpp_stone/src/features/streammanagement/StreamManagmentModule.dart';

void main() {
  test('SM enable resets sent and received counters after resume failure', () {
    final account = XmppAccountSettings.fromJid('alice@example.com', 'secret');
    final connection = Connection(account);
    final sm = StreamManagementModule.getInstance(connection);

    sm.streamState.lastSentStanza = 7;
    sm.streamState.lastReceivedStanza = 5;
    sm.lastAckSent = 5;
    sm.streamState.nonConfirmedSentStanzas
        .add(IqStanza('iq-1', IqStanzaType.GET));

    sm.streamState.tryingToResume = true;
    sm.state = NegotiatorState.NEGOTIATING;
    sm.parseNonza(
      Nonza()
        ..name = 'failed'
        ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sm:3')),
    );

    sm.streamState.lastSentStanza = 2;
    sm.streamState.lastReceivedStanza = 3;
    sm.lastAckSent = 3;
    sm.streamState.nonConfirmedSentStanzas
        .add(IqStanza('iq-2', IqStanzaType.SET));

    sm.handleEnabled(
      Nonza()
        ..name = 'enabled'
        ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sm:3'))
        ..addAttribute(XmppAttribute('resume', 'true'))
        ..addAttribute(XmppAttribute('id', 'new-sm-id')),
    );

    expect(sm.streamState.lastSentStanza, 0);
    expect(sm.streamState.lastReceivedStanza, 0);
    expect(sm.lastAckSent, 0);
    expect(sm.streamState.nonConfirmedSentStanzas, isEmpty);
    expect(sm.streamState.tryingToResume, isFalse);
    expect(sm.streamState.streamManagementEnabled, isTrue);
    expect(sm.streamState.streamResumeEnabled, isTrue);

    connection.dispose();
  });
}
