import 'dart:async';

import 'package:test/test.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/ReconnectionState.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';

class _TestConnection extends Connection {
  _TestConnection(XmppAccountSettings account) : super(account);

  int reconnectCalls = 0;

  @override
  Future<void> openSocket() async {}

  @override
  void reconnect() {
    if (state == XmppConnectionState.ForcefullyClosed) {
      reconnectCalls += 1;
      setState(XmppConnectionState.Reconnecting);
    }
  }
}

void main() {
  late _TestConnection connection;

  setUp(() {
    final account = XmppAccountSettings.fromJid('alice@example.com', 'secret');
    connection = _TestConnection(account);
    connection.setReconnectPolicy(
      const ReconnectionPolicy(
        baseDelay: Duration(milliseconds: 200),
        maxDelay: Duration(minutes: 10),
        jitterRatio: 0,
        unboundedRetries: true,
      ),
    );
    connection.setReconnectContext(
        networkOnline: true, allowAutoReconnect: true);
  });

  tearDown(() {
    connection.dispose();
  });

  test('forceful close schedules reconnect and dedupes duplicate requests',
      () async {
    var scheduledStates = 0;
    final sub = connection.reconnectStateStream.listen((state) {
      if (state.phase == ReconnectionPhase.scheduled) {
        scheduledStates += 1;
      }
    });

    connection.setState(XmppConnectionState.ForcefullyClosed);
    connection.requestReconnect(reason: ReconnectionReason.keepaliveTimeout);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(scheduledStates, 1);
    expect(connection.reconnectCalls, 0);
    await sub.cancel();
  });

  test('network restore triggers immediate reconnect when suspended', () async {
    connection.setState(XmppConnectionState.ForcefullyClosed);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    connection.setReconnectContext(networkOnline: false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    connection.setReconnectContext(networkOnline: true);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(connection.reconnectCalls, greaterThan(0));
  });

  test('terminal auth failure emits terminal reconnection state', () async {
    final terminalFuture = connection.reconnectStateStream.firstWhere(
      (state) => state.phase == ReconnectionPhase.terminal,
    );
    connection.setState(XmppConnectionState.AuthenticationFailure);
    final terminal = await terminalFuture;

    expect(terminal.message, contains('Authentication failed'));
  });

  test('jittered delay stays within configured bounds', () async {
    connection.setReconnectPolicy(
      const ReconnectionPolicy(
        baseDelay: Duration(seconds: 1),
        maxDelay: Duration(minutes: 10),
        jitterRatio: 0.25,
      ),
    );
    final scheduledFuture = connection.reconnectStateStream.firstWhere(
      (state) => state.phase == ReconnectionPhase.scheduled,
    );
    connection.setState(XmppConnectionState.ForcefullyClosed);
    final scheduled = await scheduledFuture;
    final delay = scheduled.nextDelay!;

    expect(delay.inMilliseconds, greaterThanOrEqualTo(750));
    expect(delay.inMilliseconds, lessThanOrEqualTo(1250));
  });
}
