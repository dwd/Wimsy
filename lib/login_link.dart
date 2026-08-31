import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Values supplied by a Wimsy Android login link.
@immutable
class LoginLinkValues {
  const LoginLinkValues({
    required this.jid,
    required this.password,
    required this.displayName,
  });

  final String jid;
  final String password;
  final String displayName;
}

/// Parses the supported `wimsy://login` and `https://wimsy.im/login` links.
LoginLinkValues? parseLoginLink(Uri uri) {
  final isCustomLink = uri.scheme == 'wimsy' && uri.host == 'login';
  final isWebLink =
      uri.scheme == 'https' &&
      uri.host == 'wimsy.im' &&
      (uri.path == '/login' || uri.path == '/login/');
  if (!isCustomLink && !isWebLink) {
    return null;
  }
  final jid = (uri.queryParameters['jid'] ?? '').trim();
  if (jid.isEmpty) {
    return null;
  }
  return LoginLinkValues(
    jid: jid,
    password: uri.queryParameters['password'] ?? '',
    displayName: (uri.queryParameters['display_name'] ?? '').trim(),
  );
}

/// Receives Android intents without requiring a third-party link package.
class AndroidLoginLinkReceiver {
  AndroidLoginLinkReceiver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('wimsy/login_link');

  final MethodChannel _channel;

  Future<void> start(ValueChanged<LoginLinkValues> onLink) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLoginLink') {
        _deliver(call.arguments as String?, onLink);
      }
    });
    final initialLink = await _channel.invokeMethod<String>('getInitialLink');
    _deliver(initialLink, onLink);
  }

  void _deliver(String? rawLink, ValueChanged<LoginLinkValues> onLink) {
    if (rawLink == null) return;
    final uri = Uri.tryParse(rawLink);
    if (uri == null) return;
    final values = parseLoginLink(uri);
    if (values != null) onLink(values);
  }

  void dispose() => _channel.setMethodCallHandler(null);
}
