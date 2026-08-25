import 'dart:async';
import 'dart:developer';

class Log {
  static LogLevel logLevel = LogLevel.VERBOSE;

  static bool logXmpp = true;
  static bool logToConsole = true;

  /// Broadcasts the same timestamped entries written to the developer log.
  ///
  /// Applications can use this to surface connection diagnostics in their UI
  /// on devices where a console is not readily available.
  static final StreamController<String> _messageController =
      StreamController<String>.broadcast(sync: true);

  static Stream<String> get messages => _messageController.stream;

  static String _timestamp() {
    return DateTime.now().toUtc().toIso8601String();
  }

  static void _emit(String message) {
    final stamped = '${_timestamp()} $message';
    log(stamped);
    _messageController.add(stamped);
    if (logToConsole) {
      // Keep console output visible in Flutter run logs.
      // ignore: avoid_print
      print(stamped);
    }
  }

  static void v(String tag, String message) {
    if (logLevel.index <= LogLevel.VERBOSE.index) {
      _emit('V/[$tag]: $message');
    }
  }

  static void d(String tag, String message) {
    if (logLevel.index <= LogLevel.DEBUG.index) {
      _emit('D/[$tag]: $message');
    }
  }

  static void i(String tag, String message) {
    if (logLevel.index <= LogLevel.INFO.index) {
      _emit('I/[$tag]: $message');
    }
  }

  static void w(String tag, String message) {
    if (logLevel.index <= LogLevel.WARNING.index) {
      _emit('W/[$tag]: $message');
    }
  }

  static void e(String tag, String message) {
    if (logLevel.index <= LogLevel.ERROR.index) {
      _emit('E/[$tag]: $message');
    }
  }

  static void xmppp_receiving(String message, {String? channel}) {
    if (logXmpp) {
      if (channel == null) {
        _emit('---Xmpp Receiving:---');
      } else {
        _emit('---Xmpp Receiving [$channel]:---');
      }
      _emit('$message');
    }
  }

  static void xmppp_sending(String message, {String? channel}) {
    if (logXmpp) {
      if (channel == null) {
        _emit('---Xmpp Sending:---');
      } else {
        _emit('---Xmpp Sending [$channel]:---');
      }
      _emit('$message');
    }
  }
}

enum LogLevel { VERBOSE, DEBUG, INFO, WARNING, ERROR, OFF }
