import 'package:flutter/material.dart';

/// Shared "avatar / name / chips" layout used by both [MessageBubble] (one
/// per chat message) and the chat list (one per contact/room), so the two
/// look visually consistent.
///
/// Renders an avatar on the left (optional), followed by a column with a
/// colored accent bar down its left edge. That column starts with
/// [header] - typically a [NameChipsRow] - and then renders whatever
/// [body] contains below it (message content, status/preview text, etc.).
/// [rowTrailing], when supplied, is placed outside the accent-bordered
/// column, as a sibling of the avatar (e.g. an unread-count badge).
class ChatEntryHeader extends StatelessWidget {
  const ChatEntryHeader({
    super.key,
    this.avatar,
    this.avatarSpacing = 12,
    required this.accentColor,
    this.header,
    this.body,
    this.headerSpacing = 6,
    this.rowTrailing,
  });

  final Widget? avatar;
  final double avatarSpacing;
  final Color accentColor;
  final Widget? header;
  final Widget? body;
  final double headerSpacing;
  final Widget? rowTrailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ?avatar,
        if (avatar != null) SizedBox(width: avatarSpacing),
        Expanded(
          child: Container(
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: accentColor, width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ?header,
                if (header != null && body != null)
                  SizedBox(height: headerSpacing),
                ?body,
              ],
            ),
          ),
        ),
        if (rowTrailing != null) const SizedBox(width: 8),
        ?rowTrailing,
      ],
    );
  }
}

/// The name row shared by message bubbles and chat list entries: a bold,
/// colored name, optional [nameChips] rendered right after it (e.g. a
/// "moderator" role chip or a "ROOM" badge), and optional [trailing]
/// widgets aligned to the end of the row (e.g. a timestamp, an "edited"
/// chip, or a delivery tick icon).
class NameChipsRow extends StatelessWidget {
  const NameChipsRow({
    super.key,
    required this.name,
    required this.nameColor,
    this.nameBold = true,
    this.nameChips = const [],
    this.trailing = const [],
  });

  final String name;
  final Color nameColor;
  final bool nameBold;
  final List<Widget> nameChips;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // The name (plus its chips) gets priority over the available space:
        // a higher flex factor than the trailing widgets means it keeps as
        // much room as it needs, pushing the trailing content to shrink
        // (and ellipsize) first instead of overlapping or overflowing it.
        Flexible(
          flex: 3,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: Text(
                  name,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: nameColor,
                    fontWeight: nameBold ? FontWeight.bold : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final chip in nameChips) ...[
                const SizedBox(width: 6),
                chip,
              ],
            ],
          ),
        ),
        if (trailing.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < trailing.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Flexible(child: trailing[i]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
