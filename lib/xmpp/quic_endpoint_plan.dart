import 'package:xmpp_stone/xmpp_stone.dart';

import 'srv_target.dart';

List<XmppQuicEndpoint> buildQuicEndpointPlan({
  required String domain,
  String resolvedHost = '',
  int resolvedPort = 443,
  List<XmppSrvTarget> srvCandidates = const <XmppSrvTarget>[],
}) {
  if (srvCandidates.isEmpty) {
    if (resolvedHost.isEmpty) return const <XmppQuicEndpoint>[];
    return <XmppQuicEndpoint>[
      XmppQuicEndpoint(host: resolvedHost, port: resolvedPort, tlsHost: domain),
    ];
  }
  return srvCandidates
      .map(
        (candidate) => XmppQuicEndpoint(
          host: candidate.host,
          port: candidate.port,
          tlsHost: domain,
        ),
      )
      .toList();
}
