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
class MessageActionCard extends StatelessWidget {
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
    this.onViewXml,
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
  final VoidCallback? onViewXml;

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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fullJid = senderFullJid != null && senderFullJid != senderJid
        ? senderFullJid
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
                  _buildJidInfo(theme, fullJid),
                  const SizedBox(height: 12),
                  _buildMessagePreview(theme),
                  const SizedBox(height: 12),
                  _buildReactionsList(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A non-interactive rendering of the sender + message body, intentionally
  /// kept minimal and decoupled from `MessageBubble`'s rendering rather than
  /// deeply refactoring it.
  Widget _buildMessagePreview(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AvatarWithPresence(label: senderName, bytes: avatarBytes),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                senderName,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                message.body.isEmpty ? '(no text)' : message.body,
                style: theme.textTheme.bodyMedium,
              ),
              if (message.edited) ...[
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
    final reactions = message.reactions ?? const {};
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
            selected: ownReactions.contains(entry.key),
            onTap: onViewReactions,
          ),
      ],
    );
  }

  Widget _buildJidInfo(ThemeData theme, String? fullJid) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          fullJid == null ? senderJid : '$senderJid ($fullJid)',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        if (isContact)
          Chip(
            avatar: const Icon(Icons.check_circle, size: 16),
            label: const Text('Added to contacts'),
          )
        else if (onAddToRoster != null)
          ActionChip(
            avatar: const Icon(Icons.person_add_outlined, size: 16),
            label: const Text('Add to contacts'),
            onPressed: () {
              onAddToRoster?.call();
              onDismiss?.call();
            },
          ),
      ],
    );
  }

  Widget _buildActions(BuildContext context) {
    final actions = <_CardAction>[
      if (onReply != null)
        _CardAction(icon: Icons.reply, label: 'Reply', onTap: onReply!),
      if (onKick != null)
        _CardAction(
          icon: Icons.person_remove_outlined,
          label: 'Kick',
          onTap: onKick!,
        ),
      if (onBan != null)
        _CardAction(icon: Icons.block, label: 'Ban', onTap: onBan!),
      if (onViewXml != null)
        _CardAction(icon: Icons.code, label: 'View XML', onTap: onViewXml!),
      if (onEdit != null)
        _CardAction(
          icon: Icons.edit_outlined,
          label: 'Edit message',
          onTap: onEdit!,
        ),
      if (onReact != null)
        _CardAction(
          icon: Icons.add_reaction_outlined,
          label: 'Add reaction',
          onTap: onOpenReactionPicker ?? () => _showReactionPicker(context),
          closesCard: false,
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
              if (action.closesCard) {
                onDismiss?.call();
              }
            },
          ),
      ],
    );
  }

  /// A minimal, self-contained quick-reaction picker. Deliberately kept
  /// separate from the chat screen's own reaction picker sheet (see
  /// `_showReactionPickerSheet` in `lib/main.dart`) to keep this widget
  /// decoupled, even though the two look similar.
  void _showReactionPicker(BuildContext context) {
    final onReact = this.onReact;
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
                for (final emoji in recentReactionOptions)
                  FilterChip(
                    selected: ownReactions.contains(emoji),
                    label: Text(emoji, style: const TextStyle(fontSize: 20)),
                    onSelected: (_) {
                      Navigator.of(sheetContext).pop();
                      onReact(emoji);
                      onDismiss?.call();
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
  _CardAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.closesCard = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Whether tapping this action should dismiss the card immediately. The
  /// "Add reaction" action instead opens its own picker sheet and dismisses
  /// the card only once an emoji is actually chosen.
  final bool closesCard;
}

/// A single icon-and-label action button used inside [MessageActionCard].
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
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
  final int count;
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
            const SizedBox(width: 4),
            Text('$count', style: theme.textTheme.labelSmall),
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
        onViewXml: _previewNoop,
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
        onViewXml: _previewNoop,
      ),
    ),
  );
}
