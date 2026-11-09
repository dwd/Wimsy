import 'package:flutter/material.dart';

import '../encryption/encryption_manager.dart';

/// A small per-chat control (an icon button with a dropdown menu) that lets
/// the user pick the end-to-end-encryption protocol used for a 1:1
/// conversation. Offers "None", "OMEMO2", "Legacy OMEMO", and "OX
/// (OpenPGP)".
///
/// Wired into the chat header's action row alongside the voice/video call
/// buttons (see `lib/main.dart`).
class EncryptionSelector extends StatelessWidget {
  const EncryptionSelector({
    super.key,
    required this.selected,
    required this.onSelected,
    this.isProtocolSupported,
  });

  /// The currently selected protocol for the open conversation.
  final EncryptionProtocol selected;

  /// Called with the newly chosen protocol when the user picks a menu item.
  final ValueChanged<EncryptionProtocol> onSelected;

  /// Optional callback returning whether the remote contact is known to
  /// support a given [EncryptionProtocol]. When it returns `false` for a
  /// protocol, that menu item is still fully selectable -- we simply have
  /// no evidence the contact's client understands it yet -- but is
  /// rendered greyed out so the user can tell at a glance which options
  /// are unlikely to work. If omitted, all options are rendered normally.
  final bool Function(EncryptionProtocol protocol)? isProtocolSupported;

  @override
  Widget build(BuildContext context) {
    final isEncrypted = selected != EncryptionProtocol.none;
    return PopupMenuButton<EncryptionProtocol>(
      key: const Key('encryption-selector'),
      tooltip: 'End-to-end encryption',
      initialValue: selected,
      onSelected: onSelected,
      icon: Icon(isEncrypted ? Icons.lock : Icons.lock_open),
      itemBuilder: (context) => [
        _buildItem(context, EncryptionProtocol.none, 'None'),
        _buildItem(context, EncryptionProtocol.omemo2, 'OMEMO2'),
        _buildItem(context, EncryptionProtocol.legacyOmemo, 'Legacy OMEMO'),
        _buildItem(context, EncryptionProtocol.ox, 'OX (OpenPGP)'),
      ],
    );
  }

  /// Builds a single menu entry for [protocol], greying out its text (but
  /// keeping it selectable) when [isProtocolSupported] reports no known
  /// support for it.
  CheckedPopupMenuItem<EncryptionProtocol> _buildItem(
    BuildContext context,
    EncryptionProtocol protocol,
    String label,
  ) {
    final isSupported = isProtocolSupported?.call(protocol) ?? true;
    final textStyle = isSupported
        ? null
        : TextStyle(color: Theme.of(context).disabledColor);
    return CheckedPopupMenuItem(
      value: protocol,
      checked: selected == protocol,
      child: Text(label, style: textStyle),
    );
  }
}
