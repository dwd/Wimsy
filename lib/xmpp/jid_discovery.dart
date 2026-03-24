import 'package:xmpp_stone/xmpp_stone.dart';

enum DiscoveredJidKind { person, room, unknown }

class JidDiscoveryResult {
  const JidDiscoveryResult({
    required this.kind,
    this.features = const <String>{},
  });

  final DiscoveredJidKind kind;
  final Set<String> features;
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

  for (final child in query.children) {
    if (child.name == 'identity') {
      final category = child.getAttribute('category')?.value?.toLowerCase();
      if (category == 'conference') {
        hasRoomIdentity = true;
      } else if (category == 'account') {
        hasAccountIdentity = true;
      }
    } else if (child.name == 'feature') {
      final value = child.getAttribute('var')?.value?.trim();
      if (value != null && value.isNotEmpty) {
        features.add(value);
      }
    }
  }

  if (hasRoomIdentity || features.contains(_mucNamespace)) {
    return JidDiscoveryResult(kind: DiscoveredJidKind.room, features: features);
  }
  if (hasAccountIdentity) {
    return JidDiscoveryResult(
      kind: DiscoveredJidKind.person,
      features: features,
    );
  }
  return JidDiscoveryResult(
    kind: DiscoveredJidKind.unknown,
    features: features,
  );
}
