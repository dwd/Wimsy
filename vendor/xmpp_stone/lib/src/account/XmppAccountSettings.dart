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
  bool sasl2SendUserAgent = true;
  String? sasl2UserAgentId;
  String? sasl2Software;
  String? sasl2Device;
  bool iapEnabled = true;
  bool iapIncludeConfigVersion = false;
  bool iapPipeliningEnabled = true;
  String? iapConfigVersionScheme;
  String? iapConfigVersionValue;
  List<String>? sasl2CachedMechanisms;
  String? sasl2LastMechanism;
  bool bufferedWritesEnabled = true;
  int totalReconnections = 3;
  int reconnectionTimeout = 1000;
  bool ackEnabled = true;
  bool smResumable = true;

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
