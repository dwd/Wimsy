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

Future<XmppSrvTarget?> resolveXmppSrv(String domain) async {
  return null;
}
