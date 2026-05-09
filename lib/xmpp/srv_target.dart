class XmppSrvTarget {
  XmppSrvTarget({
    required this.host,
    required this.port,
    required this.priority,
    required this.weight,
    required this.directTls,
  });

  final String host;
  final int port;
  final int priority;
  final int weight;
  final bool directTls;
}

/// Returns the subset of [candidates] permitted by the user's transport
/// allow-flags.
///
/// `_xmpps-client._tcp` (Direct TLS) records are kept only when
/// [allowDirectTls] is true; `_xmpp-client._tcp` (plain TCP) records are kept
/// only when [allowPlainTcp] is true. The flags are independent allow-lists,
/// so disabling both yields an empty list.
List<XmppSrvTarget> filterTcpSrvCandidatesByTransport(
  List<XmppSrvTarget> candidates, {
  required bool allowDirectTls,
  required bool allowPlainTcp,
}) {
  return candidates
      .where((c) => c.directTls ? allowDirectTls : allowPlainTcp)
      .toList(growable: false);
}
