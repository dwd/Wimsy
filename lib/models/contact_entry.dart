class ContactEntry {
  ContactEntry({
    required this.jid,
    this.name,
    List<String>? groups,
    this.subscriptionType,
    this.isBookmark = false,
    this.bookmarkNick,
    this.bookmarkPassword,
    this.bookmarkAutoJoin = false,
  }) : groups = List.unmodifiable(groups ?? const []);

  final String jid;
  final String? name;
  final List<String> groups;
  final String? subscriptionType;
  final bool isBookmark;
  final String? bookmarkNick;
  final String? bookmarkPassword;
  final bool bookmarkAutoJoin;

  String get displayName => name?.isNotEmpty == true ? name! : jid;

  ContactEntry copyWith({
    String? name,
    List<String>? groups,
    String? subscriptionType,
    bool? isBookmark,
    String? bookmarkNick,
    String? bookmarkPassword,
    bool? bookmarkAutoJoin,
  }) {
    return ContactEntry(
      jid: jid,
      name: name ?? this.name,
      groups: groups ?? this.groups,
      subscriptionType: subscriptionType ?? this.subscriptionType,
      isBookmark: isBookmark ?? this.isBookmark,
      bookmarkNick: bookmarkNick ?? this.bookmarkNick,
      bookmarkPassword: bookmarkPassword ?? this.bookmarkPassword,
      bookmarkAutoJoin: bookmarkAutoJoin ?? this.bookmarkAutoJoin,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'jid': jid,
      'name': name,
      'groups': groups,
      'subscriptionType': subscriptionType,
      'isBookmark': isBookmark,
      'bookmarkNick': bookmarkNick,
      'bookmarkPassword': bookmarkPassword,
      'bookmarkAutoJoin': bookmarkAutoJoin,
    };
  }

  static ContactEntry? fromMap(Map<String, dynamic>? map) {
    if (map == null) {
      return null;
    }
    final jid = map['jid']?.toString() ?? '';
    if (jid.isEmpty) {
      return null;
    }
    final name = map['name']?.toString();
    final groupsRaw = map['groups'];
    final groups = <String>[];
    final subscriptionType = map['subscriptionType']?.toString();
    final isBookmark = map['isBookmark'] == true;
    final bookmarkNick = map['bookmarkNick']?.toString();
    final bookmarkPassword = map['bookmarkPassword']?.toString();
    final bookmarkAutoJoin = map['bookmarkAutoJoin'] == true;
    if (groupsRaw is List) {
      for (final entry in groupsRaw) {
        final value = entry.toString().trim();
        if (value.isNotEmpty) {
          groups.add(value);
        }
      }
    }
    return ContactEntry(
      jid: jid,
      name: name,
      groups: groups,
      subscriptionType: subscriptionType,
      isBookmark: isBookmark,
      bookmarkNick: bookmarkNick,
      bookmarkPassword: bookmarkPassword,
      bookmarkAutoJoin: bookmarkAutoJoin,
    );
  }
}
