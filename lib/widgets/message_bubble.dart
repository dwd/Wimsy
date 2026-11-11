import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';
import 'package:xmpp_stone/xmpp_stone.dart';
import 'package:url_launcher/url_launcher.dart';

import '../av/call_session.dart';
import '../encryption/encryption_backend.dart';
import '../models/chat_message.dart';
import '../xmpp/xmpp_service.dart';
import '../utils/xep0392_color.dart';
import '../main.dart'
    show buildSecurityLabelChip, WebxdcHostPanel, RoleAffiliationChip, formatTimestamp;
import 'avatar_with_presence.dart';
import 'fingerprint_verification_screen.dart';
import 'message_action_card.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.senderName,
    required this.timestamp,
    required this.avatarBytes,
    this.deferOobImages = false,
    required this.chatBareJid,
    required this.isRoom,
    required this.service,
    required this.replySenderName,
    required this.replyBody,
    required this.onReplyTargetTap,
    required this.inviteRoomJid,
    required this.inviteRoomName,
    required this.inviteAvatarBytes,
    required this.inviteReason,
    required this.onJoinInvite,
    this.onAddToRoster,
    this.onKick,
    this.onBan,
    required this.selfReactionSenderId,
    required this.recentReactionOptions,
    required this.onReact,
    required this.onEdit,
    this.onRetract,
    this.onModerate,
    required this.onReply,
    required this.onAcceptFile,
    required this.onDeclineFile,
    required this.onFallbackUpload,
    this.onOpenWebxdc,
  });

  final ChatMessage message;
  final String senderName;
  final String timestamp;
  final Uint8List? avatarBytes;
  final bool deferOobImages;
  final String chatBareJid;
  final bool isRoom;
  final XmppService service;
  final String? replySenderName;
  final String? replyBody;
  final VoidCallback? onReplyTargetTap;
  final String? inviteRoomJid;
  final String? inviteRoomName;
  final Uint8List? inviteAvatarBytes;
  final String? inviteReason;
  final VoidCallback? onJoinInvite;
  final VoidCallback? onAddToRoster;
  /// Shown as "Kick" in the message menu for MUC messages when the local
  /// user is an owner/admin of the room (XEP-0045 §8.2); sets the sender's
  /// role to `none`, removing them from the room without banning them.
  final VoidCallback? onKick;
  /// Shown as "Ban" in the message menu for MUC messages when the local
  /// user is an owner/admin of the room; sets the sender's affiliation to
  /// `outcast` (XEP-0045 §9.1), preventing them from rejoining.
  final VoidCallback? onBan;
  final String selfReactionSenderId;
  final List<String> recentReactionOptions;
  final void Function(String emoji)? onReact;
  final VoidCallback? onEdit;
  // XEP-0424: shown as "Retract" in the message action card; only ever
  // non-null for our own outgoing messages (see `main.dart`'s wiring).
  final VoidCallback? onRetract;
  // XEP-0425: shown as "Moderate" in the message action card; only ever
  // non-null for other occupants' messages in a MUC room where we hold
  // the `moderator` role (see `main.dart`'s wiring).
  final VoidCallback? onModerate;
  final VoidCallback? onReply;
  final VoidCallback? onAcceptFile;
  final VoidCallback? onDeclineFile;
  final VoidCallback? onFallbackUpload;
  // XEP-0491: when supplied, used to open a WebXDC mini-app as an embedded
  // card within the current chat window instead of pushing a full-screen
  // route. Falls back to the full-screen host when omitted.
  final OpenWebxdcCallback? onOpenWebxdc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    final linkColor = theme.colorScheme.primary;
    final tickIcon = _tickIcon(theme);
    final nameColor = message.outgoing
        ? textColor.withValues(alpha: 0.85)
        : xep0392ColorForLabel(senderName);
    final oobImage = _buildOobImage(context);
    final oobFileCard = _buildOobFileCard(context);
    final webxdcCard = _buildWebxdcCard(context);
    final fileTransferCard = _buildFileTransferCard(context);
    final inviteCard = _buildInviteCard(context);
    final callCard = message.callSid == null
        ? null
        : _CallMessageCard(message: message);
    final securityLabelChip = _buildSecurityLabelChip(context);
    final reactions = message.reactions ?? const {};
    final ownReactions = _ownReactions(reactions);
    final occupantRealJid = isRoom
        ? service.roomOccupantRealJid(chatBareJid, message.from)
        : null;
    final senderBareJid = isRoom
        ? (occupantRealJid ?? chatBareJid)
        : (Jid.fromFullJid(message.from).userAtDomain);
    final senderFullJid = isRoom
        ? '$chatBareJid/${message.from}'
        : (message.from != senderBareJid ? message.from : null);
    final isSenderContact = service.contacts.any(
      (contact) => contact.jid == senderBareJid,
    );

    return _MessageMenuRegion(
      messageId: message.messageId,
      builder: (menuKey) => Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MessageMenuButton(
              key: menuKey,
              message: message,
              senderName: senderName,
              senderJid: senderBareJid,
              senderFullJid: senderFullJid,
              avatarBytes: avatarBytes,
              isContact: isSenderContact,
              recentReactionOptions: recentReactionOptions,
              ownReactions: ownReactions,
              onReact: onReact,
              onEdit: onEdit,
              onRetract: onRetract,
              onModerate: onModerate,
              onReply: onReply,
              onAddToRoster: onAddToRoster,
              onKick: onKick,
              onBan: onBan,
              chatBareJid: chatBareJid,
              isRoom: isRoom,
              service: service,
              timestampText: timestamp,
              deferOobImages: deferOobImages,
              selfReactionSenderId: selfReactionSenderId,
              replySenderName: replySenderName,
              replyBody: replyBody,
              inviteRoomJid: inviteRoomJid,
              inviteRoomName: inviteRoomName,
              inviteAvatarBytes: inviteAvatarBytes,
              inviteReason: inviteReason,
              child: AvatarWithPresence(
                label: senderName,
                bytes: avatarBytes,
                showPresenceDot: true,
                presenceShow: _resolveSenderPresenceShow(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Flexible(
                              child: Text(
                                senderName,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: nameColor,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (_senderRoomRole() == 'moderator') ...[
                              const SizedBox(width: 6),
                              const RoleAffiliationChip(label: 'moderator'),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (message.retracted) ...[
                            message.moderated
                                ? _buildModeratedChip(context)
                                : _buildRetractedChip(context),
                            const SizedBox(width: 6),
                          ]
                          else if (message.edited) ...[
                            const SizedBox(width: 6),
                            _buildEditedChip(context),
                          ],
                          Text(
                            timestamp,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: textColor.withValues(alpha: 0.7),
                            ),
                          ),
                          if (tickIcon != null) ...[
                            const SizedBox(width: 6),
                            tickIcon,
                          ],
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (securityLabelChip != null) ...[
                    securityLabelChip,
                    const SizedBox(height: 6),
                  ],
                  if ((message.replyToId ?? '').isNotEmpty) ...[
                    _buildReplyCard(context),
                    const SizedBox(height: 8),
                  ],
                  if (fileTransferCard != null) ...[
                    fileTransferCard,
                    const SizedBox(height: 8),
                  ],
                  if (inviteCard != null) ...[
                    inviteCard,
                    const SizedBox(height: 8),
                  ],
                  if (callCard != null) ...[
                    callCard,
                    const SizedBox(height: 8),
                  ],
                  if (oobImage != null) ...[
                    oobImage,
                    const SizedBox(height: 8),
                  ],
                  if (webxdcCard != null) ...[
                    webxdcCard,
                    const SizedBox(height: 8),
                  ],
                  if (oobFileCard != null) ...[
                    oobFileCard,
                    const SizedBox(height: 8),
                  ],
                  if (message.callSid != null)
                    const SizedBox.shrink()
                  else if (message.encryptionError != null)
                    SelectableText(
                      'Undecryptable message '
                      '(${message.encryptionError})',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: textColor,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else if (_meCommandAction(message.body) != null)
                    SelectableText(
                      _formatMeCommand(
                        senderName,
                        _meCommandAction(message.body)!,
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: textColor,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else if (_shouldShowBody(message.body, message.oobUrl))
                    SelectableText.rich(
                      TextSpan(
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textColor,
                          decoration: _strikeThroughBody
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                        children: _linkifyText(
                          message.body,
                          theme.textTheme.bodyMedium?.copyWith(
                            color: textColor,
                            decoration: _strikeThroughBody
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                          theme.textTheme.bodyMedium?.copyWith(
                            color: linkColor,
                            decoration: _strikeThroughBody
                                ? TextDecoration.combine([
                                    TextDecoration.underline,
                                    TextDecoration.lineThrough,
                                  ])
                                : TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                  if (reactions.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _buildReactionRow(context, reactions, ownReactions),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Whether the message body should be rendered struck through: true for
  // a XEP-0424 retraction or a XEP-0425 moderation without a reason, but
  // not when a moderation reason replaced the body entirely (that
  // replacement text is shown plainly rather than struck through).
  bool get _strikeThroughBody =>
      message.retracted && (message.moderationReason ?? '').isEmpty;

  /// The sender's current MUC role (e.g. `moderator`), looked up by nick
  /// from the room's occupant list, or `null` for non-room chats or
  /// occupants we don't have presence details for yet. Used to show a
  /// "moderator" chip next to the sender's name, mirroring the occupant
  /// list's own role chip.
  String? _senderRoomRole() {
    if (!isRoom) {
      return null;
    }
    return service.roomOccupantRole(chatBareJid, message.from);
  }

  // XEP-0258: renders this message's security label marking as a small
  // coloured chip, when present. The marking is preferably derived by
  // parsing the label itself against a known security policy; when that
  // isn't possible, the server's pre-rendered `<displaymarking/>` is shown
  // instead, with a warning triangle to flag that it hasn't been
  // policy-verified.
  Widget? _buildSecurityLabelChip(BuildContext context) {
    final text = message.securityLabelText?.trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return buildSecurityLabelChip(
      text: text,
      fgColor: message.securityLabelFgColor,
      bgColor: message.securityLabelBgColor,
      isFallback: message.securityLabelIsFallback,
    );
  }

  // XEP-0308: renders a small chip flagging that this message has been
  // edited (a correction was applied), with the timestamp the correction
  // was received at. Shown next to the message timestamp, same style as
  // the retracted chip.
  Widget _buildEditedChip(BuildContext context) {
    final theme = Theme.of(context);
    final editedAt = message.editedAt;
    final suffix = editedAt == null ? '' : ' ${formatTimestamp(editedAt)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Edited at$suffix',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  // XEP-0424: renders a small chip flagging that this message has been
  // retracted, with the timestamp the retraction was observed at. Shown
  // above the (struck-through) message body.
  Widget _buildRetractedChip(BuildContext context) {
    final theme = Theme.of(context);
    final retractedAt = message.retractedAt;
    final suffix = retractedAt == null
        ? ''
        : ' ${formatTimestamp(retractedAt)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Retracted at$suffix',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  // XEP-0425: renders a small chip flagging that this message has been
  // moderated (retracted by a room moderator, rather than by its original
  // sender), with the timestamp the moderation notice was observed at.
  // Shown in place of [_buildRetractedChip] next to the message timestamp.
  Widget _buildModeratedChip(BuildContext context) {
    final theme = Theme.of(context);
    final moderatedAt = message.retractedAt;
    final suffix = moderatedAt == null
        ? ''
        : ' ${formatTimestamp(moderatedAt)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Moderated at$suffix',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  Widget _buildReplyCard(BuildContext context) {
    final theme = Theme.of(context);
    final cardBody = (replyBody ?? message.replyFallback ?? '').trim();
    final text = cardBody.isEmpty ? '(original message unavailable)' : cardBody;
    return InkWell(
      onTap: onReplyTargetTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              replySenderName ?? 'original message',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// Resolves the presence `<show/>` state to display on the sender's
  /// avatar dot. For room messages, looks up the sender's nick in the
  /// current occupant list; for 1:1 chats, uses the roster presence (or
  /// our own presence, for outgoing messages). Returns `null` when the
  /// sender's presence is unknown (rendered as a neutral/offline dot).
  PresenceShowElement? _resolveSenderPresenceShow() {
    if (isRoom) {
      for (final occupant in service.roomOccupantsFor(chatBareJid)) {
        if (occupant.nick == message.from) {
          return occupant.show ?? PresenceShowElement.CHAT;
        }
      }
      return null;
    }
    if (message.outgoing) {
      return service.selfPresence.showElement ?? PresenceShowElement.CHAT;
    }
    final presence = service.presenceFor(message.from);
    if (presence == null) {
      return null;
    }
    final statusText = presence.status?.trim();
    if (statusText != null && statusText.toLowerCase() == 'unavailable') {
      return null;
    }
    return presence.showElement ?? PresenceShowElement.CHAT;
  }

  Widget? _tickIcon(ThemeData theme) {
    if (!message.outgoing) {
      return null;
    }
    if (message.displayed) {
      return Icon(Icons.done_all, size: 14, color: theme.colorScheme.primary);
    }
    if (message.receiptReceived) {
      return Icon(
        Icons.done_all,
        size: 14,
        color: theme.colorScheme.onSurfaceVariant,
      );
    }
    if (message.acked) {
      return Icon(
        Icons.done,
        size: 14,
        color: theme.colorScheme.onSurfaceVariant,
      );
    }
    return _PendingMessageClock(
      key: const Key('pending-message-clock'),
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  List<TextSpan> _linkifyText(
    String input,
    TextStyle? baseStyle,
    TextStyle? linkStyle,
  ) {
    final regex = RegExp(
      r'((https?:\/\/)|(www\.))[^\s<]+',
      caseSensitive: false,
    );
    final matches = regex.allMatches(input).toList();
    if (matches.isEmpty) {
      return [TextSpan(text: input, style: baseStyle)];
    }

    final spans = <TextSpan>[];
    var lastIndex = 0;
    for (final match in matches) {
      if (match.start > lastIndex) {
        spans.add(
          TextSpan(
            text: input.substring(lastIndex, match.start),
            style: baseStyle,
          ),
        );
      }
      final raw = input.substring(match.start, match.end);
      final normalized = _normalizeUrl(raw);
      spans.add(
        TextSpan(
          text: raw,
          style: linkStyle ?? baseStyle,
          recognizer: TapGestureRecognizer()
            ..onTap = () async {
              final uri = Uri.tryParse(normalized);
              if (uri == null) {
                return;
              }
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
        ),
      );
      lastIndex = match.end;
    }
    if (lastIndex < input.length) {
      spans.add(TextSpan(text: input.substring(lastIndex), style: baseStyle));
    }
    return spans;
  }

  String _normalizeUrl(String raw) {
    final stripped = _stripTrailingPunctuation(raw);
    final lower = stripped.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return stripped;
    }
    return 'https://$stripped';
  }

  String _stripTrailingPunctuation(String input) {
    var result = input;
    while (result.isNotEmpty &&
        RegExp(r'[\\).,!?;:\\]]').hasMatch(result[result.length - 1])) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  String? _meCommandAction(String body) {
    if (!body.startsWith('/me ')) {
      return null;
    }
    final action = body.substring(4).trim();
    return action.isEmpty ? null : action;
  }

  String _formatMeCommand(String senderName, String action) {
    return '* $senderName $action';
  }

  bool _shouldShowBody(String body, String? oobUrl) {
    if (_isNonImageOob(oobUrl)) {
      return false;
    }
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final rawOob = oobUrl?.trim();
    if (rawOob == null || rawOob.isEmpty) {
      return true;
    }
    if (trimmed.contains(RegExp(r'\s'))) {
      return true;
    }
    return _normalizeUrl(trimmed) != _normalizeUrl(rawOob);
  }

  Widget? _buildInviteCard(BuildContext context) {
    final roomJid = inviteRoomJid;
    if (roomJid == null || roomJid.isEmpty) {
      return null;
    }
    final theme = Theme.of(context);
    final title = inviteRoomName?.isNotEmpty == true
        ? inviteRoomName!
        : roomJid;
    final subtitle = inviteReason?.isNotEmpty == true ? inviteReason! : roomJid;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AvatarWithPresence(label: title, bytes: inviteAvatarBytes),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (onJoinInvite != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      onPressed: onJoinInvite,
                      child: const Text('Join'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildFileTransferCard(BuildContext context) {
    final transferId = message.fileTransferId;
    if (transferId == null || transferId.isEmpty) {
      return null;
    }
    final theme = Theme.of(context);
    final name = message.fileName?.isNotEmpty == true
        ? message.fileName!
        : 'File';
    final size = message.fileSize;
    final bytes = message.fileBytes ?? 0;
    final state = message.fileState ?? '';
    final status = _fileTransferStatusLabel(state, message.outgoing);
    final showActions =
        !message.outgoing &&
        state == 'offered' &&
        (onAcceptFile != null || onDeclineFile != null);
    final showFallback =
        message.outgoing &&
        (state == 'failed' || state == 'declined') &&
        onFallbackUpload != null;
    final hasProgress = size != null && size > 0 && state == 'in_progress';
    final progressValue = hasProgress ? (bytes / size).clamp(0.0, 1.0) : null;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            size == null ? 'Size unknown' : _formatFileSize(size),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            status,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (hasProgress) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progressValue),
          ],
          if (showActions) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: onAcceptFile,
                  child: const Text('Receive'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onDeclineFile,
                  child: const Text('Decline'),
                ),
              ],
            ),
          ],
          if (showFallback) ...[
            const SizedBox(height: 8),
            FilledButton(
              onPressed: onFallbackUpload,
              child: const Text('Send via HTTP'),
            ),
          ],
        ],
      ),
    );
  }

  String _fileTransferStatusLabel(String state, bool outgoing) {
    switch (state) {
      case 'accepted':
        return 'Accepted';
      case 'in_progress':
        return outgoing ? 'Sending...' : 'Receiving...';
      case 'completed':
        return 'Completed';
      case 'failed':
        return 'Failed';
      case 'declined':
        return 'Declined';
      case 'offered':
      default:
        return outgoing ? 'Waiting for acceptance' : 'Waiting to accept';
    }
  }

  String _formatFileSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex += 1;
    }
    final value = size >= 10
        ? size.roundToDouble()
        : double.parse(size.toStringAsFixed(1));
    final text = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$text ${units[unitIndex]}';
  }

  Widget? _buildOobImage(BuildContext context) {
    final url = _imageUrlForMessage(message.oobUrl);
    if (url == null) {
      return null;
    }
    return _DeferredOobImage(
      deferred: deferOobImages,
      imageBuilder: () =>
          _buildNetworkOobImage(url, () => _showExpandedImage(context, url)),
    );
  }

  Widget _buildNetworkOobImage(String url, VoidCallback onTap) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 260.0;
        final cap = math.min(maxWidth, 280.0);
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: cap, maxHeight: cap),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Shows a fullscreen overlay displaying [url] so the user can view the
  /// image at full size. Tapping the background or the close button dismisses
  /// the overlay.
  void _showExpandedImage(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog.fullscreen(
          backgroundColor: Colors.black87,
          child: Stack(
            children: [
              // Tapping outside the image also dismisses the dialog.
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(color: Colors.transparent),
              ),
              Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 8.0,
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: SafeArea(
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget? _buildWebxdcCard(BuildContext context) {
    if (!message.isWebxdcWidget) {
      return null;
    }
    final theme = Theme.of(context);
    final title = (message.webxdcDocument?.trim().isNotEmpty == true)
        ? message.webxdcDocument!.trim()
        : (message.oobDescription?.trim().isNotEmpty == true
              ? message.oobDescription!.trim()
              : 'Mini App');
    final summary = message.webxdcSummary?.trim();
    final threadId = message.webxdcThreadId?.trim() ?? '';
    final oobUrl = message.oobUrl?.trim() ?? '';
    final canOpen = threadId.isNotEmpty && oobUrl.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          if (summary != null && summary.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              summary,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: canOpen
                  ? () {
                      final openInline = onOpenWebxdc;
                      if (openInline != null) {
                        openInline(
                          threadId: threadId,
                          oobUrl: oobUrl,
                          chatBareJid: chatBareJid,
                          isRoom: isRoom,
                          title: title,
                        );
                        return;
                      }
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => WebxdcHostPanel(
                            service: service,
                            threadId: threadId,
                            oobUrl: oobUrl,
                            chatBareJid: chatBareJid,
                            isRoom: isRoom,
                            title: title,
                            maximized: true,
                            onToggleMaximized: () {},
                            onClose: () => Navigator.of(context).pop(),
                          ),
                        ),
                      );
                    }
                  : null,
              child: const Text('Open'),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildOobFileCard(BuildContext context) {
    if (message.isWebxdcWidget) {
      return null;
    }
    final url = message.oobUrl?.trim() ?? '';
    if (url.isEmpty || _isImageUrl(url)) {
      return null;
    }
    final theme = Theme.of(context);
    final description = _oobDescriptionText(url);
    final name = _oobFileName(url);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: theme.textTheme.titleSmall),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: () async {
                final uri = Uri.tryParse(url);
                if (uri == null) {
                  return;
                }
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              child: const Text('Download'),
            ),
          ),
        ],
      ),
    );
  }

  bool _isNonImageOob(String? oobUrl) {
    final raw = oobUrl?.trim();
    if (raw == null || raw.isEmpty) {
      return false;
    }
    return !_isImageUrl(raw);
  }

  String _oobDescriptionText(String url) {
    final description = message.oobDescription?.trim();
    if (description != null && description.isNotEmpty) {
      return description;
    }
    final body = message.body.trim();
    if (body.isNotEmpty && _normalizeUrl(body) != _normalizeUrl(url)) {
      return body;
    }
    return url;
  }

  String _oobFileName(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return 'File';
    }
    final segments = uri.pathSegments;
    if (segments.isEmpty) {
      return 'File';
    }
    final last = segments.last.trim();
    if (last.isEmpty) {
      return 'File';
    }
    return Uri.decodeComponent(last);
  }

  String? _imageUrlForMessage(String? oobUrl) {
    final raw = oobUrl?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    if (!_isImageUrl(raw)) {
      return null;
    }
    return raw;
  }

  bool _isImageUrl(String url) {
    final lower = url.toLowerCase();
    final match = RegExp(r'\.(png|jpe?g|gif|webp|bmp)(\?|#|$)').hasMatch(lower);
    if (match) {
      return true;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    final path = uri.path.toLowerCase();
    return RegExp(r'\.(png|jpe?g|gif|webp|bmp)$').hasMatch(path);
  }

  Set<String> _ownReactions(Map<String, List<String>> reactions) {
    final sender = selfReactionSenderId.trim();
    if (sender.isEmpty) {
      return <String>{};
    }
    final result = <String>{};
    reactions.forEach((emoji, senders) {
      if (senders.contains(sender)) {
        result.add(emoji);
      }
    });
    return result;
  }

  Widget _buildReactionRow(
    BuildContext context,
    Map<String, List<String>> reactions,
    Set<String> ownReactions,
  ) {
    final theme = Theme.of(context);
    final entries = reactions.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final entry in entries)
          Tooltip(
            message: entry.value.join(', '),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onReact == null ? null : () => onReact!(entry.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: ownReactions.contains(entry.key)
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: ownReactions.contains(entry.key)
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                  child: Text(
                    '${entry.key} ${entry.value.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: ownReactions.contains(entry.key)
                          ? theme.colorScheme.onPrimaryContainer
                          : null,
                    ),
                  ),
                ),
              ),
          ),
        ),
      ],
    );
  }
}

void _previewMessageBubbleNoop() {}

void _previewMessageBubbleNoopEmoji(String emoji) {}

/// Sample data for the [MessageBubble] previews below: a plain incoming
/// text message.
ChatMessage _previewIncomingBubbleMessage() {
  return ChatMessage(
    from: 'juliet@example.com',
    to: 'romeo@example.com',
    body: 'Wherefore art thou, Romeo?',
    timestamp: DateTime(2026, 1, 1, 12, 30),
    outgoing: false,
    messageId: 'preview-bubble-incoming',
  );
}

/// Sample data for the [MessageBubble] previews below: a retracted
/// (XEP-0424) outgoing message, shown struck through with a "Retracted at"
/// chip next to the timestamp.
ChatMessage _previewRetractedBubbleMessage() {
  return ChatMessage(
    from: 'romeo@example.com',
    to: 'juliet@example.com',
    body: 'Oops, wrong chat',
    timestamp: DateTime(2026, 1, 1, 12, 31),
    outgoing: true,
    messageId: 'preview-bubble-retracted',
    retracted: true,
    retractedAt: DateTime(2026, 1, 1, 12, 32),
  );
}

/// Preview of [MessageBubble] for a plain incoming 1:1 message, used to
/// sanity-check the message header layout (sender name, timestamp, status
/// tick) stays right-justified against the available width.
@Preview(name: 'Message bubble - incoming 1:1')
Widget previewMessageBubbleIncoming() {
  return MaterialApp(
    home: Scaffold(
      body: MessageBubble(
        message: _previewIncomingBubbleMessage(),
        senderName: 'Juliet',
        timestamp: '12:30',
        avatarBytes: null,
        chatBareJid: 'juliet@example.com',
        isRoom: false,
        service: XmppService(),
        replySenderName: null,
        replyBody: null,
        onReplyTargetTap: null,
        inviteRoomJid: null,
        inviteRoomName: null,
        inviteAvatarBytes: null,
        inviteReason: null,
        onJoinInvite: null,
        selfReactionSenderId: 'romeo@example.com',
        recentReactionOptions: const ['👍', '❤️', '😂'],
        onReact: _previewMessageBubbleNoopEmoji,
        onEdit: _previewMessageBubbleNoop,
        onReply: _previewMessageBubbleNoop,
        onAcceptFile: null,
        onDeclineFile: null,
        onFallbackUpload: null,
      ),
    ),
  );
}

/// Preview of [MessageBubble] for a retracted (XEP-0424) outgoing message:
/// struck-through body plus the "Retracted at" chip to the left of the
/// (right-justified) timestamp.
@Preview(name: 'Message bubble - retracted')
Widget previewMessageBubbleRetracted() {
  return MaterialApp(
    home: Scaffold(
      body: MessageBubble(
        message: _previewRetractedBubbleMessage(),
        senderName: 'You',
        timestamp: '12:31',
        avatarBytes: null,
        chatBareJid: 'juliet@example.com',
        isRoom: false,
        service: XmppService(),
        replySenderName: null,
        replyBody: null,
        onReplyTargetTap: null,
        inviteRoomJid: null,
        inviteRoomName: null,
        inviteAvatarBytes: null,
        inviteReason: null,
        onJoinInvite: null,
        selfReactionSenderId: 'romeo@example.com',
        recentReactionOptions: const ['👍', '❤️', '😂'],
        onReact: _previewMessageBubbleNoopEmoji,
        onEdit: _previewMessageBubbleNoop,
        onReply: _previewMessageBubbleNoop,
        onAcceptFile: null,
        onDeclineFile: null,
        onFallbackUpload: null,
      ),
    ),
  );
}

/// A small padlock/trust indicator shown in the chat header next to
/// [EncryptionSelector], reflecting the aggregate [TrustState] of
/// [peerBareJid]'s known OMEMO2 devices (e.g. all verified vs. some still
/// unverified/trust-on-first-use). Always shown, even when encryption is
/// off for the conversation ([isEncrypted] is false) - in that case it's
/// rendered as an outline-only icon to indicate there's currently nothing
/// to verify, while still letting the user tap through to review any
/// previously-known fingerprints. Tapping it opens
/// [FingerprintVerificationScreen] so the user can review and verify
/// fingerprints.
class TrustIndicator extends StatefulWidget {
  const TrustIndicator({
    required this.service,
    required this.peerBareJid,
    required this.isEncrypted,
  });

  final XmppService service;
  final String peerBareJid;
  final bool isEncrypted;

  @override
  State<TrustIndicator> createState() => _TrustIndicatorState();
}

class _TrustIndicatorState extends State<TrustIndicator> {
  TrustState? _trust;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TrustIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerBareJid != widget.peerBareJid) {
      _load();
    }
  }

  Future<void> _load() async {
    final trust = await widget.service.encryptionTrustSummaryFor(
      widget.peerBareJid,
    );
    if (mounted) {
      setState(() => _trust = trust);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trust = _trust;
    final verified = trust == TrustState.verified;
    final isEncrypted = widget.isEncrypted;
    final tooltip = !isEncrypted
        ? 'Encryption is off. Tap to review fingerprints.'
        : verified
        ? 'All known devices verified. Tap to review fingerprints.'
        : 'Some devices unverified. Tap to verify fingerprints.';
    final iconData = !isEncrypted
        ? Icons.shield_outlined
        : verified
        ? Icons.verified_user
        : Icons.gpp_maybe;
    final iconColor = !isEncrypted
        ? Theme.of(context).disabledColor
        : verified
        ? Colors.green
        : Colors.orange;
    return IconButton(
      key: const Key('trust-indicator'),
      tooltip: tooltip,
      icon: Icon(iconData, color: iconColor),
      onPressed: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => FingerprintVerificationScreen(
              service: widget.service,
              peerBareJid: widget.peerBareJid,
            ),
          ),
        );
        _load();
      },
    );
  }
}

class _CallMessageCard extends StatefulWidget {
  const _CallMessageCard({required this.message});

  final ChatMessage message;

  @override
  State<_CallMessageCard> createState() => _CallMessageCardState();
}

class _CallMessageCardState extends State<_CallMessageCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _CallMessageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  void _syncTimer() {
    final active = widget.message.callStatus == 'active';
    if (active && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    } else if (!active) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final theme = Theme.of(context);
    final media = message.callVideo == true ? 'Video call' : 'Voice call';
    final startedAt = message.callStartedAt;
    final endedAt = message.callEndedAt;
    final status = switch (message.callStatus) {
      'active' when startedAt != null =>
        'In progress for ${formatCallDuration(DateTime.now().difference(startedAt))}',
      'finished' when startedAt != null && endedAt != null =>
        'Finished, lasted ${formatCallDuration(endedAt.difference(startedAt))}',
      'missed' => 'Missed',
      'declined' => 'Declined',
      'failed' => 'Failed',
      'cancelled' => 'Cancelled',
      _ => message.outgoing ? 'Calling…' : 'Incoming…',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(message.callVideo == true ? Icons.videocam : Icons.call),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(media, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(status, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Icon(
            message.outgoing ? Icons.call_made : Icons.call_received,
            size: 18,
          ),
        ],
      ),
    );
  }
}

class _DeferredOobImage extends StatefulWidget {
  const _DeferredOobImage({required this.deferred, required this.imageBuilder});

  final bool deferred;
  final Widget Function() imageBuilder;

  @override
  State<_DeferredOobImage> createState() => _DeferredOobImageState();
}

class _DeferredOobImageState extends State<_DeferredOobImage> {
  late bool _revealed = !widget.deferred;

  @override
  Widget build(BuildContext context) {
    if (_revealed) return widget.imageBuilder();
    return OutlinedButton.icon(
      key: const Key('view-oob-image'),
      onPressed: () => setState(() => _revealed = true),
      icon: const Icon(Icons.image),
      label: const Text('View photo'),
    );
  }
}

/// A compact ticking clock shown while an outgoing message is awaiting its
/// first confirmation from the server.
class _PendingMessageClock extends StatefulWidget {
  const _PendingMessageClock({super.key, required this.color});

  final Color color;

  @override
  State<_PendingMessageClock> createState() => _PendingMessageClockState();
}

class _PendingMessageClockState extends State<_PendingMessageClock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Message sending',
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: SizedBox.square(
            dimension: 14,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => CustomPaint(
                painter: _PendingMessageClockPainter(
                  color: widget.color,
                  progress: _controller.value,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingMessageClockPainter extends CustomPainter {
  const _PendingMessageClockPainter({
    required this.color,
    required this.progress,
  });

  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 1;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, paint);
    canvas.drawLine(center, center + const Offset(0, -3), paint);

    final angle = progress * math.pi * 2 - math.pi / 2;
    canvas.drawLine(
      center,
      center + Offset(math.cos(angle), math.sin(angle)) * 4.2,
      paint,
    );
  }

  @override
  bool shouldRepaint(_PendingMessageClockPainter oldDelegate) =>
      progress != oldDelegate.progress || color != oldDelegate.color;
}

class _MessageMenuRegion extends StatefulWidget {
  const _MessageMenuRegion({required this.messageId, required this.builder});

  final String? messageId;
  final Widget Function(GlobalKey<_MessageMenuButtonState> menuKey) builder;

  @override
  State<_MessageMenuRegion> createState() => _MessageMenuRegionState();
}

class _MessageMenuRegionState extends State<_MessageMenuRegion> {
  final _menuKey = GlobalKey<_MessageMenuButtonState>();

  @override
  Widget build(BuildContext context) {
    return TouchLongPressRegion(
      key: Key('message-bubble-${widget.messageId}'),
      onLongPress: (position) => _menuKey.currentState?.showAt(position),
      child: widget.builder(_menuKey),
    );
  }
}

/// Detects touch long presses without competing with selectable message text.
class TouchLongPressRegion extends StatefulWidget {
  const TouchLongPressRegion({
    super.key,
    required this.onLongPress,
    required this.child,
  });

  final ValueChanged<Offset> onLongPress;
  final Widget child;

  @override
  State<TouchLongPressRegion> createState() => _TouchLongPressRegionState();
}

class _TouchLongPressRegionState extends State<TouchLongPressRegion> {
  Timer? _timer;
  int? _pointer;
  Offset? _startPosition;
  bool _longPressRecognized = false;

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    _cancel();
    _pointer = event.pointer;
    _startPosition = event.position;
    _timer = Timer(kLongPressTimeout, () {
      _timer = null;
      _longPressRecognized = _startPosition != null;
    });
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _startPosition == null) {
      return;
    }
    if ((event.position - _startPosition!).distance > kTouchSlop) {
      _cancel();
    }
  }

  void _handlePointerEnd(PointerEvent event) {
    if (event.pointer == _pointer) {
      final position = _startPosition;
      final recognized = _longPressRecognized;
      _cancel();
      // Do not insert the popup route while Android is still dispatching the
      // pointer sequence which recognized this long press. Otherwise the
      // release can hit the newly opened menu and immediately select or
      // dismiss an action. Opening after release gives the menu a fresh
      // gesture sequence.
      if (recognized && position != null && event is PointerUpEvent) {
        widget.onLongPress(position);
      }
    }
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _pointer = null;
    _startPosition = null;
    _longPressRecognized = false;
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
      child: widget.child,
    );
  }
}

// XEP-0491: callback used by [MessageBubble] to ask the hosting chat
// window to open a WebXDC mini-app as an embedded card, rather than the
// widget pushing a full-screen route itself.
typedef OpenWebxdcCallback =
    void Function({
      required String threadId,
      required String oobUrl,
      required String chatBareJid,
      required bool isRoom,
      required String title,
    });

class _MessageMenuButton extends StatefulWidget {
  const _MessageMenuButton({
    super.key,
    required this.message,
    required this.senderName,
    required this.senderJid,
    this.senderFullJid,
    this.avatarBytes,
    this.isContact = false,
    required this.recentReactionOptions,
    required this.ownReactions,
    required this.onReact,
    required this.onEdit,
    this.onRetract,
    this.onModerate,
    required this.onReply,
    this.onAddToRoster,
    this.onKick,
    this.onBan,
    this.child,
    required this.chatBareJid,
    required this.isRoom,
    required this.service,
    required this.timestampText,
    required this.deferOobImages,
    required this.selfReactionSenderId,
    this.replySenderName,
    this.replyBody,
    this.inviteRoomJid,
    this.inviteRoomName,
    this.inviteAvatarBytes,
    this.inviteReason,
  });

  final ChatMessage message;
  final String senderName;
  final String senderJid;
  final String? senderFullJid;
  final Uint8List? avatarBytes;
  final bool isContact;
  final List<String> recentReactionOptions;
  final Set<String> ownReactions;
  final void Function(String emoji)? onReact;
  final VoidCallback? onEdit;
  final VoidCallback? onRetract;
  final VoidCallback? onModerate;
  final VoidCallback? onReply;
  final VoidCallback? onAddToRoster;
  final VoidCallback? onKick;
  final VoidCallback? onBan;
  final Widget? child;

  // Extra data threaded through solely so [showMessageActionCard]'s
  // embedded preview can render a real [MessageBubble] identical to the
  // one shown in the chat (see [_MessageMenuButtonState._showCard]).
  final String chatBareJid;
  final bool isRoom;
  final XmppService service;
  final String timestampText;
  final bool deferOobImages;
  final String selfReactionSenderId;
  final String? replySenderName;
  final String? replyBody;
  final String? inviteRoomJid;
  final String? inviteRoomName;
  final Uint8List? inviteAvatarBytes;
  final String? inviteReason;

  @override
  State<_MessageMenuButton> createState() => _MessageMenuButtonState();
}

class _MessageMenuButtonState extends State<_MessageMenuButton> {
  Future<void> showAt(Offset globalPosition) async {
    await _showCard(anchorY: globalPosition.dy);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showCard(),
      child: widget.child ?? const Icon(Icons.more_horiz, size: 16),
    );
  }

  /// Finds the global rect of the chat window / message list the card
  /// should match the width of, by measuring the nearest enclosing
  /// scrollable (the message `ListView`). Falls back to null (centered,
  /// fixed-width card) if no such ancestor can be found or measured yet.
  Rect? _findChatPaneRect() {
    final scrollableBox =
        Scrollable.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (scrollableBox == null || !scrollableBox.hasSize) {
      return null;
    }
    return scrollableBox.localToGlobal(Offset.zero) & scrollableBox.size;
  }

  /// Approximates where the tapped message currently sits on screen, using
  /// this button's own position as a fallback for the icon-tap path (the
  /// long-press path instead passes the exact touch position to [showAt]).
  double? _findOwnAnchorY() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return null;
    }
    return box.localToGlobal(Offset.zero).dy + box.size.height / 2;
  }

  Future<void> _showCard({double? anchorY}) {
    final reactions = widget.message.reactions ?? const {};
    final chatPaneRect = _findChatPaneRect();
    final resolvedAnchorY = anchorY ?? _findOwnAnchorY();
    return showMessageActionCard(
      context,
      builder: (dismiss) => MessageActionCard(
        message: widget.message,
        senderName: widget.senderName,
        senderJid: widget.senderJid,
        senderFullJid: widget.senderFullJid,
        avatarBytes: widget.avatarBytes,
        isContact: widget.isContact,
        recentReactionOptions: widget.recentReactionOptions,
        ownReactions: widget.ownReactions,
        onEdit: widget.onEdit,
        onRetract: widget.onRetract,
        onModerate: widget.onModerate,
        onReply: widget.onReply,
        onReact: widget.onReact,
        onAddToRoster: widget.onAddToRoster,
        onKick: widget.onKick,
        onBan: widget.onBan,
        onViewReactions: reactions.isEmpty
            ? null
            : () => _showReactions(context),
        onOpenReactionPicker: widget.onReact == null
            ? null
            : () => _showReactionSheet(context),
        onDismiss: dismiss,
        chatPaneRect: chatPaneRect,
        anchorY: resolvedAnchorY,
        service: widget.service,
        chatBareJid: widget.chatBareJid,
        isRoom: widget.isRoom,
        timestampText: widget.timestampText,
        deferOobImages: widget.deferOobImages,
        selfReactionSenderId: widget.selfReactionSenderId,
        replySenderName: widget.replySenderName,
        replyBody: widget.replyBody,
        inviteRoomJid: widget.inviteRoomJid,
        inviteRoomName: widget.inviteRoomName,
        inviteAvatarBytes: widget.inviteAvatarBytes,
        inviteReason: widget.inviteReason,
      ),
    );
  }

  void _showReactionSheet(BuildContext context) {
    if (widget.onReact == null) {
      return;
    }
    showReactionPickerSheet(
      context: context,
      onReact: widget.onReact!,
      recentReactionOptions: widget.recentReactionOptions,
      ownReactions: widget.ownReactions,
    );
  }

  void _showReactions(BuildContext context) {
    final reactions = widget.message.reactions ?? const {};
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Reactions'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry
                      in reactions.entries.toList()
                        ..sort((a, b) => a.key.compareTo(b.key)))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('${entry.key} ${entry.value.join(', ')}'),
                    ),
                  if (reactions.isEmpty) const Text('No reactions yet.'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

void showReactionPickerSheet({
  required BuildContext context,
  required void Function(String emoji) onReact,
  required List<String> recentReactionOptions,
  required Set<String> ownReactions,
}) {
  final options = _reactionPickerOptions(recentReactionOptions);
  showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final emoji in options)
                    FilterChip(
                      selected: ownReactions.contains(emoji),
                      label: Text(emoji, style: const TextStyle(fontSize: 20)),
                      side: BorderSide(
                        color: ownReactions.contains(emoji)
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                      ),
                      onSelected: (_) {
                        Navigator.of(sheetContext).pop();
                        onReact(emoji);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () async {
                  Navigator.of(sheetContext).pop();
                  final custom = await _promptForCustomReaction(context);
                  if (custom == null || custom.isEmpty) {
                    return;
                  }
                  onReact(custom);
                },
                icon: const Icon(Icons.add_reaction_outlined),
                label: const Text('Use custom emoji'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

const List<String> _defaultReactionOptions = [
  "👍",
  "❤️",
  "😂",
  "😮",
  "😢",
  "👎",
];

List<String> _reactionPickerOptions(List<String> recent) {
  final ordered = <String>[];
  for (final emoji in [...recent, ..._defaultReactionOptions]) {
    if (emoji.trim().isEmpty || ordered.contains(emoji)) {
      continue;
    }
    ordered.add(emoji);
  }
  return ordered;
}

Future<String?> _promptForCustomReaction(BuildContext context) async {
  final controller = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Add reaction'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Emoji',
            hintText: 'Paste or type an emoji',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Add'),
          ),
        ],
      );
    },
  );
  final normalized = value?.trim() ?? '';
  if (normalized.isEmpty) {
    return null;
  }
  final chars = normalized.characters;
  return chars.isEmpty ? null : chars.first;
}
