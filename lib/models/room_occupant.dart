import 'package:xmpp_stone/xmpp_stone.dart';

/// A single occupant of a joined MUC room, as tracked from the most recent
/// presence stanza we have seen for them.
///
/// Used to render the room occupant list (see the "N online" banner in the
/// chat header), showing avatar, nickname, role/affiliation chips and the
/// occupant's free-text presence status.
class RoomOccupant {
  RoomOccupant({
    required this.nick,
    this.role,
    this.affiliation,
    this.realJid,
    this.status,
    this.occupantId,
    this.isSelf = false,
    this.show,
  });

  /// The occupant's room nickname (the resource part of their occupant
  /// JID, `room@conference/nick`).
  final String nick;

  /// The occupant's MUC role in the room, e.g. "moderator", "participant",
  /// or "visitor", when disclosed by the server.
  final String? role;

  /// The occupant's MUC affiliation with the room, e.g. "owner", "admin",
  /// "member", or "outcast", when disclosed by the server.
  final String? affiliation;

  /// The occupant's real bare JID, when the room discloses it (e.g.
  /// non-anonymous rooms).
  final String? realJid;

  /// The occupant's free-text presence `<status/>` message, when present.
  final String? status;

  /// XEP-0421 anonymous unique occupant identifier, when the server
  /// includes it.
  final String? occupantId;

  /// Whether this occupant is the local user.
  final bool isSelf;

  /// The occupant's presence `<show/>` element (e.g. "away", "dnd"), when
  /// present. `null` means the occupant is online/available with no
  /// particular mode advertised, used to render the presence dot on their
  /// avatar.
  final PresenceShowElement? show;

  RoomOccupant copyWith({
    String? role,
    String? affiliation,
    String? realJid,
    String? status,
    String? occupantId,
    bool? isSelf,
    PresenceShowElement? show,
    bool clearRealJid = false,
    bool clearStatus = false,
    bool clearShow = false,
  }) {
    return RoomOccupant(
      nick: nick,
      role: role ?? this.role,
      affiliation: affiliation ?? this.affiliation,
      realJid: clearRealJid ? null : (realJid ?? this.realJid),
      status: clearStatus ? null : (status ?? this.status),
      occupantId: occupantId ?? this.occupantId,
      isSelf: isSelf ?? this.isSelf,
      show: clearShow ? null : (show ?? this.show),
    );
  }
}

/// Rank used to sort occupants by affiliation, with higher-privilege
/// affiliations listed first. Unknown/absent affiliations sort last.
int roomOccupantAffiliationRank(String? affiliation) {
  switch (affiliation) {
    case 'owner':
      return 0;
    case 'admin':
      return 1;
    case 'member':
      return 2;
    case 'outcast':
      return 4;
    default:
      return 3;
  }
}
