import 'package:xmpp_stone/xmpp_stone.dart';

enum DiscoveredJidKind { person, room, unknown }

class JidDiscoveryResult {
  const JidDiscoveryResult({
    required this.kind,
    this.features = const <String>{},
    this.identityName,
  });

  final DiscoveredJidKind kind;
  final Set<String> features;
  final String? identityName;
}

const String _discoInfoNamespace = 'http://jabber.org/protocol/disco#info';
const String _mucNamespace = 'http://jabber.org/protocol/muc';

JidDiscoveryResult classifyJidFromDiscoInfo(IqStanza? discoInfo) {
  if (discoInfo == null || discoInfo.type != IqStanzaType.RESULT) {
    return const JidDiscoveryResult(kind: DiscoveredJidKind.unknown);
  }
  final query = discoInfo.getChild('query');
  if (query == null ||
      query.getAttribute('xmlns')?.value != _discoInfoNamespace) {
    return const JidDiscoveryResult(kind: DiscoveredJidKind.unknown);
  }

  final features = <String>{};
  var hasRoomIdentity = false;
  var hasAccountIdentity = false;
  var hasImServerIdentity = false;
  String? identityName;

  for (final child in query.children) {
    if (child.name == 'identity') {
      final category = child.getAttribute('category')?.value?.toLowerCase();
      final name = child.getAttribute('name')?.value?.trim();
      if ((identityName?.isEmpty ?? true) && name != null && name.isNotEmpty) {
        identityName = name;
      }
      if (category == 'conference') {
        hasRoomIdentity = true;
      } else if (category == 'account' || category == 'client') {
        hasAccountIdentity = true;
      } else if (category == 'server') {
        final type = child.getAttribute('type')?.value?.toLowerCase();
        if (type == 'im') {
          hasImServerIdentity = true;
        }
      }
    } else if (child.name == 'feature') {
      final value = child.getAttribute('var')?.value?.trim();
      if (value != null && value.isNotEmpty) {
        features.add(value);
      }
    }
  }

  if (hasRoomIdentity || features.contains(_mucNamespace)) {
    return JidDiscoveryResult(
      kind: DiscoveredJidKind.room,
      features: features,
      identityName: identityName,
    );
  }
  if (hasAccountIdentity || hasImServerIdentity) {
    return JidDiscoveryResult(
      kind: DiscoveredJidKind.person,
      features: features,
      identityName: identityName,
    );
  }
  return JidDiscoveryResult(
    kind: DiscoveredJidKind.unknown,
    features: features,
    identityName: identityName,
  );
}
