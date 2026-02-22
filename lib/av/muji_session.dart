import 'package:xmpp_stone/xmpp_stone.dart';

class MujiParticipant {
  const MujiParticipant({
    required this.jid,
    required this.nick,
  });

  final Jid jid;
  final String nick;
}

class MujiSessionState {
  final Map<String, MujiParticipant> _participants = {};

  List<MujiParticipant> get participants =>
      _participants.values.toList(growable: false);

  void addParticipant(MujiParticipant participant) {
    _participants[_jidKey(participant.jid)] = participant;
  }

  void removeParticipant(Jid jid) {
    _participants.remove(_jidKey(jid));
  }

  void clear() {
    _participants.clear();
  }

  String _jidKey(Jid jid) {
    return jid.fullJid ?? jid.userAtDomain;
  }
}
