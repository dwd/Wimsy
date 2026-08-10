import 'package:xmpp_stone/xmpp_stone.dart';

/// The mode used to decide whether an incoming groupchat message should
/// trigger a notification, absent any "after I sent a message" override.
enum MucNotifyMode {
  /// Notify about every message sent to the room.
  all,

  /// Only notify about messages that mention the user's in-room nickname,
  /// either because the message begins with the nickname followed by
  /// punctuation (e.g. "dave: hello"), or because it contains "@" followed
  /// by the nickname (e.g. "hello @dave").
  mentions,
}

/// Per-room configuration controlling when groupchat (MUC) notifications
/// should be shown.
///
/// Instances are stored as a child element of the room's bookmark (inside
/// the `<extensions>` element defined by XEP-0402), using the
/// `https://wimsy.cridland.io/muc-notify` namespace, so that the setting is
/// synchronized across all of the user's clients via PEP.
class MucNotifySettings {
  const MucNotifySettings({
    this.mode = MucNotifyMode.mentions,
    this.afterOwnMessagePeriod,
    this.alwaysAfterOwnMessage = false,
  });

  /// Whether to notify about all messages, or only ones that mention the
  /// user's in-room nickname.
  final MucNotifyMode mode;

  /// If set (and [alwaysAfterOwnMessage] is false), notify about *all*
  /// messages received within this period after the user last sent a
  /// message to the room, regardless of [mode].
  final Duration? afterOwnMessagePeriod;

  /// If true, notify about *all* messages received at any point after the
  /// user last sent a message to the room, irrespective of how long ago
  /// that was, regardless of [mode].
  final bool alwaysAfterOwnMessage;

  static const defaultSettings = MucNotifySettings();

  static const String namespace = 'https://wimsy.cridland.io/muc-notify';
  static const String elementName = 'notify';

  MucNotifySettings copyWith({
    MucNotifyMode? mode,
    Duration? afterOwnMessagePeriod,
    bool clearAfterOwnMessagePeriod = false,
    bool? alwaysAfterOwnMessage,
  }) {
    return MucNotifySettings(
      mode: mode ?? this.mode,
      afterOwnMessagePeriod: clearAfterOwnMessagePeriod
          ? null
          : (afterOwnMessagePeriod ?? this.afterOwnMessagePeriod),
      alwaysAfterOwnMessage: alwaysAfterOwnMessage ?? this.alwaysAfterOwnMessage,
    );
  }

  /// Serializes these settings into a `<notify/>` element in the
  /// [namespace], suitable for embedding into a bookmark's `<extensions>`.
  XmppElement toXml() {
    final element = XmppElement()..name = elementName;
    element.addAttribute(XmppAttribute('xmlns', namespace));
    element.addAttribute(
      XmppAttribute('mode', mode == MucNotifyMode.all ? 'all' : 'mentions'),
    );
    if (alwaysAfterOwnMessage) {
      element.addAttribute(XmppAttribute('after-own', 'always'));
    } else if (afterOwnMessagePeriod != null &&
        afterOwnMessagePeriod!.inSeconds > 0) {
      element.addAttribute(
        XmppAttribute('after-own', afterOwnMessagePeriod!.inSeconds.toString()),
      );
    }
    return element;
  }

  /// Parses a `<notify/>` element (as produced by [toXml]) back into
  /// [MucNotifySettings]. Returns null if [element] is not a recognizable
  /// notify-settings element.
  static MucNotifySettings? fromXml(XmppElement? element) {
    if (element == null ||
        element.name != elementName ||
        element.getAttribute('xmlns')?.value != namespace) {
      return null;
    }
    final modeAttr = element.getAttribute('mode')?.value;
    final mode = modeAttr == 'all' ? MucNotifyMode.all : MucNotifyMode.mentions;
    final afterOwn = element.getAttribute('after-own')?.value;
    var alwaysAfterOwnMessage = false;
    Duration? afterOwnMessagePeriod;
    if (afterOwn == 'always') {
      alwaysAfterOwnMessage = true;
    } else if (afterOwn != null && afterOwn.isNotEmpty) {
      final seconds = int.tryParse(afterOwn);
      if (seconds != null && seconds > 0) {
        afterOwnMessagePeriod = Duration(seconds: seconds);
      }
    }
    return MucNotifySettings(
      mode: mode,
      afterOwnMessagePeriod: afterOwnMessagePeriod,
      alwaysAfterOwnMessage: alwaysAfterOwnMessage,
    );
  }

  /// Finds and parses a notify-settings element among [extensions]'s
  /// children, e.g. the children of a bookmark's `<extensions>` element.
  static MucNotifySettings? fromExtensions(XmppElement? extensions) {
    if (extensions == null) {
      return null;
    }
    for (final child in extensions.children) {
      final parsed = fromXml(child);
      if (parsed != null) {
        return parsed;
      }
    }
    return null;
  }

  Map<String, dynamic> toMap() {
    return {
      'mode': mode == MucNotifyMode.all ? 'all' : 'mentions',
      'afterOwnMessageSeconds': alwaysAfterOwnMessage
          ? null
          : afterOwnMessagePeriod?.inSeconds,
      'alwaysAfterOwnMessage': alwaysAfterOwnMessage,
    };
  }

  static MucNotifySettings? fromMap(Map<String, dynamic>? map) {
    if (map == null) {
      return null;
    }
    final mode = map['mode']?.toString() == 'all'
        ? MucNotifyMode.all
        : MucNotifyMode.mentions;
    final alwaysAfterOwnMessage = map['alwaysAfterOwnMessage'] == true;
    final seconds = map['afterOwnMessageSeconds'];
    Duration? afterOwnMessagePeriod;
    if (!alwaysAfterOwnMessage && seconds is int && seconds > 0) {
      afterOwnMessagePeriod = Duration(seconds: seconds);
    }
    return MucNotifySettings(
      mode: mode,
      afterOwnMessagePeriod: afterOwnMessagePeriod,
      alwaysAfterOwnMessage: alwaysAfterOwnMessage,
    );
  }

  /// Returns true if a message with the given [body] should be considered a
  /// mention of the given in-room [nick], following the convention that a
  /// mention either begins with the nickname followed by punctuation (e.g.
  /// "dave: hi", "dave, hi"), or contains "@" followed by the nickname
  /// anywhere in the body (e.g. "hi @dave").
  static bool bodyMentionsNick(String body, String nick) {
    if (nick.trim().isEmpty || body.trim().isEmpty) {
      return false;
    }
    final escapedNick = RegExp.escape(nick.trim());
    final leadingPattern = RegExp(
      '^\\s*$escapedNick\\s*[:,-]',
      caseSensitive: false,
    );
    if (leadingPattern.hasMatch(body)) {
      return true;
    }
    final atPattern = RegExp('@$escapedNick\\b', caseSensitive: false);
    return atPattern.hasMatch(body);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is MucNotifySettings &&
        other.mode == mode &&
        other.afterOwnMessagePeriod == afterOwnMessagePeriod &&
        other.alwaysAfterOwnMessage == alwaysAfterOwnMessage;
  }

  @override
  int get hashCode =>
      Object.hash(mode, afterOwnMessagePeriod, alwaysAfterOwnMessage);
}
