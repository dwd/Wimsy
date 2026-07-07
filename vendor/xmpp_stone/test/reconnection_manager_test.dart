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

  test(
      'networkChanged force-closes a live connection and schedules immediate reconnect',
      () async {
    // Simulate a connected state (not ForcefullyClosed) — e.g. after wake-from-sleep
    // where the QUIC migration failed but the connection object is still "open".
    connection.setState(XmppConnectionState.Ready);

    final phases = <ReconnectionPhase>[];
    final sub = connection.reconnectStateStream.listen((s) => phases.add(s.phase));

    // This is what xmpp_service.dart calls when QUIC migration fails.
    connection.requestReconnect(
      reason: ReconnectionReason.networkChanged,
      immediate: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // The connection must have been force-closed and a reconnect scheduled/fired.
    expect(
      phases,
      containsAll([ReconnectionPhase.scheduled]),
      reason: 'networkChanged should force-close and schedule a reconnect',
    );
    await sub.cancel();
  });

  test(
      'reconnect continues after a failed attempt (no-network scenario)',
      () async {
    // Regression test: when a reconnect attempt fails (all transports time
    // out), the connection goes ForcefullyClosed again while _phase is still
    // 'reconnecting'. The dedupe guard must not block the next attempt.
    connection.setReconnectPolicy(
      const ReconnectionPolicy(
        baseDelay: Duration(milliseconds: 50),
        maxDelay: Duration(milliseconds: 200),
        jitterRatio: 0,
        unboundedRetries: true,
      ),
    );

    // Start from ForcefullyClosed — first reconnect fires.
    connection.setState(XmppConnectionState.ForcefullyClosed);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connection.reconnectCalls, 1);

    // Simulate the attempt failing: connection goes back to ForcefullyClosed
    // while _phase is still 'reconnecting'.
    connection.setState(XmppConnectionState.ForcefullyClosed);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // A second reconnect attempt must have been scheduled and fired.
    expect(
      connection.reconnectCalls,
      greaterThan(1),
      reason: 'reconnect should continue after a failed attempt',
    );
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
