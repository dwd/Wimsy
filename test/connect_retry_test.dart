import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal self-contained model of the retry scheduling logic extracted from
// XmppService so it can be tested without a real XMPP stack.
//
// The production code in XmppService._scheduleConnectRetry() follows exactly
// this pattern:
//   1. Cancel any existing retry timer.
//   2. Schedule a new Timer(_connectRetryDelay, callback).
//   3. The callback calls connect() with the stored _lastConnectArgs.
//   4. disconnect() cancels the timer and clears _lastConnectArgs.
// ---------------------------------------------------------------------------

/// Minimal record of connect parameters (mirrors _ConnectArgs in xmpp_service.dart).
class _ConnectArgs {
  const _ConnectArgs({required this.jid, required this.password});
  final String jid;
  final String password;
}

/// Simplified retry scheduler that mirrors the production logic.
class _RetryScheduler {
  static const Duration retryDelay = Duration(minutes: 1);

  Timer? _retryTimer;
  _ConnectArgs? _lastArgs;
  int connectCallCount = 0;
  _ConnectArgs? lastConnectArgs;

  void connect({required String jid, required String password}) {
    // Cancel any pending retry so we don't double-connect.
    _retryTimer?.cancel();
    _retryTimer = null;
    _lastArgs = _ConnectArgs(jid: jid, password: password);
    connectCallCount++;
    lastConnectArgs = _lastArgs;
  }

  void scheduleRetry() {
    final args = _lastArgs;
    if (args == null) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelay, () {
      _retryTimer = null;
      connect(jid: args.jid, password: args.password);
    });
  }

  void disconnect() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _lastArgs = null;
  }

  bool get hasRetryPending => _retryTimer != null;
}

void main() {
  group('connect retry scheduling', () {
    test('retry fires after 1 minute and calls connect again', () {
      fakeAsync((async) {
        final scheduler = _RetryScheduler();
        scheduler.connect(jid: 'user@example.com', password: 'secret');
        expect(scheduler.connectCallCount, 1);

        // Simulate a connection failure — schedule retry.
        scheduler.scheduleRetry();
        expect(scheduler.hasRetryPending, isTrue);

        // Advance time by just under 1 minute — retry should NOT have fired.
        async.elapse(const Duration(seconds: 59));
        expect(scheduler.connectCallCount, 1);

        // Advance past the 1-minute mark — retry SHOULD fire.
        async.elapse(const Duration(seconds: 2));
        expect(scheduler.connectCallCount, 2);
        expect(scheduler.hasRetryPending, isFalse);
        expect(scheduler.lastConnectArgs?.jid, 'user@example.com');
        expect(scheduler.lastConnectArgs?.password, 'secret');
      });
    });

    test('retry preserves original connect args', () {
      fakeAsync((async) {
        final scheduler = _RetryScheduler();
        scheduler.connect(jid: 'alice@xmpp.example', password: 'p@ssw0rd');
        scheduler.scheduleRetry();

        async.elapse(const Duration(minutes: 1, seconds: 1));

        expect(scheduler.lastConnectArgs?.jid, 'alice@xmpp.example');
        expect(scheduler.lastConnectArgs?.password, 'p@ssw0rd');
      });
    });

    test('disconnect cancels pending retry', () {
      fakeAsync((async) {
        final scheduler = _RetryScheduler();
        scheduler.connect(jid: 'user@example.com', password: 'secret');
        scheduler.scheduleRetry();
        expect(scheduler.hasRetryPending, isTrue);

        // User explicitly disconnects — retry must be cancelled.
        scheduler.disconnect();
        expect(scheduler.hasRetryPending, isFalse);

        // Advance well past the retry window — connect should NOT be called again.
        async.elapse(const Duration(minutes: 5));
        expect(scheduler.connectCallCount, 1);
      });
    });

    test('calling connect() again cancels any pending retry', () {
      fakeAsync((async) {
        final scheduler = _RetryScheduler();
        scheduler.connect(jid: 'user@example.com', password: 'secret');
        scheduler.scheduleRetry();
        expect(scheduler.hasRetryPending, isTrue);

        // A new manual connect() call (e.g. user taps "Retry") cancels the timer.
        scheduler.connect(jid: 'user@example.com', password: 'secret');
        expect(scheduler.hasRetryPending, isFalse);

        // Advance past the original retry window — no extra connect call.
        async.elapse(const Duration(minutes: 2));
        // Only the two explicit connect() calls, no timer-triggered one.
        expect(scheduler.connectCallCount, 2);
      });
    });

    test('scheduleRetry does nothing when no connect args are stored', () {
      fakeAsync((async) {
        final scheduler = _RetryScheduler();
        // No connect() called yet — scheduleRetry should be a no-op.
        scheduler.scheduleRetry();
        expect(scheduler.hasRetryPending, isFalse);

        async.elapse(const Duration(minutes: 2));
        expect(scheduler.connectCallCount, 0);
      });
    });

    test('retry fires only once, not repeatedly', () {
      fakeAsync((async) {
        final scheduler = _RetryScheduler();
        scheduler.connect(jid: 'user@example.com', password: 'secret');
        scheduler.scheduleRetry();

        // Advance 3 minutes — the retry fires once at 1 minute, then stops.
        async.elapse(const Duration(minutes: 3));
        // connect() was called once initially + once by the timer = 2 total.
        expect(scheduler.connectCallCount, 2);
      });
    });

    test('multiple scheduleRetry calls do not stack timers', () {
      fakeAsync((async) {
        final scheduler = _RetryScheduler();
        scheduler.connect(jid: 'user@example.com', password: 'secret');

        // Schedule retry three times in a row (e.g. multiple error callbacks).
        scheduler.scheduleRetry();
        scheduler.scheduleRetry();
        scheduler.scheduleRetry();

        async.elapse(const Duration(minutes: 2));
        // Only one retry should have fired.
        expect(scheduler.connectCallCount, 2);
      });
    });
  });
}
