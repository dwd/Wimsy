import 'package:wimsy/av/call_session.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

class JingleSdpMapping {
  const JingleSdpMapping({
    required this.description,
    required this.transport,
    required this.contentName,
  });

  final JingleRtpDescription description;
  final JingleIceTransport transport;
  final String contentName;
}

JingleSdpMapping mapSdpToJingle({
  required String sdp,
  required CallMediaKind mediaKind,
}) {
  final parsed = _parseSdp(sdp);
  final desiredMedia = mediaKind == CallMediaKind.video ? 'video' : 'audio';
  final selected = parsed.sections.firstWhere(
    (section) => section.media == desiredMedia,
    orElse: () => parsed.sections.isNotEmpty ? parsed.sections.first : _SdpSection.empty(),
  );
  final targetLines = <String>[
    ...parsed.sessionLines,
    ...selected.lines,
  ];

  String? ufrag;
  String? pwd;
  String? mid;
  String? msid;
  JingleDtlsFingerprint? fingerprint;
  final payloadTypes = <int, JingleRtpPayloadType>{};
  final feedback = <JingleRtpFeedback>[];
  final headerExtensions = <JingleRtpHeaderExtension>[];
  final sources = <int, JingleRtpSource>{};
  final sourceGroups = <JingleRtpSourceGroup>[];

  for (final line in targetLines) {
    if (line.startsWith('a=ice-ufrag:')) {
      ufrag = line.substring('a=ice-ufrag:'.length).trim();
      continue;
    }
    if (line.startsWith('a=ice-pwd:')) {
      pwd = line.substring('a=ice-pwd:'.length).trim();
      continue;
    }
    if (line.startsWith('a=msid:')) {
      msid = line.substring('a=msid:'.length).trim();
      continue;
    }
    if (line.startsWith('a=mid:')) {
      mid = line.substring('a=mid:'.length).trim();
      continue;
    }
    if (line.startsWith('a=fingerprint:')) {
      final value = line.substring('a=fingerprint:'.length).trim();
      final parts = value.split(' ');
      if (parts.length >= 2) {
        fingerprint = JingleDtlsFingerprint(
          hash: parts[0].toLowerCase(),
          fingerprint: parts.sublist(1).join(' '),
        );
      }
      continue;
    }
    if (line.startsWith('a=rtpmap:')) {
      final rest = line.substring('a=rtpmap:'.length).trim();
      final spaceIndex = rest.indexOf(' ');
      if (spaceIndex <= 0) {
        continue;
      }
      final idValue = rest.substring(0, spaceIndex);
      final id = int.tryParse(idValue);
      if (id == null) {
        continue;
      }
      final codec = rest.substring(spaceIndex + 1);
      final codecParts = codec.split('/');
      if (codecParts.isEmpty) {
        continue;
      }
      final name = codecParts[0];
      final clockRate = codecParts.length > 1 ? int.tryParse(codecParts[1]) : null;
      final channels = codecParts.length > 2 ? int.tryParse(codecParts[2]) : null;
      payloadTypes[id] = JingleRtpPayloadType(
        id: id,
        name: name,
        clockRate: clockRate,
        channels: channels,
        parameters: payloadTypes[id]?.parameters ?? const {},
      );
      continue;
    }
    if (line.startsWith('a=fmtp:')) {
      final rest = line.substring('a=fmtp:'.length).trim();
      final spaceIndex = rest.indexOf(' ');
      if (spaceIndex <= 0) {
        continue;
      }
      final idValue = rest.substring(0, spaceIndex);
      final id = int.tryParse(idValue);
      if (id == null) {
        continue;
      }
      final params = rest.substring(spaceIndex + 1);
      final pairs = params.split(';');
      final current = payloadTypes[id];
      final parameters = <String, String>{
        ...?current?.parameters,
      };
      for (final pair in pairs) {
        final trimmed = pair.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        final eqIndex = trimmed.indexOf('=');
        if (eqIndex == -1) {
          parameters[trimmed] = '';
          continue;
        }
        final key = trimmed.substring(0, eqIndex).trim();
        final value = trimmed.substring(eqIndex + 1).trim();
        if (key.isEmpty) {
          continue;
        }
        parameters[key] = value;
      }
      if (current != null) {
        payloadTypes[id] = JingleRtpPayloadType(
          id: current.id,
          name: current.name,
          clockRate: current.clockRate,
          channels: current.channels,
          parameters: parameters,
        );
      } else {
        payloadTypes[id] = JingleRtpPayloadType(
          id: id,
          parameters: parameters,
        );
      }
      continue;
    }
    if (line.startsWith('a=rtcp-fb:')) {
      final rest = line.substring('a=rtcp-fb:'.length).trim();
      final parts = rest.split(' ');
      if (parts.length >= 2) {
        final type = parts[1];
        final subtype = parts.length > 2 ? parts[2] : null;
        feedback.add(JingleRtpFeedback(
          type: type,
          subtype: subtype,
        ));
      }
      continue;
    }
    if (line.startsWith('a=extmap:')) {
      final rest = line.substring('a=extmap:'.length).trim();
      final spaceIndex = rest.indexOf(' ');
      if (spaceIndex <= 0) {
        continue;
      }
      final idValue = rest.substring(0, spaceIndex);
      final id = int.tryParse(idValue.split('/').first);
      final uri = rest.substring(spaceIndex + 1).trim();
      if (id == null || uri.isEmpty) {
        continue;
      }
      headerExtensions.add(JingleRtpHeaderExtension(id: id, uri: uri));
      continue;
    }
    if (line.startsWith('a=ssrc:')) {
      final rest = line.substring('a=ssrc:'.length).trim();
      final spaceIndex = rest.indexOf(' ');
      if (spaceIndex <= 0) {
        continue;
      }
      final idValue = rest.substring(0, spaceIndex);
      final ssrc = int.tryParse(idValue);
      if (ssrc == null) {
        continue;
      }
      final param = rest.substring(spaceIndex + 1);
      final parts = param.split(':');
      final name = parts.first.trim();
      final value = parts.length > 1 ? parts.sublist(1).join(':').trim() : '';
      final existing = sources[ssrc];
      final parameters = <String, String>{
        ...?existing?.parameters,
      };
      if (name.isNotEmpty) {
        parameters[name] = value;
      }
      sources[ssrc] = JingleRtpSource(ssrc: ssrc, parameters: parameters);
      continue;
    }
    if (line.startsWith('a=ssrc-group:')) {
      final rest = line.substring('a=ssrc-group:'.length).trim();
      final parts = rest.split(' ');
      if (parts.length < 3) {
        continue;
      }
      final semantics = parts.first;
      final ssrcs = <int>[];
      for (final entry in parts.skip(1)) {
        final ssrc = int.tryParse(entry);
        if (ssrc != null) {
          ssrcs.add(ssrc);
        }
      }
      if (semantics.isNotEmpty && ssrcs.isNotEmpty) {
        sourceGroups.add(JingleRtpSourceGroup(
          semantics: semantics,
          sources: ssrcs,
        ));
      }
    }
  }

  if (msid != null && msid.isNotEmpty && sources.isNotEmpty) {
    final updated = <int, JingleRtpSource>{};
    for (final entry in sources.entries) {
      final parameters = <String, String>{...entry.value.parameters};
      parameters.putIfAbsent('msid', () => msid!);
      updated[entry.key] = JingleRtpSource(
        ssrc: entry.value.ssrc,
        parameters: parameters,
      );
    }
    sources
      ..clear()
      ..addAll(updated);
  }

  final description = JingleRtpDescription(
    media: mediaKind == CallMediaKind.video ? 'video' : 'audio',
    payloadTypes: payloadTypes.values.toList(),
    rtcpFeedback: feedback,
    headerExtensions: headerExtensions,
    sources: sources.values.toList(),
    sourceGroups: sourceGroups,
  );
  final transport = JingleIceTransport(
    ufrag: ufrag ?? '',
    password: pwd ?? '',
    candidates: const [],
    fingerprint: fingerprint,
  );

  final contentName = (mid == null || mid.isEmpty) ? description.media : mid;

  return JingleSdpMapping(
    description: description,
    transport: transport,
    contentName: contentName,
  );
}

List<JingleSdpMapping> mapSdpToJingleContents({required String sdp}) {
  final parsed = _parseSdp(sdp);
  final mappings = <JingleSdpMapping>[];
  for (final section in parsed.sections) {
    if (section.media != 'audio' && section.media != 'video') {
      continue;
    }
    final targetLines = <String>[
      ...parsed.sessionLines,
      ...section.lines,
    ];
    final mapping = _mapLinesToJingle(
      lines: targetLines,
      media: section.media,
    );
    if (mapping != null) {
      mappings.add(mapping);
    }
  }
  return mappings;
}

String buildMinimalSdpFromJingle({
  required JingleRtpDescription description,
  required JingleIceTransport transport,
  String? contentName,
}) {
  final buffer = StringBuffer();
  buffer.writeln('v=0');
  buffer.writeln('o=- 0 0 IN IP4 127.0.0.1');
  buffer.writeln('s=-');
  buffer.writeln('t=0 0');
  buffer.writeln('a=ice-ufrag:${transport.ufrag}');
  buffer.writeln('a=ice-pwd:${transport.password}');
  if (contentName != null && contentName.isNotEmpty) {
    buffer.writeln('a=mid:$contentName');
  }
  if (transport.fingerprint != null) {
    final fp = transport.fingerprint!;
    buffer.writeln('a=fingerprint:${fp.hash} ${fp.fingerprint}');
  }
  buffer.writeln('a=rtcp-mux');
  final payloadIds = description.payloadTypes.map((p) => p.id).join(' ');
  buffer.writeln('m=${description.media} 9 UDP/TLS/RTP/SAVPF $payloadIds');
  buffer.writeln('c=IN IP4 0.0.0.0');
  for (final payload in description.payloadTypes) {
    final name = payload.name ?? 'unknown';
    final clock = payload.clockRate ?? 0;
    final channels = payload.channels;
    final channelSuffix = channels != null && channels > 0 ? '/$channels' : '';
    buffer.writeln('a=rtpmap:${payload.id} $name/$clock$channelSuffix');
    if (payload.parameters.isNotEmpty) {
      final params = payload.parameters.entries
          .map((entry) => entry.value.isEmpty ? entry.key : '${entry.key}=${entry.value}')
          .join(';');
      buffer.writeln('a=fmtp:${payload.id} $params');
    }
  }
  for (final fb in description.rtcpFeedback) {
    final subtype = fb.subtype;
    buffer.writeln(
        'a=rtcp-fb:* ${fb.type}${subtype == null || subtype.isEmpty ? '' : ' $subtype'}');
  }
  for (final ext in description.headerExtensions) {
    buffer.writeln('a=extmap:${ext.id} ${ext.uri}');
  }
  for (final source in description.sources) {
    for (final entry in source.parameters.entries) {
      buffer.writeln('a=ssrc:${source.ssrc} ${entry.key}:${entry.value}');
    }
  }
  for (final group in description.sourceGroups) {
    buffer.writeln('a=ssrc-group:${group.semantics} ${group.sources.join(' ')}');
  }
  return buffer.toString();
}

String buildMinimalSdpFromJingleContents({
  required List<JingleContent> contents,
}) {
  final buffer = StringBuffer();
  buffer.writeln('v=0');
  buffer.writeln('o=- 0 0 IN IP4 127.0.0.1');
  buffer.writeln('s=-');
  buffer.writeln('t=0 0');
  if (contents.length > 1) {
    final bundle = contents
        .map((content) =>
            content.name.isEmpty ? content.rtpDescription?.media ?? '' : content.name)
        .where((name) => name.isNotEmpty)
        .join(' ');
    if (bundle.isNotEmpty) {
      buffer.writeln('a=group:BUNDLE $bundle');
    }
  }
  for (final content in contents) {
    final description = content.rtpDescription;
    final transport = content.iceTransport;
    if (description == null || transport == null) {
      continue;
    }
    buffer.write(_buildSdpSection(
      description: description,
      transport: transport,
      contentName: content.name.isEmpty ? description.media : content.name,
    ));
  }
  return buffer.toString();
}

String _buildSdpSection({
  required JingleRtpDescription description,
  required JingleIceTransport transport,
  required String contentName,
}) {
  final buffer = StringBuffer();
  buffer.writeln('m=${description.media} 9 UDP/TLS/RTP/SAVPF '
      '${description.payloadTypes.map((p) => p.id).join(' ')}');
  buffer.writeln('c=IN IP4 0.0.0.0');
  if (transport.ufrag.isNotEmpty) {
    buffer.writeln('a=ice-ufrag:${transport.ufrag}');
  }
  if (transport.password.isNotEmpty) {
    buffer.writeln('a=ice-pwd:${transport.password}');
  }
  if (contentName.isNotEmpty) {
    buffer.writeln('a=mid:$contentName');
  }
  if (transport.fingerprint != null) {
    final fp = transport.fingerprint!;
    buffer.writeln('a=fingerprint:${fp.hash} ${fp.fingerprint}');
  }
  buffer.writeln('a=rtcp-mux');
  final msid = description.sources
      .expand((source) => source.parameters.entries)
      .firstWhere(
        (entry) => entry.key == 'msid' && entry.value.isNotEmpty,
        orElse: () => const MapEntry('', ''),
      )
      .value;
  if (msid.isNotEmpty) {
    buffer.writeln('a=msid:$msid');
  }
  for (final payload in description.payloadTypes) {
    final name = payload.name ?? 'unknown';
    final clock = payload.clockRate ?? 0;
    final channels = payload.channels;
    final channelSuffix = channels != null && channels > 0 ? '/$channels' : '';
    buffer.writeln('a=rtpmap:${payload.id} $name/$clock$channelSuffix');
    if (payload.parameters.isNotEmpty) {
      final params = payload.parameters.entries
          .map((entry) => entry.value.isEmpty ? entry.key : '${entry.key}=${entry.value}')
          .join(';');
      buffer.writeln('a=fmtp:${payload.id} $params');
    }
  }
  for (final fb in description.rtcpFeedback) {
    final subtype = fb.subtype;
    buffer.writeln(
        'a=rtcp-fb:* ${fb.type}${subtype == null || subtype.isEmpty ? '' : ' $subtype'}');
  }
  for (final ext in description.headerExtensions) {
    buffer.writeln('a=extmap:${ext.id} ${ext.uri}');
  }
  for (final source in description.sources) {
    for (final entry in source.parameters.entries) {
      buffer.writeln('a=ssrc:${source.ssrc} ${entry.key}:${entry.value}');
    }
  }
  for (final group in description.sourceGroups) {
    buffer.writeln('a=ssrc-group:${group.semantics} ${group.sources.join(' ')}');
  }
  return buffer.toString();
}

class _SdpSection {
  _SdpSection({required this.media, required this.lines});

  factory _SdpSection.empty() => _SdpSection(media: '', lines: const []);

  final String media;
  final List<String> lines;
}

class _SdpParseResult {
  const _SdpParseResult({required this.sessionLines, required this.sections});

  final List<String> sessionLines;
  final List<_SdpSection> sections;
}

_SdpParseResult _parseSdp(String sdp) {
  final lines = sdp.split('\n').map((line) => line.trim()).toList();
  final sessionLines = <String>[];
  final sections = <_SdpSection>[];
  _SdpSection? current;
  for (final line in lines) {
    if (line.startsWith('m=')) {
      final media = line.substring(2).split(' ').first.trim();
      current = _SdpSection(media: media, lines: [line]);
      sections.add(current);
      continue;
    }
    if (current == null) {
      sessionLines.add(line);
    } else {
      current.lines.add(line);
    }
  }
  return _SdpParseResult(sessionLines: sessionLines, sections: sections);
}

JingleSdpMapping? _mapLinesToJingle({
  required List<String> lines,
  required String media,
}) {
  String? ufrag;
  String? pwd;
  String? mid;
  String? msid;
  JingleDtlsFingerprint? fingerprint;
  final payloadTypes = <int, JingleRtpPayloadType>{};
  final feedback = <JingleRtpFeedback>[];
  final headerExtensions = <JingleRtpHeaderExtension>[];
  final sources = <int, JingleRtpSource>{};
  final sourceGroups = <JingleRtpSourceGroup>[];

  for (final line in lines) {
    if (line.startsWith('a=ice-ufrag:')) {
      ufrag = line.substring('a=ice-ufrag:'.length).trim();
      continue;
    }
    if (line.startsWith('a=ice-pwd:')) {
      pwd = line.substring('a=ice-pwd:'.length).trim();
      continue;
    }
    if (line.startsWith('a=msid:')) {
      msid = line.substring('a=msid:'.length).trim();
      continue;
    }
    if (line.startsWith('a=mid:')) {
      mid = line.substring('a=mid:'.length).trim();
      continue;
    }
    if (line.startsWith('a=fingerprint:')) {
      final value = line.substring('a=fingerprint:'.length).trim();
      final parts = value.split(' ');
      if (parts.length >= 2) {
        fingerprint = JingleDtlsFingerprint(
          hash: parts[0].toLowerCase(),
          fingerprint: parts.sublist(1).join(' '),
        );
      }
      continue;
    }
    if (line.startsWith('a=rtpmap:')) {
      final rest = line.substring('a=rtpmap:'.length).trim();
      final spaceIndex = rest.indexOf(' ');
      if (spaceIndex <= 0) {
        continue;
      }
      final idValue = rest.substring(0, spaceIndex);
      final id = int.tryParse(idValue);
      if (id == null) {
        continue;
      }
      final codec = rest.substring(spaceIndex + 1);
      final codecParts = codec.split('/');
      if (codecParts.isEmpty) {
        continue;
      }
      final name = codecParts[0];
      final clockRate = codecParts.length > 1 ? int.tryParse(codecParts[1]) : null;
      final channels = codecParts.length > 2 ? int.tryParse(codecParts[2]) : null;
      payloadTypes[id] = JingleRtpPayloadType(
        id: id,
        name: name,
        clockRate: clockRate,
        channels: channels,
        parameters: payloadTypes[id]?.parameters ?? const {},
      );
      continue;
    }
    if (line.startsWith('a=fmtp:')) {
      final rest = line.substring('a=fmtp:'.length).trim();
      final spaceIndex = rest.indexOf(' ');
      if (spaceIndex <= 0) {
        continue;
      }
      final idValue = rest.substring(0, spaceIndex);
      final id = int.tryParse(idValue);
      if (id == null) {
        continue;
      }
      final params = rest.substring(spaceIndex + 1);
      final pairs = params.split(';');
      final current = payloadTypes[id];
      final parameters = <String, String>{
        ...?current?.parameters,
      };
      for (final pair in pairs) {
        final trimmed = pair.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        final eqIndex = trimmed.indexOf('=');
        if (eqIndex == -1) {
          parameters[trimmed] = '';
          continue;
        }
        final key = trimmed.substring(0, eqIndex).trim();
        final value = trimmed.substring(eqIndex + 1).trim();
        if (key.isEmpty) {
          continue;
        }
        parameters[key] = value;
      }
      if (current != null) {
        payloadTypes[id] = JingleRtpPayloadType(
          id: current.id,
          name: current.name,
          clockRate: current.clockRate,
          channels: current.channels,
          parameters: parameters,
        );
      } else {
        payloadTypes[id] = JingleRtpPayloadType(
          id: id,
          parameters: parameters,
        );
      }
      continue;
    }
    if (line.startsWith('a=rtcp-fb:')) {
      final rest = line.substring('a=rtcp-fb:'.length).trim();
      final parts = rest.split(' ');
      if (parts.length >= 2) {
        final type = parts[1];
        final subtype = parts.length > 2 ? parts[2] : null;
        feedback.add(JingleRtpFeedback(
          type: type,
          subtype: subtype,
        ));
      }
      continue;
    }
    if (line.startsWith('a=extmap:')) {
      final rest = line.substring('a=extmap:'.length).trim();
      final spaceIndex = rest.indexOf(' ');
      if (spaceIndex <= 0) {
        continue;
      }
      final idValue = rest.substring(0, spaceIndex);
      final id = int.tryParse(idValue.split('/').first);
      final uri = rest.substring(spaceIndex + 1).trim();
      if (id == null || uri.isEmpty) {
        continue;
      }
      headerExtensions.add(JingleRtpHeaderExtension(id: id, uri: uri));
      continue;
    }
    if (line.startsWith('a=ssrc:')) {
      final rest = line.substring('a=ssrc:'.length).trim();
      final spaceIndex = rest.indexOf(' ');
      if (spaceIndex <= 0) {
        continue;
      }
      final idValue = rest.substring(0, spaceIndex);
      final ssrc = int.tryParse(idValue);
      if (ssrc == null) {
        continue;
      }
      final param = rest.substring(spaceIndex + 1);
      final parts = param.split(':');
      final name = parts.first.trim();
      final value = parts.length > 1 ? parts.sublist(1).join(':').trim() : '';
      final existing = sources[ssrc];
      final parameters = <String, String>{
        ...?existing?.parameters,
      };
      if (name.isNotEmpty) {
        parameters[name] = value;
      }
      sources[ssrc] = JingleRtpSource(ssrc: ssrc, parameters: parameters);
      continue;
    }
    if (line.startsWith('a=ssrc-group:')) {
      final rest = line.substring('a=ssrc-group:'.length).trim();
      final parts = rest.split(' ');
      if (parts.length < 3) {
        continue;
      }
      final semantics = parts.first;
      final ssrcs = <int>[];
      for (final entry in parts.skip(1)) {
        final ssrc = int.tryParse(entry);
        if (ssrc != null) {
          ssrcs.add(ssrc);
        }
      }
      if (semantics.isNotEmpty && ssrcs.isNotEmpty) {
        sourceGroups.add(JingleRtpSourceGroup(
          semantics: semantics,
          sources: ssrcs,
        ));
      }
    }
  }

  if (payloadTypes.isEmpty) {
    return null;
  }

  if (msid != null && msid.isNotEmpty && sources.isNotEmpty) {
    final updated = <int, JingleRtpSource>{};
    for (final entry in sources.entries) {
      final parameters = <String, String>{...entry.value.parameters};
      parameters.putIfAbsent('msid', () => msid!);
      updated[entry.key] = JingleRtpSource(
        ssrc: entry.value.ssrc,
        parameters: parameters,
      );
    }
    sources
      ..clear()
      ..addAll(updated);
  }

  final description = JingleRtpDescription(
    media: media,
    payloadTypes: payloadTypes.values.toList(),
    rtcpFeedback: feedback,
    headerExtensions: headerExtensions,
    sources: sources.values.toList(),
    sourceGroups: sourceGroups,
  );
  final transport = JingleIceTransport(
    ufrag: ufrag ?? '',
    password: pwd ?? '',
    candidates: const [],
    fingerprint: fingerprint,
  );

  final contentName = (mid == null || mid.isEmpty) ? description.media : mid;

  return JingleSdpMapping(
    description: description,
    transport: transport,
    contentName: contentName,
  );
}
