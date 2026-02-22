enum CallDirection {
  incoming,
  outgoing,
}

enum CallMediaKind {
  audio,
  video,
}

enum CallState {
  ringing,
  active,
  ended,
  declined,
  failed,
}

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
