import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import '../utils/xep0392_color.dart';

/// The single, consistent avatar widget used everywhere we show a user's
/// (or room's) avatar: chat messages, the roster/chat-list, and the MUC
/// occupant list.
///
/// Renders [bytes] as a circular image when available, otherwise a
/// colored circle with the first letter of [label] (colored per
/// XEP-0392, so the same name always gets the same color across the
/// app). When [showPresenceDot] is true, a small colored dot reflecting
/// [presenceShow] is overlaid in the bottom-right corner; pass `null` for
/// [presenceShow] to render the neutral/offline dot. Pass [badge] instead
/// of [showPresenceDot] to overlay a custom indicator (e.g. the "room
/// bookmark" icon used in the chat list) rather than a presence dot.
class AvatarWithPresence extends StatelessWidget {
  const AvatarWithPresence({
    super.key,
    required this.label,
    this.bytes,
    this.radius = 18,
    this.showPresenceDot = false,
    this.presenceShow,
    this.badge,
  }) : assert(
         !(showPresenceDot && badge != null),
         'Use either showPresenceDot or badge, not both.',
       );

  /// Used to derive the placeholder initial and its background color when
  /// [bytes] is null.
  final String label;

  /// Raw avatar image bytes, when a vCard/PEP avatar has been fetched.
  final Uint8List? bytes;

  /// The avatar's radius. Defaults to the size used across the app (18).
  final double radius;

  /// Whether to overlay a presence dot in the bottom-right corner,
  /// colored according to [presenceShow].
  final bool showPresenceDot;

  /// The presence `<show/>` state to color the presence dot with, when
  /// [showPresenceDot] is true. `null` renders a neutral/offline dot.
  final PresenceShowElement? presenceShow;

  /// A custom overlay badge shown in the bottom-right corner instead of a
  /// presence dot (e.g. a small room icon for bookmarked rooms).
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final avatar = _buildAvatarCircle();
    final overlay = badge ?? (showPresenceDot ? _PresenceDot(show: presenceShow) : null);
    if (overlay == null) {
      return avatar;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(right: 0, bottom: 0, child: overlay),
      ],
    );
  }

  Widget _buildAvatarCircle() {
    if (bytes != null) {
      return CircleAvatar(radius: radius, backgroundImage: MemoryImage(bytes!));
    }
    final trimmed = label.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
    final baseColor = xep0392ColorForLabel(label);
    final onBase = baseColor.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    return CircleAvatar(
      radius: radius,
      backgroundColor: baseColor,
      foregroundColor: onBase,
      child: Text(initial),
    );
  }
}

/// The small colored dot overlaid on an [AvatarWithPresence] to indicate
/// presence state, matching the color scheme used by the presence menu.
class _PresenceDot extends StatelessWidget {
  const _PresenceDot({required this.show});

  final PresenceShowElement? show;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: presenceDotColor(theme, show),
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.surface, width: 2),
      ),
    );
  }
}

/// Returns the color used to render a presence dot for the given
/// presence `<show/>` state. `null` (no particular mode, or unknown/
/// offline) renders a neutral outline color.
Color presenceDotColor(ThemeData theme, PresenceShowElement? show) {
  if (show == null) {
    return theme.colorScheme.outlineVariant;
  }
  switch (show) {
    case PresenceShowElement.CHAT:
      return const Color(0xFF2FB84D);
    case PresenceShowElement.AWAY:
      return const Color(0xFFF9A825);
    case PresenceShowElement.DND:
      return const Color(0xFFC62828);
    case PresenceShowElement.XA:
      return const Color(0xFFF9A825);
  }
}
