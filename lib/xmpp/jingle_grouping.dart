import 'package:xmpp_stone/xmpp_stone.dart';

import '../av/sdp_mapper.dart';

List<String> contentNamesFor(List<JingleContent> contents) {
  final names = <String>[];
  for (final content in contents) {
    final description = content.rtpDescription;
    if (description == null) {
      continue;
    }
    final name = content.name.isEmpty ? description.media : content.name;
    if (name.isNotEmpty && !names.contains(name)) {
      names.add(name);
    }
  }
  return names;
}

List<String> extractBundleGroupNames(
  IqStanza stanza, {
  required String groupingNamespace,
  required String groupingBundle,
}) {
  final jingle = stanza.getChild('jingle');
  if (jingle == null) {
    return const [];
  }
  for (final child in jingle.children) {
    if (child.name != 'group') {
      continue;
    }
    if (child.getAttribute('xmlns')?.value != groupingNamespace) {
      continue;
    }
    final semantics = child.getAttribute('semantics')?.value ?? '';
    if (semantics != groupingBundle) {
      continue;
    }
    final names = <String>[];
    for (final content in child.children) {
      if (content.name != 'content') {
        continue;
      }
      final name = content.getAttribute('name')?.value ?? '';
      if (name.isNotEmpty && !names.contains(name)) {
        names.add(name);
      }
    }
    return names;
  }
  return const [];
}

List<String> bundleGroupNamesForContents(List<JingleContent> contents) {
  String? audioName;
  String? videoName;
  final extras = <String>[];
  for (final content in contents) {
    final description = content.rtpDescription;
    if (description == null) {
      continue;
    }
    final name = content.name.isEmpty ? description.media : content.name;
    if (name.isEmpty) {
      continue;
    }
    final media = description.media.toLowerCase();
    if (media == 'audio') {
      audioName ??= name;
      continue;
    }
    if (media == 'video') {
      videoName ??= name;
      continue;
    }
    if (!extras.contains(name)) {
      extras.add(name);
    }
  }
  final names = <String>[];
  if (audioName != null) {
    names.add(audioName);
  }
  if (videoName != null) {
    names.add(videoName);
  }
  names.addAll(extras);
  return names;
}

String? bundleTransportNameForMappings(List<JingleSdpMapping> mappings) {
  for (final mapping in mappings) {
    if (mapping.description.media.toLowerCase() == 'audio' &&
        mapping.contentName.isNotEmpty) {
      return mapping.contentName;
    }
  }
  for (final mapping in mappings) {
    if (mapping.contentName.isNotEmpty) {
      return mapping.contentName;
    }
  }
  return null;
}

void attachBundleGroup(
  IqStanza stanza,
  List<String> names, {
  required String groupingNamespace,
  required String groupingBundle,
}) {
  if (names.length < 2) {
    return;
  }
  final jingle = stanza.getChild('jingle');
  if (jingle == null) {
    return;
  }
  for (final child in jingle.children) {
    if (child.name == 'group' &&
        child.getAttribute('xmlns')?.value == groupingNamespace) {
      return;
    }
  }
  final group = XmppElement()..name = 'group';
  group.addAttribute(XmppAttribute('xmlns', groupingNamespace));
  group.addAttribute(XmppAttribute('semantics', groupingBundle));
  for (final name in names) {
    if (name.isEmpty) {
      continue;
    }
    final content = XmppElement()..name = 'content';
    content.addAttribute(XmppAttribute('name', name));
    group.addChild(content);
  }
  if (group.children.isEmpty) {
    return;
  }
  jingle.addChild(group);
}
