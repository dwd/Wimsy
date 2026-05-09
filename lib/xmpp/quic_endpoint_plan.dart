import 'package:xmpp_stone/xmpp_stone.dart';

import 'srv_target.dart';

List<XmppQuicEndpoint> buildQuicEndpointPlan({
  required String domain,
  List<XmppSrvTarget> srvCandidates = const <XmppSrvTarget>[],
}) {
  if (srvCandidates.isEmpty) {
    return const <XmppQuicEndpoint>[];
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
