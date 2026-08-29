import 'package:xmpp_stone/xmpp_stone.dart';

enum DiscoveredJidKind { person, room, unknown }

class JidSuggestion {
  const JidSuggestion({
    required this.jid,
    required this.kind,
    this.name,
    this.isUnverified = false,
  });

  final String jid;
  final DiscoveredJidKind kind;
  final String? name;
  final bool isUnverified;
}

/// Matches directory and roster suggestions by either their JID or name.
bool jidSuggestionMatches(JidSuggestion suggestion, String input) {
  final query = input.trim().toLowerCase();
  if (query.isEmpty) {
    return false;
  }
  return suggestion.jid.toLowerCase().contains(query) ||
      (suggestion.name?.toLowerCase().contains(query) ?? false);
}

/// Resolves an incomplete person JID using search results or the local domain.
String? completeLocalPersonJid(
  String input,
  String? selfJid,
  Iterable<JidSuggestion> suggestions,
) {
  final localPart = input.trim();
  if (localPart.isEmpty || localPart.contains('@')) return null;
  for (final suggestion in suggestions) {
    if (suggestion.kind == DiscoveredJidKind.person) return suggestion.jid;
  }
  if (selfJid == null) return null;
  final domain = Jid.fromFullJid(selfJid).domain;
  return domain.isEmpty ? null : '$localPart@$domain';
}

class JidDiscoveryResult {
  const JidDiscoveryResult({
    required this.kind,
    this.features = const <String>{},
    this.identityName,
    this.description,
  });

  final DiscoveredJidKind kind;
  final Set<String> features;
  final String? identityName;
  final String? description;
}

const String _discoInfoNamespace = 'http://jabber.org/protocol/disco#info';
const String _mucNamespace = 'http://jabber.org/protocol/muc';
const String jidSearchNamespace = 'jabber:iq:search';

List<JidSuggestion> parseJidSearchResults(IqStanza? response) {
  if (response == null || response.type != IqStanzaType.RESULT) {
    return const [];
  }
  final query = response.getChild('query');
  if (query?.getAttribute('xmlns')?.value != jidSearchNamespace) {
    return const [];
  }
  final results = <JidSuggestion>[];
  final seen = <String>{};
  for (final item in query!.children.where((child) => child.name == 'item')) {
    final jid = item.getAttribute('jid')?.value?.trim() ?? '';
    if (jid.isEmpty || !seen.add(jid.toLowerCase())) {
      continue;
    }
    String? name;
    for (final field in const ['nick', 'first', 'last']) {
      final value = item.getChild(field)?.textValue?.trim();
      if (value != null && value.isNotEmpty) {
        name = name == null ? value : '$name $value';
      }
    }
    results.add(
      JidSuggestion(jid: jid, kind: DiscoveredJidKind.person, name: name),
    );
  }
  return results;
}

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
  String? description;

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
    } else if (child.name == 'x' &&
        child.getAttribute('xmlns')?.value == 'jabber:x:data') {
      for (final field in child.children.where(
        (item) => item.name == 'field',
      )) {
        if (field.getAttribute('var')?.value == 'muc#roominfo_description') {
          final value = field.getChild('value')?.textValue?.trim();
          if (value != null && value.isNotEmpty) {
            description = value;
          }
        }
      }
    }
  }

  if (hasRoomIdentity || features.contains(_mucNamespace)) {
    return JidDiscoveryResult(
      kind: DiscoveredJidKind.room,
      features: features,
      identityName: identityName,
      description: description,
    );
  }
  if (hasAccountIdentity || hasImServerIdentity) {
    return JidDiscoveryResult(
      kind: DiscoveredJidKind.person,
      features: features,
      identityName: identityName,
      description: description,
    );
  }
  return JidDiscoveryResult(
    kind: DiscoveredJidKind.unknown,
    features: features,
    identityName: identityName,
    description: description,
  );
}

/// Picks the most useful human-readable bookmark name for a discovered room.
String? discoveredRoomName(
  JidDiscoveryResult result, {
  String? discoItemsName,
}) {
  for (final candidate in [
    result.identityName,
    result.description,
    discoItemsName,
  ]) {
    final value = candidate?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}
