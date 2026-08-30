import 'dart:async';
import 'dart:math';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/ReconnectionState.dart';
import 'logger/Log.dart';

class ReconnectionManager {
  static const TAG = 'ReconnectionManager';

  late Connection _connection;
  bool isActive = false;
  bool _networkOnline = true;
  bool _allowAutoReconnect = true;
  int _attempt = 0;
  ReconnectionPolicy _policy = const ReconnectionPolicy();
  ReconnectionReason? _lastReason;
  final Random _random = Random();
  Timer? timer;
  Timer? _stableReadyTimer;
  late StreamSubscription<XmppConnectionState> _xmppConnectionStateSubscription;
  final StreamController<ReconnectionState> _stateController =
      StreamController.broadcast();

  ReconnectionManager(Connection connection) {
    _connection = connection;
    _xmppConnectionStateSubscription =
        _connection.connectionStateStream.listen(connectionStateHandler);
    final baseMs = _connection.account.reconnectionTimeout;
    if (baseMs > 0) {
      _policy = ReconnectionPolicy(baseDelay: Duration(milliseconds: baseMs));
    }
  }

  Stream<ReconnectionState> get stateStream => _stateController.stream;

  ReconnectionState get currentState => ReconnectionState(
        phase: _phase,
        reason: _lastReason,
        attempt: _attempt,
        nextDelay: _nextDelay,
        updatedAt: DateTime.now(),
        message: _message,
      );

  ReconnectionPhase _phase = ReconnectionPhase.idle;
  Duration? _nextDelay;
  String? _message;

  void setPolicy(ReconnectionPolicy policy) {
    final jitter = policy.jitterRatio < 0
        ? 0.0
        : (policy.jitterRatio > 1 ? 1.0 : policy.jitterRatio);
    final maxDelay =
        policy.maxDelay < policy.baseDelay ? policy.baseDelay : policy.maxDelay;
    _policy = ReconnectionPolicy(
      baseDelay: policy.baseDelay,
      maxDelay: maxDelay,
      jitterRatio: jitter,
      unboundedRetries: policy.unboundedRetries,
      maxAttempts: policy.maxAttempts,
      stableReadyDuration: policy.stableReadyDuration,
    );
    Log.i(
      TAG,
      'Policy updated base=${_policy.baseDelay.inMilliseconds}ms '
      'max=${_policy.maxDelay.inMilliseconds}ms '
      'jitter=${_policy.jitterRatio} '
      'unbounded=${_policy.unboundedRetries} '
      'maxAttempts=${_policy.maxAttempts}',
    );
  }

  void setContext({bool? networkOnline, bool? allowAutoReconnect}) {
    final wasOffline = !_networkOnline;
    if (networkOnline != null) {
      _networkOnline = networkOnline;
    }
    if (allowAutoReconnect != null) {
      _allowAutoReconnect = allowAutoReconnect;
    }
    if (!_networkOnline || !_allowAutoReconnect) {
      _cancelTimer();
      Log.i(
        TAG,
        'Reconnect suspended online=$_networkOnline auto=$_allowAutoReconnect',
      );
      _emit(
        ReconnectionPhase.suspended,
        reason: _lastReason,
        message: !_allowAutoReconnect
            ? 'Auto reconnect disabled'
            : 'Network offline',
      );
      return;
    }
    if (wasOffline &&
        _networkOnline &&
        _connection.state == XmppConnectionState.ForcefullyClosed) {
      Log.i(TAG, 'Network restored; requesting immediate reconnect');
      requestReconnect(
        reason: ReconnectionReason.networkChanged,
        immediate: true,
      );
    }
  }

  void setTerminalState(String message) {
    _cancelTimer();
    Log.w(TAG, 'Reconnect terminal: $message');
    _emit(ReconnectionPhase.terminal, reason: _lastReason, message: message);
  }

  void requestReconnect({
    required ReconnectionReason reason,
    bool immediate = false,
    bool shortTimeout = false,
  }) {
    _lastReason = reason;
    if (!_networkOnline || !_allowAutoReconnect) {
      Log.i(
        TAG,
        'Reconnect request suspended reason=$reason '
        'online=$_networkOnline auto=$_allowAutoReconnect',
      );
      _emit(
        ReconnectionPhase.suspended,
        reason: reason,
        message: !_allowAutoReconnect
            ? 'Auto reconnect disabled'
            : 'Network offline',
      );
      return;
    }
    if (_connection.state != XmppConnectionState.ForcefullyClosed) {
      if (_shouldForceClose(reason) &&
          _connection.state != XmppConnectionState.Closed &&
          _connection.state != XmppConnectionState.Closing &&
          _connection.state != XmppConnectionState.SocketOpening) {
        _connection.simulateForcefulClose();
      } else {
        return;
      }
    }
    if (_connection.state != XmppConnectionState.ForcefullyClosed) {
      return;
    }
    if (_phase == ReconnectionPhase.reconnecting ||
        _phase == ReconnectionPhase.scheduled) {
      Log.d(TAG, 'Reconnect dedupe reason=$reason phase=$_phase');
      return;
    }
    final delay = immediate
        ? Duration.zero
        : _delayForAttempt(_attempt, shortTimeout: shortTimeout);
    _schedule(delay, reason);
  }

  bool _shouldForceClose(ReconnectionReason reason) {
    return reason == ReconnectionReason.keepaliveTimeout ||
        reason == ReconnectionReason.streamError ||
        reason == ReconnectionReason.manualRequest ||
        // A network-change event (e.g. wake-from-sleep, interface switch)
        // means the existing transport is stale and must be torn down before
        // a new connection can be established.
        reason == ReconnectionReason.networkChanged;
  }

  void connectionStateHandler(XmppConnectionState state) {
    if (state != XmppConnectionState.Ready &&
        state != XmppConnectionState.Resumed) {
      _stableReadyTimer?.cancel();
      _stableReadyTimer = null;
    }
    if (state == XmppConnectionState.ForcefullyClosed) {
      Log.d(TAG, 'Connection forcefully closed');
      // Reset phase so the dedupe check in requestReconnect does not block
      // the next attempt. This handles the case where a connection attempt
      // fails (e.g. network offline) while _phase is still 'reconnecting'.
      if (_phase == ReconnectionPhase.reconnecting) {
        _phase = ReconnectionPhase.idle;
      }
      requestReconnect(reason: ReconnectionReason.forcefulClose);
      return;
    }
    if (state == XmppConnectionState.Reconnecting ||
        state == XmppConnectionState.SocketOpening) {
      _emit(ReconnectionPhase.reconnecting, reason: _lastReason);
      return;
    }
    if (state == XmppConnectionState.AuthenticationFailure ||
        state == XmppConnectionState.AuthenticationNotSupported) {
      setTerminalState('Authentication failed');
      return;
    }
    if (state == XmppConnectionState.Ready ||
        state == XmppConnectionState.Resumed) {
      _stableReadyTimer?.cancel();
      _stableReadyTimer = Timer(_policy.stableReadyDuration, () {
        _attempt = 0;
        isActive = false;
        _emit(ReconnectionPhase.idle, reason: _lastReason);
      });
      _cancelTimer();
      _emit(ReconnectionPhase.idle, reason: _lastReason);
    }
  }

  Duration _delayForAttempt(int attempt, {required bool shortTimeout}) {
    Duration base = _policy.baseDelay;
    if (shortTimeout) {
      base = const Duration(seconds: 5);
    }
    final growth = 1 << (attempt.clamp(0, 16));
    Duration delay = Duration(milliseconds: base.inMilliseconds * growth);
    if (delay > _policy.maxDelay) {
      delay = _policy.maxDelay;
    }
    return _jitter(delay);
  }

  Duration _jitter(Duration base) {
    if (_policy.jitterRatio <= 0) {
      return base;
    }
    final span = base.inMilliseconds * _policy.jitterRatio;
    final offset = ((_random.nextDouble() * 2) - 1) * span;
    final jittered = base.inMilliseconds + offset.round();
    return Duration(milliseconds: jittered < 0 ? 0 : jittered);
  }

  void _schedule(Duration delay, ReconnectionReason reason) {
    _cancelTimer();
    _nextDelay = delay;
    Log.i(
      TAG,
      'Reconnect scheduled reason=$reason attempt=$_attempt '
      'delay=${delay.inMilliseconds}ms',
    );
    _emit(ReconnectionPhase.scheduled, reason: reason);
    timer = Timer(delay, () {
      timer = null;
      if (!_networkOnline || !_allowAutoReconnect) {
        _emit(
          ReconnectionPhase.suspended,
          reason: reason,
          message: !_allowAutoReconnect
              ? 'Auto reconnect disabled'
              : 'Network offline',
        );
        return;
      }
      if (_connection.state != XmppConnectionState.ForcefullyClosed) {
        Log.d(TAG, 'Reconnect skipped state=${_connection.state}');
        return;
      }
      isActive = true;
      _emit(ReconnectionPhase.reconnecting, reason: reason);
      Log.i(TAG, 'Reconnect firing reason=$reason attempt=$_attempt');
      _connection.reconnect();
      _attempt += 1;
      if (!_policy.unboundedRetries &&
          _policy.maxAttempts != null &&
          _attempt >= _policy.maxAttempts!) {
        setTerminalState('Reconnect attempts exhausted');
      }
    });
  }

  void close() {
    _cancelTimer();
    _stableReadyTimer?.cancel();
    _xmppConnectionStateSubscription.cancel();
    _stateController.close();
  }

  void _cancelTimer() {
    timer?.cancel();
    timer = null;
    _nextDelay = null;
  }

  void _emit(
    ReconnectionPhase phase, {
    ReconnectionReason? reason,
    String? message,
  }) {
    _phase = phase;
    _message = message;
    _stateController.add(
      ReconnectionState(
        phase: phase,
        reason: reason,
        attempt: _attempt,
        nextDelay: _nextDelay,
        updatedAt: DateTime.now(),
        message: message,
      ),
    );
  }
}
