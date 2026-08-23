import 'package:xmpp_stone/src/data/Jid.dart';

class XmppTcpEndpoint {
  const XmppTcpEndpoint({
    required this.host,
    required this.port,
    required this.directTls,
    this.tlsHost,
  });

  final String host;
  final int port;
  final bool directTls;
  final String? tlsHost;
}

class XmppQuicEndpoint {
  const XmppQuicEndpoint({
    required this.host,
    required this.port,
    this.tlsHost,
  });

  final String host;
  final int port;
  final String? tlsHost;
}

class XmppAccountSettings {
  String name;
  String username;
  String domain;
  String? resource = '';
  String password;
  String? host;
  int port;
  bool useWebSocket = false;
  bool useWebTransport = false;
  bool directTls = false;
  String? wsUrl;
  String? wsHost;
  int? wsPort;
  String? wsPath;
  List<XmppTcpEndpoint>? tcpEndpoints;
  List<XmppQuicEndpoint>? quicEndpoints;
  bool preferSasl2 = true;
  bool useBind2 = true;
  bool sasl2SendUserAgent = true;
  String? sasl2UserAgentId;
  String? sasl2Software;
  String? sasl2Device;
  bool iapEnabled = true;
  bool iapIncludeConfigVersion = true;
  bool iapPipeliningEnabled = true;
  String? iapConfigVersionScheme;
  String? iapConfigVersionValue;
  List<String>? sasl2CachedMechanisms;
  String? sasl2LastMechanism;
  List<String>? sasl2CachedBind2Features;
  List<String>? sasl2CachedFastMechanisms;
  bool bufferedWritesEnabled = true;
  int totalReconnections = 3;
  int reconnectionTimeout = 1000;
  bool ackEnabled = true;
  bool smResumable = true;

  // FAST (XEP-0484) token fields. When [fastEnabled] is true and a token
  // has been issued by the server, the client will attempt to use HT2-* (or
  // HT-*) authentication on the next connection instead of SCRAM.
  bool fastEnabled = true;

  /// The FAST token last issued by the server, base64-encoded.
  String? fastToken;

  /// ISO-8601 expiry timestamp for [fastToken].
  String? fastTokenExpiry;

  /// Wire-name of the preferred FAST mechanism agreed with the server
  /// (e.g. "HT2-SHA-256-NONE").
  String? fastMechanism;

  /// Invoked whenever the FAST credentials ([fastToken], [fastTokenExpiry]
  /// and [fastMechanism]) change, so that the embedding application can
  /// persist them and reuse the token on the next (first) connection.
  ///
  /// The callback is also invoked with a cleared token when FAST
  /// authentication fails, so that stale tokens are dropped from storage.
  void Function(XmppAccountSettings account)? onFastCredentialsChanged;

  XmppAccountSettings(
    this.name,
    this.username,
    this.domain,
    this.password,
    this.port, {
    this.host,
    this.resource,
    this.useWebSocket = false,
    this.directTls = false,
    this.wsUrl,
    this.wsHost,
    this.wsPort,
    this.wsPath,
    this.tcpEndpoints,
    this.quicEndpoints,
  });

  Jid get fullJid => Jid(username, domain, resource);

  /// Stores a freshly issued FAST token together with its (optional) expiry
  /// and notifies [onFastCredentialsChanged].
  void storeFastToken(String token, String? expiry) {
    fastToken = token;
    fastTokenExpiry = expiry;
    _notifyFastCredentialsChanged();
  }

  /// Clears the stored FAST credentials, e.g. after an expired or rejected
  /// token, so the next connection falls back to SCRAM. Notifies
  /// [onFastCredentialsChanged] when something was actually cleared.
  void clearFastToken() {
    if (fastToken == null && fastTokenExpiry == null && fastMechanism == null) {
      return;
    }
    fastToken = null;
    fastTokenExpiry = null;
    fastMechanism = null;
    _notifyFastCredentialsChanged();
  }

  void _notifyFastCredentialsChanged() {
    final callback = onFastCredentialsChanged;
    if (callback != null) {
      callback(this);
    }
  }

  /// for `port` setting by default used default XMPP port 5222, for the Web platform set it manually via [XmppAccountSettings.port]
  static XmppAccountSettings fromJid(String jid, String password) {
    var fullJid = Jid.fromFullJid(jid);
    var accountSettings =
        XmppAccountSettings(jid, fullJid.local, fullJid.domain, password, 5222);
    if (fullJid.resource != null && fullJid.resource!.isNotEmpty) {
      accountSettings.resource = fullJid.resource;
    }

    return accountSettings;
  }
}
