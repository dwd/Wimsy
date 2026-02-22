import 'package:wimsy/av/call_session.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

class JingleSdpMapping {
  const JingleSdpMapping({
    required this.description,
    required this.transport,
  });

  final JingleRtpDescription description;
  final JingleIceTransport transport;
}

JingleSdpMapping mapSdpToJingle({
  required String sdp,
  required CallMediaKind mediaKind,
}) {
  final lines = sdp.split('\n').map((line) => line.trim()).toList();
  String? ufrag;
  String? pwd;
  JingleDtlsFingerprint? fingerprint;
  final payloadTypes = <JingleRtpPayloadType>[];

  for (final line in lines) {
    if (line.startsWith('a=ice-ufrag:')) {
      ufrag = line.substring('a=ice-ufrag:'.length).trim();
      continue;
    }
    if (line.startsWith('a=ice-pwd:')) {
      pwd = line.substring('a=ice-pwd:'.length).trim();
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
      payloadTypes.add(JingleRtpPayloadType(
        id: id,
        name: name,
        clockRate: clockRate,
        channels: channels,
      ));
    }
  }

  final description = JingleRtpDescription(
    media: mediaKind == CallMediaKind.video ? 'video' : 'audio',
    payloadTypes: payloadTypes,
  );
  final transport = JingleIceTransport(
    ufrag: ufrag ?? '',
    password: pwd ?? '',
    candidates: const [],
    fingerprint: fingerprint,
  );

  return JingleSdpMapping(description: description, transport: transport);
}

String buildMinimalSdpFromJingle({
  required JingleRtpDescription description,
  required JingleIceTransport transport,
}) {
  final buffer = StringBuffer();
  buffer.writeln('v=0');
  buffer.writeln('o=- 0 0 IN IP4 127.0.0.1');
  buffer.writeln('s=-');
  buffer.writeln('t=0 0');
  buffer.writeln('a=ice-ufrag:${transport.ufrag}');
  buffer.writeln('a=ice-pwd:${transport.password}');
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
  }
  return buffer.toString();
}
