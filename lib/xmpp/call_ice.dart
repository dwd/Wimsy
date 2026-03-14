import 'package:xmpp_stone/xmpp_stone.dart';

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
