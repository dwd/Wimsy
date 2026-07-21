class RoomEntry {
  RoomEntry({
    required this.roomJid,
    this.nick,
    this.subject,
    this.joined = false,
    this.occupantCount = 0,
    this.joinError = false,
    this.joinErrorCondition,
  });

  final String roomJid;
  final String? nick;
  final String? subject;
  final bool joined;
  final int occupantCount;
  /// True if the most recent join attempt was rejected by the server.
  final bool joinError;
  /// The XMPP error condition returned when [joinError] is true, e.g.
  /// "registration-required" or "forbidden".
  final String? joinErrorCondition;

  RoomEntry copyWith({
    String? nick,
    String? subject,
    bool? joined,
    int? occupantCount,
    bool? joinError,
    String? joinErrorCondition,
    bool clearJoinError = false,
  }) {
    return RoomEntry(
      roomJid: roomJid,
      nick: nick ?? this.nick,
      subject: subject ?? this.subject,
      joined: joined ?? this.joined,
      occupantCount: occupantCount ?? this.occupantCount,
      joinError: clearJoinError ? false : (joinError ?? this.joinError),
      joinErrorCondition: clearJoinError
          ? null
          : (joinErrorCondition ?? this.joinErrorCondition),
    );
  }
}
