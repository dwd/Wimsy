class AccountRecord {
  AccountRecord({
    required this.jid,
    required this.password,
    required this.host,
    required this.port,
    required this.resource,
    required this.rememberPassword,
    required this.useWebSocket,
    required this.directTls,
    required this.connectionUrl,
    this.useQuic = true,
    this.useTcp = true,
  });

  final String jid;
  final String password;
  final String host;
  final int port;
  final String resource;
  final bool rememberPassword;
  final bool useWebSocket;
  final bool directTls;
  /// Manual connection URL override. The scheme determines the transport:
  /// `wss://` / `ws://` → WebSocket; `https://` / `http://` → WebTransport.
  final String connectionUrl;
  /// Whether to attempt QUIC transport (XEP-0467) when available.
  final bool useQuic;

  /// Whether to attempt plain TCP (`_xmpp-client._tcp` SRV records and the
  /// non-TLS fallback). When false, plain-TCP SRV records are ignored and
  /// no plain-TCP fallback connection will be attempted.
  final bool useTcp;

  Map<String, dynamic> toMap() {
    return {
      'jid': jid,
      'password': password,
      'host': host,
      'port': port,
      'resource': resource,
      'rememberPassword': rememberPassword,
      'useWebSocket': useWebSocket,
      'directTls': directTls,
      'connectionUrl': connectionUrl,
      'useQuic': useQuic,
      'useTcp': useTcp,
    };
  }

  static AccountRecord? fromMap(Map<String, dynamic>? map) {
    if (map == null) {
      return null;
    }
    final jid = map['jid']?.toString() ?? '';
    final password = map['password']?.toString() ?? '';
    final host = map['host']?.toString() ?? '';
    final portRaw = map['port'];
    final resource = map['resource']?.toString() ?? '';
    final rememberPasswordRaw = map['rememberPassword'];
    final useWebSocketRaw = map['useWebSocket'];
    final directTlsRaw = map['directTls'];
    // Support both the new 'connectionUrl' key and the legacy 'wsEndpoint' key.
    final connectionUrl =
        (map['connectionUrl'] ?? map['wsEndpoint'])?.toString() ?? '';
    final useQuicRaw = map['useQuic'];
    final useTcpRaw = map['useTcp'];
    final port = portRaw is int ? portRaw : int.tryParse(portRaw?.toString() ?? '') ?? 5222;
    if (jid.isEmpty) {
      return null;
    }
    final rememberPassword = rememberPasswordRaw is bool
        ? rememberPasswordRaw
        : password.isNotEmpty;
    final useWebSocket = useWebSocketRaw is bool
        ? useWebSocketRaw
        : connectionUrl.isNotEmpty;
    final directTls = directTlsRaw is bool ? directTlsRaw : false;
    final useQuic = useQuicRaw is bool ? useQuicRaw : true;
    final useTcp = useTcpRaw is bool ? useTcpRaw : true;
    return AccountRecord(
      jid: jid,
      password: rememberPassword ? password : '',
      host: host,
      port: port,
      resource: resource,
      rememberPassword: rememberPassword,
      useWebSocket: useWebSocket,
      directTls: directTls,
      connectionUrl: connectionUrl,
      useQuic: useQuic,
      useTcp: useTcp,
    );
  }
}
