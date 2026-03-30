import 'package:xmpp_stone/xmpp_stone.dart';

import 'srv_target.dart';

List<XmppTcpEndpoint> buildTcpEndpointPlan({
  required String domain,
  required String resolvedHost,
  required int resolvedPort,
  required bool directTls,
  List<XmppSrvTarget> srvCandidates = const <XmppSrvTarget>[],
}) {
  if (srvCandidates.isNotEmpty) {
    return srvCandidates
        .map(
          (candidate) => XmppTcpEndpoint(
            host: candidate.host,
            port: candidate.port,
            directTls: candidate.directTls,
            tlsHost: domain,
          ),
        )
        .toList();
  }
  final host = resolvedHost.isNotEmpty ? resolvedHost : domain;
  return <XmppTcpEndpoint>[
    XmppTcpEndpoint(
      host: host,
      port: resolvedPort,
      directTls: directTls,
      tlsHost: domain,
    ),
  ];
}
