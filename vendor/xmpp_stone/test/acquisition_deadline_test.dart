import 'package:test/test.dart';
import 'package:xmpp_stone/src/Connection.dart';

void main() {
  test('connection phases have separate acquisition deadlines', () {
    expect(
      acquisitionPhaseTimeout(XmppConnectionState.SocketOpening),
      const Duration(seconds: 60),
    );
    expect(
      acquisitionPhaseTimeout(XmppConnectionState.SocketOpened),
      const Duration(seconds: 30),
    );
    expect(
      acquisitionPhaseTimeout(XmppConnectionState.Authenticating),
      const Duration(seconds: 45),
    );
    expect(acquisitionPhaseTimeout(XmppConnectionState.Ready), isNull);
  });
}
