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
    _policy = policy;
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
      requestReconnect(
        reason: ReconnectionReason.networkChanged,
        immediate: true,
      );
    }
  }

  void setTerminalState(String message) {
    _cancelTimer();
    _emit(ReconnectionPhase.terminal, reason: _lastReason, message: message);
  }

  void requestReconnect({
    required ReconnectionReason reason,
    bool immediate = false,
    bool shortTimeout = false,
  }) {
    _lastReason = reason;
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
        reason == ReconnectionReason.manualRequest;
  }

  void connectionStateHandler(XmppConnectionState state) {
    if (state == XmppConnectionState.ForcefullyClosed) {
      Log.d(TAG, 'Connection forcefully closed');
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
    _attempt = 0;
    isActive = false;
    _cancelTimer();
    _emit(ReconnectionPhase.idle, reason: _lastReason);
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
        return;
      }
      isActive = true;
      _emit(ReconnectionPhase.reconnecting, reason: reason);
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
