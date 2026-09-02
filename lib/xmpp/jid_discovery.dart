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

/// Search fields which can reasonably identify a person in an XEP-0055
/// directory, in order of usefulness.
const List<String> sensibleJidSearchFields = [
  'jid',
  'nick',
  'first',
  'last',
  'email',
];

/// Reads the fields advertised by either a legacy or data-form XEP-0055 form.
Set<String> parseJidSearchFields(IqStanza? response) {
  if (response == null || response.type != IqStanzaType.RESULT) return const {};
  final query = response.getChild('query');
  if (query?.getAttribute('xmlns')?.value != jidSearchNamespace) {
    return const {};
  }
  final fields = <String>{};
  for (final child in query!.children) {
    final childName = child.name;
    if (childName != null && sensibleJidSearchFields.contains(childName)) {
      fields.add(childName);
    }
    if (child.name == 'x' &&
        child.getAttribute('xmlns')?.value == 'jabber:x:data') {
      for (final field in child.children.where(
        (item) => item.name == 'field',
      )) {
        final name = field.getAttribute('var')?.value?.trim().toLowerCase();
        if (name != null && sensibleJidSearchFields.contains(name)) {
          fields.add(name);
        }
      }
    }
  }
  return fields;
}

bool hasJidSearchDataForm(IqStanza? response) {
  final query = response?.getChild('query');
  return response?.type == IqStanzaType.RESULT &&
      query?.getAttribute('xmlns')?.value == jidSearchNamespace &&
      query!.children.any(
        (child) =>
            child.name == 'x' &&
            child.getAttribute('xmlns')?.value == 'jabber:x:data',
      );
}

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
  final legacyItems = query!.children.where((child) => child.name == 'item');
  final dataFormItems = query.children
      .where(
        (child) =>
            child.name == 'x' &&
            child.getAttribute('xmlns')?.value == 'jabber:x:data',
      )
      .expand((form) => form.children.where((child) => child.name == 'item'));
  for (final item in [...legacyItems, ...dataFormItems]) {
    final values = <String, String>{};
    for (final field in item.children.where((child) => child.name == 'field')) {
      final key = field.getAttribute('var')?.value?.trim().toLowerCase();
      final value = field.getChild('value')?.textValue?.trim();
      if (key != null && value != null && value.isNotEmpty) values[key] = value;
    }
    final jid = (item.getAttribute('jid')?.value ?? values['jid'] ?? '').trim();
    if (jid.isEmpty || !seen.add(jid.toLowerCase())) {
      continue;
    }
    String? name;
    for (final field in const [
      'nick',
      'nickname',
      'first',
      'given',
      'last',
      'family',
      'fn',
    ]) {
      final value = item.getChild(field)?.textValue?.trim() ?? values[field];
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
