import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import '../av/call_session.dart';

JingleIceTransport mergeIceTransports(
  JingleIceTransport existing,
  JingleIceTransport update,
) {
  final mergedCandidates = <JingleIceCandidate>[];
  final candidateKeys = <String>{};
  void addCandidate(JingleIceCandidate candidate) {
    final key =
        '${candidate.foundation}|${candidate.component}|'
        '${candidate.protocol}|${candidate.priority}|${candidate.ip}|'
        '${candidate.port}|${candidate.type}|${candidate.generation ?? ''}';
    if (candidateKeys.add(key)) {
      mergedCandidates.add(candidate);
    }
  }

  for (final candidate in update.candidates) {
    addCandidate(candidate);
  }
  for (final candidate in existing.candidates) {
    addCandidate(candidate);
  }

  final ufrag = update.ufrag.isNotEmpty ? update.ufrag : existing.ufrag;
  final password = update.password.isNotEmpty
      ? update.password
      : existing.password;
  final fingerprint = update.fingerprint ?? existing.fingerprint;

  return JingleIceTransport(
    ufrag: ufrag,
    password: password,
    candidates: mergedCandidates,
    fingerprint: fingerprint,
  );
}

String buildCandidateLine(JingleIceCandidate candidate) {
  final buffer = StringBuffer();
  buffer.write('candidate:${candidate.foundation} ');
  buffer.write('${candidate.component} ');
  buffer.write('${candidate.protocol} ');
  buffer.write('${candidate.priority} ');
  buffer.write('${candidate.ip} ');
  buffer.write('${candidate.port} ');
  buffer.write('typ ${candidate.type}');
  return buffer.toString();
}

JingleIceCandidate? parseIceCandidate(String? candidateLine) {
  if (candidateLine == null || candidateLine.isEmpty) {
    return null;
  }
  final value = candidateLine.startsWith('candidate:')
      ? candidateLine.substring('candidate:'.length)
      : candidateLine;
  final parts = value.split(' ');
  if (parts.length < 8) {
    return null;
  }
  final foundation = parts[0];
  final component = int.tryParse(parts[1]);
  final protocol = parts[2];
  final priority = int.tryParse(parts[3]);
  final ip = parts[4];
  final port = int.tryParse(parts[5]);
  final typeIndex = parts.indexOf('typ');
  final type = typeIndex >= 0 && typeIndex + 1 < parts.length
      ? parts[typeIndex + 1]
      : '';
  if (component == null || priority == null || port == null || type.isEmpty) {
    return null;
  }
  return JingleIceCandidate(
    foundation: foundation,
    component: component,
    protocol: protocol,
    priority: priority,
    ip: ip,
    port: port,
    type: type,
    id: AbstractStanza.getRandomId(),
    generation: 0,
  );
}

JingleIceTransport transportInfoTransport(
  JingleIceTransport base,
  JingleIceCandidate candidate,
) {
  return JingleIceTransport(
    ufrag: base.ufrag,
    password: base.password,
    candidates: [candidate],
    // Fingerprints are exchanged during session-initiate/accept.
    // Some clients treat fingerprints in transport-info as a change.
    fingerprint: null,
  );
}

/// Default CIDR ranges used by common local virtualization/container bridge
/// networks: Docker's default and custom bridge networks, and libvirt's
/// default/secondary NAT networks. These same ranges are sometimes used by
/// real production LANs too (e.g. some corporate/aircraft Wi-Fi networks),
/// so candidates within them must never be dropped outright - they're only
/// deprioritized (sent to the peer after a short delay) via
/// [isLikelyVirtualBridgeCandidate], once candidates from other interfaces
/// have already had a chance to be sent and tried first.
const List<String> virtualBridgeCidrs = [
  '172.16.0.0/12', // Docker default + custom bridge networks
  '192.168.122.0/24', // libvirt default NAT network
  '192.168.123.0/24', // libvirt secondary NAT network
];

/// Whether [candidate] looks like it came from a local Docker/libvirt bridge
/// interface, based on [virtualBridgeCidrs]. Only `host` candidates are
/// considered, since srflx/relay candidates reflect externally-visible
/// addresses rather than the local bridge interface itself.
bool isLikelyVirtualBridgeCandidate(JingleIceCandidate candidate) {
  if (candidate.type != 'host') {
    return false;
  }
  return virtualBridgeCidrs.any((cidr) => _ipv4InCidr(candidate.ip, cidr));
}

bool _ipv4InCidr(String ip, String cidr) {
  final parts = cidr.split('/');
  if (parts.length != 2) {
    return false;
  }
  final maskBits = int.tryParse(parts[1]);
  final ipInt = _ipv4ToInt(ip);
  final netInt = _ipv4ToInt(parts[0]);
  if (maskBits == null || ipInt == null || netInt == null) {
    return false;
  }
  final mask = maskBits == 0 ? 0 : (0xFFFFFFFF << (32 - maskBits)) & 0xFFFFFFFF;
  return (ipInt & mask) == (netInt & mask);
}

int? _ipv4ToInt(String ip) {
  final segments = ip.split('.');
  if (segments.length != 4) {
    return null;
  }
  var result = 0;
  for (final segment in segments) {
    final value = int.tryParse(segment);
    if (value == null || value < 0 || value > 255) {
      return null;
    }
    result = (result << 8) | value;
  }
  return result;
}

String resolveCandidateContentName({
  required RTCIceCandidate candidate,
  required List<String>? contentNames,
  required CallMediaKind defaultKind,
}) {
  final byMid = candidate.sdpMid;
  if (byMid != null && byMid.isNotEmpty) {
    return byMid;
  }
  final index = candidate.sdpMLineIndex;
  if (index != null &&
      contentNames != null &&
      index >= 0 &&
      index < contentNames.length) {
    return contentNames[index];
  }
  return contentNames?.first ??
      (defaultKind == CallMediaKind.video ? 'video' : 'audio');
}
