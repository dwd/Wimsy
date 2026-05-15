class WsEndpointConfig {
  WsEndpointConfig({
    required this.uri,
    required this.host,
    required this.port,
    required this.path,
    required this.scheme,
  });

  final Uri uri;
  final String host;
  final int port;
  final String path;
  final String scheme;

  /// True when the URL scheme indicates a WebTransport connection
  /// (`https` or `http`), false for WebSocket (`wss` or `ws`).
  bool get isWebTransport => scheme == 'https' || scheme == 'http';
}

/// Parses a manual connection URL into a [WsEndpointConfig].
///
/// Accepted schemes:
///   `wss://` / `ws://`   → WebSocket connection
///   `https://` / `http://` → WebTransport connection
///
/// If no scheme is present, `wss://` is assumed (WebSocket).
/// Returns `null` if the input is empty or cannot be parsed.
WsEndpointConfig? parseWsEndpoint(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final hasScheme = trimmed.contains('://');
  final candidate = hasScheme ? trimmed : 'wss://$trimmed';
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) {
    return null;
  }
  final isWebTransport = uri.scheme == 'https' || uri.scheme == 'http';
  final isWebSocket = uri.scheme == 'ws' || uri.scheme == 'wss';
  if (!isWebTransport && !isWebSocket) {
    return null;
  }
  // Default path differs by transport type.
  final defaultPath = isWebTransport ? '/xmpp-webtransport' : '/xmpp-websocket';
  final path = uri.path.isEmpty ? defaultPath : uri.path;
  final normalized = uri.replace(path: path);
  final port = normalized.hasPort
      ? normalized.port
      : (normalized.scheme == 'wss' || normalized.scheme == 'https')
          ? 443
          : 80;
  return WsEndpointConfig(
    uri: normalized,
    host: normalized.host,
    port: port,
    path: normalized.path,
    scheme: normalized.scheme,
  );
}
