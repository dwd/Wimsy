import 'package:xmpp_stone/xmpp_stone.dart';

class MujiParticipant {
  const MujiParticipant({
    required this.jid,
    required this.nick,
    this.muted = false,
    this.speaking = false,
  });

  final Jid jid;
  final String nick;
  final bool muted;
  final bool speaking;
}

class MujiSessionState {
  final Map<String, MujiParticipant> _participants = {};

  List<MujiParticipant> get participants =>
      _participants.values.toList(growable: false);

  void addParticipant(MujiParticipant participant) {
    final key = _jidKey(participant.jid);
    final existing = _participants[key];
    if (existing == null) {
      _participants[key] = participant;
      return;
    }
    _participants[key] = MujiParticipant(
      jid: participant.jid,
      nick: participant.nick,
      muted: existing.muted,
      speaking: existing.speaking,
    );
  }

  void removeParticipant(Jid jid) {
    _participants.remove(_jidKey(jid));
  }

  void setMuted(Jid jid, bool muted) {
    final key = _jidKey(jid);
    final existing = _participants[key];
    if (existing == null) {
      return;
    }
    _participants[key] = MujiParticipant(
      jid: existing.jid,
      nick: existing.nick,
      muted: muted,
      speaking: existing.speaking,
    );
  }

  void setActiveSpeaker(String nick) {
    for (final entry in _participants.entries) {
      final participant = entry.value;
      final speaking = participant.nick == nick;
      if (participant.speaking == speaking) {
        continue;
      }
      _participants[entry.key] = MujiParticipant(
        jid: participant.jid,
        nick: participant.nick,
        muted: participant.muted,
        speaking: speaking,
      );
    }
  }

  void clear() {
    _participants.clear();
  }

  String _jidKey(Jid jid) {
    return jid.fullJid ?? jid.userAtDomain;
  }
}
