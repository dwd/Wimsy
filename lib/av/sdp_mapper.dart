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
  final lines = sdp.split('\n').map((line) => line.trim()).toList();
  String? ufrag;
  String? pwd;
  String? mid;
  JingleDtlsFingerprint? fingerprint;
  final payloadTypes = <int, JingleRtpPayloadType>{};
  final feedback = <JingleRtpFeedback>[];
  final headerExtensions = <JingleRtpHeaderExtension>[];

  for (final line in lines) {
    if (line.startsWith('a=ice-ufrag:')) {
      ufrag = line.substring('a=ice-ufrag:'.length).trim();
      continue;
    }
    if (line.startsWith('a=ice-pwd:')) {
      pwd = line.substring('a=ice-pwd:'.length).trim();
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
  }

  final description = JingleRtpDescription(
    media: mediaKind == CallMediaKind.video ? 'video' : 'audio',
    payloadTypes: payloadTypes.values.toList(),
    rtcpFeedback: feedback,
    headerExtensions: headerExtensions,
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
  return buffer.toString();
}
