class AccountRecord {
  AccountRecord({
    required this.jid,
    required this.password,
    required this.host,
    required this.port,
    required this.resource,
    required this.rememberPassword,
    required this.useWebSocket,
    required this.wsEndpoint,
    required this.wsProtocols,
  });

  final String jid;
  final String password;
  final String host;
  final int port;
  final String resource;
  final bool rememberPassword;
  final bool useWebSocket;
  final String wsEndpoint;
  final List<String> wsProtocols;

  Map<String, dynamic> toMap() {
    return {
      'jid': jid,
      'password': password,
      'host': host,
      'port': port,
      'resource': resource,
      'rememberPassword': rememberPassword,
      'useWebSocket': useWebSocket,
      'wsEndpoint': wsEndpoint,
      'wsProtocols': wsProtocols,
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
    final wsEndpoint = map['wsEndpoint']?.toString() ?? '';
    final wsProtocolsRaw = map['wsProtocols'];
    final port = portRaw is int ? portRaw : int.tryParse(portRaw?.toString() ?? '') ?? 5222;
    if (jid.isEmpty) {
      return null;
    }
    final rememberPassword = rememberPasswordRaw is bool
        ? rememberPasswordRaw
        : password.isNotEmpty;
    final useWebSocket = useWebSocketRaw is bool
        ? useWebSocketRaw
        : wsEndpoint.isNotEmpty;
    final wsProtocols = <String>[];
    if (wsProtocolsRaw is List) {
      for (final entry in wsProtocolsRaw) {
        final value = entry?.toString().trim() ?? '';
        if (value.isNotEmpty) {
          wsProtocols.add(value);
        }
      }
    }
    return AccountRecord(
      jid: jid,
      password: rememberPassword ? password : '',
      host: host,
      port: port,
      resource: resource,
      rememberPassword: rememberPassword,
      useWebSocket: useWebSocket,
      wsEndpoint: wsEndpoint,
      wsProtocols: wsProtocols,
    );
  }
}
