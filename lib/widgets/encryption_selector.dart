import 'package:flutter/material.dart';

import '../encryption/encryption_manager.dart';

/// A small per-chat control (an icon button with a dropdown menu) that lets
/// the user pick the end-to-end-encryption protocol used for a 1:1
/// conversation. Offers "None", "OMEMO2", and "Legacy OMEMO"; `ox` is
/// reserved in [EncryptionProtocol] for a later plan step and is not shown
/// here yet.
///
/// Wired into the chat header's action row alongside the voice/video call
/// buttons (see `lib/main.dart`).
class EncryptionSelector extends StatelessWidget {
  const EncryptionSelector({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  /// The currently selected protocol for the open conversation.
  final EncryptionProtocol selected;

  /// Called with the newly chosen protocol when the user picks a menu item.
  final ValueChanged<EncryptionProtocol> onSelected;

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
        CheckedPopupMenuItem(
          value: EncryptionProtocol.none,
          checked: selected == EncryptionProtocol.none,
          child: const Text('None'),
        ),
        CheckedPopupMenuItem(
          value: EncryptionProtocol.omemo2,
          checked: selected == EncryptionProtocol.omemo2,
          child: const Text('OMEMO2'),
        ),
        CheckedPopupMenuItem(
          value: EncryptionProtocol.legacyOmemo,
          checked: selected == EncryptionProtocol.legacyOmemo,
          child: const Text('Legacy OMEMO'),
        ),
      ],
    );
  }
}
