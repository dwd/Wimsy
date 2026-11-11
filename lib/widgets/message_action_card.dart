import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../models/chat_message.dart';
import 'avatar_with_presence.dart';

/// A floating, previewable replacement for the old `PopupMenuButton`-based
/// message menu.
///
/// Shown over a dimmed scrim (see [showMessageActionCard]) when the user
/// taps or long-presses a message's avatar, [MessageActionCard] renders a
/// non-interactive preview of the message alongside direct icon buttons for
/// every action whose corresponding callback is non-null (mirroring the
/// conditional items the old popup menu used to show), plus the sender's
/// JID and roster/contact status.
class MessageActionCard extends StatefulWidget {
  const MessageActionCard({
    super.key,
    required this.message,
    required this.senderName,
    required this.senderJid,
    this.senderFullJid,
    this.avatarBytes,
    this.isContact = false,
    this.recentReactionOptions = const [],
    this.ownReactions = const {},
    this.onReply,
    this.onEdit,
    this.onReact,
    this.onAddToRoster,
    this.onKick,
    this.onBan,
    this.onViewReactions,
    this.onDismiss,
    this.onOpenReactionPicker,
  });

  /// The message this card previews and acts on.
  final ChatMessage message;

  /// The sender's already-resolved display name (nickname/vCard name).
  final String senderName;

  /// The sender's bare JID, when known (e.g. the occupant's real JID for a
  /// MUC message, or the correspondent's bare JID for a 1:1 chat).
  final String senderJid;

  /// The sender's full JID, when it differs from [senderJid] (e.g. a MUC
  /// occupant JID `room@conference.example.com/nick`).
  final String? senderFullJid;

  final Uint8List? avatarBytes;

  /// Whether [senderJid] is already present in the local roster.
  final bool isContact;

  /// Recently-used reaction emoji offered as quick picks, mirroring the
  /// options shown by the chat screen's reaction picker sheet.
  final List<String> recentReactionOptions;

  /// Emoji the local user has already reacted with on this message, used
  /// to highlight the matching quick-pick chip.
  final Set<String> ownReactions;

  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final void Function(String emoji)? onReact;
  final VoidCallback? onAddToRoster;

  /// See `MessageBubble.onKick` in `lib/main.dart` for XEP-0045 semantics.
  final VoidCallback? onKick;

  /// See `MessageBubble.onBan` in `lib/main.dart` for XEP-0045 semantics.
  final VoidCallback? onBan;
  final VoidCallback? onViewReactions;

  /// Overrides the built-in quick-reaction picker sheet with a
  /// caller-supplied one (e.g. the chat screen's own reaction picker, which
  /// also offers a custom-emoji entry point). When null, [onReact] is
  /// offered through a minimal, self-contained picker instead.
  final VoidCallback? onOpenReactionPicker;

  /// Called when the card should close itself (e.g. after an action is
  /// chosen). Dismissing by tapping the scrim is handled by whatever
  /// presents the card (see [showMessageActionCard]) and does not require
  /// this callback.
  final VoidCallback? onDismiss;

  @override
  State<MessageActionCard> createState() => _MessageActionCardState();
}

class _MessageActionCardState extends State<MessageActionCard> {
  /// Whether the raw XML view is toggled on, replacing the sender/contact
  /// info and message preview. Off by default.
  bool _showXml = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fullJid =
        widget.senderFullJid != null &&
            widget.senderFullJid != widget.senderJid
        ? widget.senderFullJid
        : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            elevation: 8,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildActions(context),
                  const SizedBox(height: 16),
                  if (_showXml)
                    _buildXmlView(theme)
                  else ...[
                    _buildJidInfo(theme, fullJid),
                    const SizedBox(height: 12),
                    _buildMessagePreview(theme),
                  ],
                  const SizedBox(height: 12),
                  _buildReactionsList(theme),
                  if (widget.onReact != null) ...[
                    const SizedBox(height: 12),
                    _buildAddReactionRow(context),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Replaces the sender/contact info and message preview with the
  /// message's raw XML, shown while the "View XML" action is toggled on.
  Widget _buildXmlView(ThemeData theme) {
    final xml = widget.message.rawXml?.trim();
    return SelectableText(
      (xml == null || xml.isEmpty) ? 'No XML cached for this message.' : xml,
      style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
    );
  }

  /// A non-interactive rendering of the sender + message body, intentionally
  /// kept minimal and decoupled from `MessageBubble`'s rendering rather than
  /// deeply refactoring it.
  Widget _buildMessagePreview(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AvatarWithPresence(label: widget.senderName, bytes: widget.avatarBytes),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.senderName,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.message.body.isEmpty ? '(no text)' : widget.message.body,
                style: theme.textTheme.bodyMedium,
              ),
              if (widget.message.edited) ...[
                const SizedBox(height: 4),
                Text(
                  'edited',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Expands the full reaction set inline beneath the message preview,
  /// showing every emoji used together with how many people reacted with
  /// it. Each chip is tappable (calling [onViewReactions], when supplied)
  /// to see exactly who reacted with that emoji.
  Widget _buildReactionsList(ThemeData theme) {
    final reactions = widget.message.reactions ?? const {};
    if (reactions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in reactions.entries)
          _ReactionChip(
            emoji: entry.key,
            count: entry.value.length,
            selected: widget.ownReactions.contains(entry.key),
            onTap: widget.onViewReactions,
          ),
      ],
    );
  }

  Widget _buildJidInfo(ThemeData theme, String? fullJid) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          fullJid == null
              ? widget.senderJid
              : '${widget.senderJid} ($fullJid)',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        if (widget.isContact)
          Chip(
            avatar: const Icon(Icons.check_circle, size: 16),
            label: const Text('Added to contacts'),
          )
        else if (widget.onAddToRoster != null)
          ActionChip(
            avatar: const Icon(Icons.person_add_outlined, size: 16),
            label: const Text('Add to contacts'),
            onPressed: () {
              widget.onAddToRoster?.call();
              widget.onDismiss?.call();
            },
          ),
      ],
    );
  }

  Widget _buildActions(BuildContext context) {
    final actions = <_CardAction>[
      if (widget.onReply != null)
        _CardAction(icon: Icons.reply, label: 'Reply', onTap: widget.onReply!),
      if (widget.onKick != null)
        _CardAction(
          icon: Icons.person_remove_outlined,
          label: 'Kick',
          onTap: widget.onKick!,
        ),
      if (widget.onBan != null)
        _CardAction(icon: Icons.block, label: 'Ban', onTap: widget.onBan!),
      if (widget.onEdit != null)
        _CardAction(
          icon: Icons.edit_outlined,
          label: 'Edit message',
          onTap: widget.onEdit!,
        ),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final action in actions)
          _ActionButton(
            icon: action.icon,
            label: action.label,
            onTap: () {
              action.onTap();
              widget.onDismiss?.call();
            },
          ),
        // "View XML" is a toggle (off by default) rather than a one-shot
        // action: turning it on simply swaps the sender/contact info and
        // message preview for the message's raw XML, in place, instead of
        // dismissing the card or opening a separate dialog.
        _ActionButton(
          icon: Icons.code,
          label: 'View XML',
          selected: _showXml,
          onTap: () => setState(() => _showXml = !_showXml),
        ),
      ],
    );
  }

  /// The "add a reaction" section at the bottom of the card: quick-pick
  /// emoji chips (mirroring [recentReactionOptions]) react immediately on
  /// tap, while the trailing "more" button opens the fuller picker (either
  /// the caller-supplied [onOpenReactionPicker] or this card's own minimal
  /// one).
  Widget _buildAddReactionRow(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final emoji in widget.recentReactionOptions)
          _ReactionChip(
            emoji: emoji,
            count: null,
            selected: widget.ownReactions.contains(emoji),
            onTap: () {
              widget.onReact?.call(emoji);
              widget.onDismiss?.call();
            },
          ),
        InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap:
              widget.onOpenReactionPicker ??
              () => _showReactionPicker(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.add_reaction_outlined,
              size: 18,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }

  /// A minimal, self-contained quick-reaction picker. Deliberately kept
  /// separate from the chat screen's own reaction picker sheet (see
  /// `_showReactionPickerSheet` in `lib/main.dart`) to keep this widget
  /// decoupled, even though the two look similar.
  void _showReactionPicker(BuildContext context) {
    final onReact = widget.onReact;
    if (onReact == null) {
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final emoji in widget.recentReactionOptions)
                  FilterChip(
                    selected: widget.ownReactions.contains(emoji),
                    label: Text(emoji, style: const TextStyle(fontSize: 20)),
                    onSelected: (_) {
                      Navigator.of(sheetContext).pop();
                      onReact(emoji);
                      widget.onDismiss?.call();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CardAction {
  _CardAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// A single icon-and-label action button used inside [MessageActionCard].
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Whether this button represents an "on" toggle state (used by the
  /// "View XML" action) rather than a one-shot action. Highlighted to
  /// match the selected styling used by [_ReactionChip].
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: selected
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.primary,
            ),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

/// A single emoji/count chip used by [MessageActionCard._buildReactionsList]
/// to show one entry of the message's full reaction set. Highlighted when
/// the local user is among the reactors for that emoji.
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.selected,
    this.onTap,
  });

  final String emoji;

  /// How many people reacted with [emoji], or null when this chip is used
  /// as a quick-pick "add this reaction" affordance rather than a summary
  /// of an existing reaction (see [MessageActionCard._buildAddReactionRow]).
  final int? count;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 16)),
            if (count != null) ...[
              const SizedBox(width: 4),
              Text('$count', style: theme.textTheme.labelSmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows [card] in a modal overlay: a dimmed scrim behind the floating
/// card, dismissible by tapping the scrim or pressing back/escape.
///
/// Used from both the icon-tap and long-press paths that used to open the
/// `PopupMenuButton`-based message menu (see `_MessageMenuButton` in
/// `lib/main.dart`).
Future<void> showMessageActionCard(
  BuildContext context, {
  required MessageActionCard Function(VoidCallback dismiss) builder,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss message actions',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      void dismiss() {
        if (Navigator.of(dialogContext).canPop()) {
          Navigator.of(dialogContext).pop();
        }
      }

      return builder(dismiss);
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOut),
          ),
          child: child,
        ),
      );
    },
  );
}

const List<String> _previewReactionSenders = ['juliet@example.com'];

void _previewNoop() {}

void _previewNoopEmoji(String emoji) {}

/// Sample data for the previews below: an incoming text message with a
/// couple of reactions, from a sender who is not yet a roster contact.
ChatMessage _previewIncomingMessage() {
  return ChatMessage(
    from: 'juliet@example.com',
    to: 'romeo@example.com',
    body: 'Wherefore art thou, Romeo?',
    timestamp: DateTime(2026, 1, 1, 12, 30),
    outgoing: false,
    messageId: 'preview-incoming',
    reactions: {'❤️': _previewReactionSenders},
  );
}

/// Sample data for the MUC preview: an outgoing, edited message in a room
/// where the local user may kick/ban other occupants.
ChatMessage _previewMucMessage() {
  return ChatMessage(
    from: 'tybalt',
    to: 'verona@conference.example.com',
    body: 'Peace? I hate the word.',
    timestamp: DateTime(2026, 1, 1, 12, 31),
    outgoing: false,
    messageId: 'preview-muc',
    edited: true,
  );
}

/// Preview of [MessageActionCard] for a plain incoming 1:1 message: reply,
/// edit, react, view-reactions, view-XML, and "add to contacts" actions.
@Preview(name: 'Message action card - incoming 1:1')
Widget previewMessageActionCard() {
  return MaterialApp(
    home: Scaffold(
      body: MessageActionCard(
        message: _previewIncomingMessage(),
        senderName: 'Juliet',
        senderJid: 'juliet@example.com',
        isContact: false,
        recentReactionOptions: const ['👍', '❤️', '😂'],
        onReply: _previewNoop,
        onReact: _previewNoopEmoji,
        onAddToRoster: _previewNoop,
        onViewReactions: _previewNoop,
      ),
    ),
  );
}

/// Preview of [MessageActionCard] for a MUC message from an occupant who
/// is already a contact, showing the edit/kick/ban branches.
@Preview(name: 'Message action card - MUC occupant')
Widget previewMessageActionCardMuc() {
  return MaterialApp(
    home: Scaffold(
      body: MessageActionCard(
        message: _previewMucMessage(),
        senderName: 'Tybalt',
        senderJid: 'tybalt@example.com',
        senderFullJid: 'verona@conference.example.com/tybalt',
        isContact: true,
        onEdit: _previewNoop,
        onReply: _previewNoop,
        onReact: _previewNoopEmoji,
        onKick: _previewNoop,
        onBan: _previewNoop,
      ),
    ),
  );
}
