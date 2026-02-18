import 'dart:developer';

class Log {
  static LogLevel logLevel = LogLevel.VERBOSE;

  static bool logXmpp = true;
  static bool logToConsole = true;

  static void _emit(String message) {
    log(message);
    if (logToConsole) {
      // Keep console output visible in Flutter run logs.
      // ignore: avoid_print
      print(message);
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

  static void xmppp_receiving(String message) {
    if (logXmpp) {
      _emit('---Xmpp Receiving:---');
      _emit('$message');
    }
  }

  static void xmppp_sending(String message) {
    if (logXmpp) {
      _emit('---Xmpp Sending:---');
      _emit('$message');
    }
  }

}

enum LogLevel { VERBOSE, DEBUG, INFO, WARNING, ERROR, OFF }
