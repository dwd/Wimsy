import 'package:flutter/material.dart';

import '../encryption/encryption_manager.dart';
import '../xmpp/xmpp_service.dart';

/// Global encryption settings screen: lets the user pick the default
/// policy applied to conversations with no explicit per-contact choice
/// ("never" / "if supported" / "always"), and enable/disable each
/// implemented cryptosystem. Disabling a cryptosystem removes it from
/// menus/screens elsewhere (see [EncryptionSelector] and
/// `FingerprintVerificationScreen`).
///
/// Both settings are persisted locally and synced across this account's
/// devices via private PEP nodes (see
/// `lib/xmpp/encryption_settings_pep.dart`).
class EncryptionSettingsScreen extends StatefulWidget {
  const EncryptionSettingsScreen({super.key, required this.service});

  final XmppService service;

  @override
  State<EncryptionSettingsScreen> createState() =>
      _EncryptionSettingsScreenState();
}

class _EncryptionSettingsScreenState extends State<EncryptionSettingsScreen> {
  static const _protocolLabels = {
    EncryptionProtocol.omemo2: 'OMEMO2',
    EncryptionProtocol.legacyOmemo: 'Legacy OMEMO',
    EncryptionProtocol.ox: 'OX (OpenPGP)',
  };

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _setPolicy(EncryptionDefaultPolicy? policy) async {
    if (policy == null) {
      return;
    }
    await widget.service.setEncryptionDefaultPolicy(policy);
  }

  Future<void> _setProtocolEnabled(
    EncryptionProtocol protocol,
    bool enabled,
  ) async {
    await widget.service.setEncryptionProtocolEnabled(protocol, enabled);
  }

  @override
  Widget build(BuildContext context) {
    final policy = widget.service.encryptionDefaultPolicy;
    return Scaffold(
      appBar: AppBar(title: const Text('Encryption settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Default policy',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            'Applied to conversations where you haven\'t explicitly chosen '
            'an encryption protocol yet.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          _policyOption(
            key: 'encryption-default-policy-never',
            title: 'Never',
            subtitle: 'New conversations stay in plaintext.',
            value: EncryptionDefaultPolicy.never,
            current: policy,
          ),
          _policyOption(
            key: 'encryption-default-policy-if-supported',
            title: 'If supported',
            subtitle:
                'Auto-enable the first enabled cryptosystem a contact is '
                'already known to support.',
            value: EncryptionDefaultPolicy.ifSupported,
            current: policy,
          ),
          _policyOption(
            key: 'encryption-default-policy-always',
            title: 'Always',
            subtitle:
                'Auto-enable the first enabled cryptosystem for every '
                'conversation, even without prior evidence of support.',
            value: EncryptionDefaultPolicy.always,
            current: policy,
          ),
          const Divider(height: 32),
          Text(
            'Cryptosystems',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            'Disabling a cryptosystem removes it from menus and '
            'verification screens everywhere in the app.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          for (final protocol in implementedEncryptionProtocols)
            SwitchListTile(
              key: Key(
                'encryption-protocol-enabled-${encryptionProtocolId(protocol)}',
              ),
              title: Text(_protocolLabels[protocol] ?? protocol.name),
              value: widget.service.isEncryptionProtocolEnabled(protocol),
              onChanged: (enabled) => _setProtocolEnabled(protocol, enabled),
            ),
        ],
      ),
    );
  }

  /// A single tappable default-policy option, using a manually-managed
  /// selection indicator rather than [RadioListTile] (deprecated in favor
  /// of a `RadioGroup` ancestor as of Flutter 3.32) to keep this screen
  /// free of unnecessary `RadioGroup` plumbing for just three options.
  Widget _policyOption({
    required String key,
    required String title,
    required String subtitle,
    required EncryptionDefaultPolicy value,
    required EncryptionDefaultPolicy current,
  }) {
    final selected = current == value;
    return ListTile(
      key: Key(key),
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: () => _setPolicy(value),
    );
  }
}
