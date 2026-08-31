import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const String webBuildId = String.fromEnvironment('WIMSY_BUILD_ID');

/// Polls the deployed build marker and reports when this web client is stale.
///
/// A build ID is intentionally used instead of the package version because
/// local deployments commonly rebuild without changing `pubspec.yaml`.
class WebUpdateMonitor {
  WebUpdateMonitor({
    required this.onUpdateAvailable,
    http.Client? client,
    this.interval = const Duration(minutes: 5),
  }) : _client = client ?? http.Client();

  final VoidCallback onUpdateAvailable;
  final Duration interval;
  final http.Client _client;
  Timer? _timer;
  bool _reported = false;

  void start() {
    if (!kIsWeb || webBuildId.isEmpty) return;
    unawaited(check());
    _timer = Timer.periodic(interval, (_) => unawaited(check()));
  }

  Future<void> check() async {
    if (_reported || !kIsWeb || webBuildId.isEmpty) return;
    try {
      final response = await _client.get(
        Uri.parse(
          'update.json?current=${Uri.encodeQueryComponent(webBuildId)}',
        ),
        headers: const {'Cache-Control': 'no-cache'},
      );
      if (response.statusCode != 200) return;
      final deployedBuildId = parseBuildId(response.body);
      if (deployedBuildId != null && deployedBuildId != webBuildId) {
        _reported = true;
        onUpdateAvailable();
      }
    } on Object {
      // Update checks are best-effort and must not disrupt the client.
    }
  }

  void dispose() {
    _timer?.cancel();
    _client.close();
  }
}

@visibleForTesting
String? parseBuildId(String body) {
  try {
    final value = jsonDecode(body);
    if (value is! Map<String, dynamic>) return null;
    final buildId = value['build_id'];
    return buildId is String && buildId.isNotEmpty ? buildId : null;
  } on FormatException {
    return null;
  }
}
