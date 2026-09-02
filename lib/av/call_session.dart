enum CallDirection { incoming, outgoing }

enum CallMediaKind { audio, video }

enum CallState { ringing, active, ended, declined, failed }

class CallSession {
  CallSession({
    required this.sid,
    required this.peerBareJid,
    required this.direction,
    required this.video,
    required this.state,
  });

  final String sid;
  final String peerBareJid;
  final CallDirection direction;
  final bool video;
  CallState state;
}

String formatCallDuration(Duration duration) {
  final totalSeconds = duration.inSeconds.clamp(0, 359999);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
