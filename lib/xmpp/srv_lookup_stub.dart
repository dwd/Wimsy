import 'srv_target.dart';

Future<XmppSrvTarget?> resolveXmppSrv(String domain) async {
  final candidates = await resolveXmppSrvCandidates(domain);
  if (candidates.isEmpty) {
    return null;
  }
  return candidates.first;
}

Future<List<XmppSrvTarget>> resolveXmppSrvCandidates(String domain) async {
  return const [];
}

Future<List<XmppSrvTarget>> resolveXmppQuicSrvCandidates(String domain) async {
  return const [];
}
