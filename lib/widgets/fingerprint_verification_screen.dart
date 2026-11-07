import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../encryption/encryption_backend.dart';
import '../encryption/omemo2_backend.dart';
import '../encryption/ox_backend.dart';
import '../xmpp/xmpp_service.dart';

/// Lets the user review and verify the OMEMO2 device fingerprints of a
/// contact ([peerBareJid]).
///
/// There is no QR *scanner* in this project's dependencies (`qr_flutter`
/// only generates QR codes), so verification works by manual comparison:
/// this screen displays our own fingerprint as both hex text and a QR
/// code (so the contact's device can show the same to compare against,
/// e.g. side-by-side on two screens, or the user can read/copy the hex
/// out-of-band), and lists each of the peer's known device fingerprints
/// with a button to mark it as [TrustState.verified] once the user has
/// confirmed it matches what the contact's client shows for that device.
class FingerprintVerificationScreen extends StatefulWidget {
  const FingerprintVerificationScreen({
    super.key,
    required this.service,
    required this.peerBareJid,
  });

  final XmppService service;
  final String peerBareJid;

  @override
  State<FingerprintVerificationScreen> createState() =>
      _FingerprintVerificationScreenState();
}

class _FingerprintVerificationScreenState
    extends State<FingerprintVerificationScreen> {
  String? _ownFingerprint;
  int? _ownDeviceId;
  List<Omemo2DeviceFingerprint> _peerDevices = const [];
  String? _ownLegacyFingerprint;
  int? _ownLegacyDeviceId;
  List<Omemo2DeviceFingerprint> _peerLegacyDevices = const [];
  String? _ownOxFingerprint;
  List<OxKeyFingerprint> _peerOxKeys = const [];
  bool _loading = true;
  String? _error;
  bool _refreshingOmemo2Devices = false;
  bool _refreshingLegacyOmemoDevices = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ownFingerprint = await widget.service.omemo2OwnFingerprint();
      final ownDeviceId = await widget.service.omemo2OwnDeviceId();
      final peerDevices = await widget.service.omemo2FingerprintsFor(
        widget.peerBareJid,
      );
      final ownLegacyFingerprint =
          await widget.service.legacyOmemoOwnFingerprint();
      final ownLegacyDeviceId =
          await widget.service.legacyOmemoOwnDeviceId();
      final peerLegacyDevices = await widget.service.legacyOmemoFingerprintsFor(
        widget.peerBareJid,
      );
      final ownOxFingerprint = await widget.service.oxOwnFingerprint();
      final peerOxKeys = await widget.service.oxFingerprintsFor(
        widget.peerBareJid,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _ownFingerprint = ownFingerprint;
        _ownDeviceId = ownDeviceId;
        _peerDevices = peerDevices;
        _ownLegacyFingerprint = ownLegacyFingerprint;
        _ownLegacyDeviceId = ownLegacyDeviceId;
        _peerLegacyDevices = peerLegacyDevices;
        _ownOxFingerprint = ownOxFingerprint;
        _peerOxKeys = peerOxKeys;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Failed to load fingerprints: $error';
        _loading = false;
      });
    }
  }

  Future<void> _verify(Omemo2DeviceFingerprint device) async {
    await widget.service.setOmemo2DeviceTrust(
      widget.peerBareJid,
      device.deviceId,
      TrustState.verified,
    );
    await _load();
  }

  Future<void> _verifyLegacy(Omemo2DeviceFingerprint device) async {
    await widget.service.setLegacyOmemoDeviceTrust(
      widget.peerBareJid,
      device.deviceId,
      TrustState.verified,
    );
    await _load();
  }

  /// Revokes trust for [device] (OMEMO2), e.g. because the user no longer
  /// recognises it or it was previously verified in error. Mirrors
  /// `Omemo2Backend.setTrust`'s handling of [TrustState.revoked], which
  /// both untrusts *and* disables the device so it's no longer used for
  /// encryption -- there was previously no way to do this from this
  /// screen once a device had been trusted/verified.
  Future<void> _revoke(Omemo2DeviceFingerprint device) async {
    await widget.service.setOmemo2DeviceTrust(
      widget.peerBareJid,
      device.deviceId,
      TrustState.revoked,
    );
    await _load();
  }

  /// Same as [_revoke], but for a legacy-OMEMO device.
  Future<void> _revokeLegacy(Omemo2DeviceFingerprint device) async {
    await widget.service.setLegacyOmemoDeviceTrust(
      widget.peerBareJid,
      device.deviceId,
      TrustState.revoked,
    );
    await _load();
  }

  /// Wipes the locally cached OMEMO2 device list/bundles for the contact
  /// and re-fetches both live from PEP, for when the device list shown
  /// here appears stale/out of sync (e.g. a device that was removed
  /// elsewhere still shows up, or a transient PEP fetch issue silently
  /// dropped a device -- see `Omemo2Backend.refreshDevices`).
  Future<void> _refreshOmemo2Devices() async {
    setState(() => _refreshingOmemo2Devices = true);
    try {
      final refreshed = await widget.service.refreshOmemo2DevicesFor(
        widget.peerBareJid,
      );
      if (!mounted) {
        return;
      }
      if (!refreshed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Failed to refresh OMEMO2 devices from PEP (are you online?).',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _refreshingOmemo2Devices = false);
      }
    }
    await _load();
  }

  /// Same as [_refreshOmemo2Devices], but for legacy-OMEMO devices.
  Future<void> _refreshLegacyOmemoDevices() async {
    setState(() => _refreshingLegacyOmemoDevices = true);
    try {
      final refreshed = await widget.service.refreshLegacyOmemoDevicesFor(
        widget.peerBareJid,
      );
      if (!mounted) {
        return;
      }
      if (!refreshed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Failed to refresh legacy-OMEMO devices from PEP (are you '
              'online?).',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _refreshingLegacyOmemoDevices = false);
      }
    }
    await _load();
  }

  /// Builds the `xmpp:`-URI QR-code payload real OMEMO clients (e.g.
  /// Conversations) expect for fingerprint verification by scanning, per
  /// the convention documented at
  /// https://xmpp.org/extensions/xep-0384.html and used by Conversations'
  /// own "Share as XMPP URI" QR codes: `xmpp:<jid>?omemo-sid-<id>=<fp>`.
  /// A bare hex fingerprint string (the previous behaviour here) is *not*
  /// recognised by those clients' QR scanners, which show "Invalid QR
  /// Code" even though the code itself scans fine.
  String? _qrUriFor(String? ownBareJid, int? deviceId, String? fingerprint) {
    if (ownBareJid == null || deviceId == null || fingerprint == null) {
      return null;
    }
    final normalizedFingerprint = fingerprint
        .replaceAll(RegExp(r'\s'), '')
        .toLowerCase();
    return 'xmpp:$ownBareJid?omemo-sid-$deviceId=$normalizedFingerprint';
  }

  Future<void> _verifyOxKey(OxKeyFingerprint key) async {
    await widget.service.setOxKeyTrust(
      widget.peerBareJid,
      key.fingerprint,
      TrustState.verified,
    );
    await _load();
  }

  /// Same as [_revoke], but for an OX key.
  Future<void> _revokeOxKey(OxKeyFingerprint key) async {
    await widget.service.setOxKeyTrust(
      widget.peerBareJid,
      key.fingerprint,
      TrustState.revoked,
    );
    await _load();
  }

  /// Exports the identity key produced by [export] (either
  /// `widget.service.exportOmemo2IdentityKey` or
  /// `exportLegacyOmemoIdentityKey`), copies it to the clipboard, and shows
  /// a confirmation so the user knows to paste it into a password manager.
  Future<void> _exportIdentityKey(
    Future<String?> Function() export,
    String label,
  ) async {
    try {
      final pem = await export();
      if (pem == null) {
        throw StateError('No local $label identity yet');
      }
      await Clipboard.setData(ClipboardData(text: pem));
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$label identity key copied to clipboard. Paste it into your '
            'password manager to keep it safe.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to export $label identity key: $error')),
      );
    }
  }

  /// Prompts the user to paste a previously exported identity key and
  /// restores it via [import] (either
  /// `widget.service.importOmemo2IdentityKey` or
  /// `importLegacyOmemoIdentityKey`).
  Future<void> _importIdentityKey(
    Future<void> Function(String) import,
    String label,
  ) async {
    final controller = TextEditingController();
    final pem = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Import $label identity key'),
        content: TextField(
          controller: controller,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: '-----BEGIN ... IDENTITY KEY-----',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (pem == null || pem.trim().isEmpty) {
      return;
    }
    try {
      await import(pem.trim());
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label identity key imported.')),
      );
      await _load();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to import $label identity key: $error')),
      );
    }
  }

  /// Groups hex characters into readable 4-character blocks, mirroring
  /// how OMEMO fingerprints are typically displayed for manual
  /// comparison.
  String _formatFingerprint(String fingerprint) {
    final buffer = StringBuffer();
    for (var i = 0; i < fingerprint.length; i += 4) {
      if (i > 0) {
        buffer.write(' ');
      }
      buffer.write(
        fingerprint.substring(
          i,
          i + 4 > fingerprint.length ? fingerprint.length : i + 4,
        ),
      );
    }
    return buffer.toString();
  }

  String _trustLabel(TrustState state) {
    switch (state) {
      case TrustState.verified:
        return 'Verified';
      case TrustState.tofu:
        return 'Unverified (trust-on-first-use)';
      case TrustState.untrusted:
        return 'Untrusted';
      case TrustState.revoked:
        return 'Revoked';
    }
  }

  Color? _trustColor(BuildContext context, TrustState state) {
    switch (state) {
      case TrustState.verified:
        return Colors.green;
      case TrustState.tofu:
        return Colors.orange;
      case TrustState.untrusted:
      case TrustState.revoked:
        return Theme.of(context).colorScheme.error;
    }
  }

  IconData _trustIcon(TrustState state) {
    switch (state) {
      case TrustState.verified:
        return Icons.verified_user;
      case TrustState.tofu:
        return Icons.help_outline;
      case TrustState.untrusted:
      case TrustState.revoked:
        return Icons.gpp_bad;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Verify ${widget.peerBareJid}'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Text(
                    'Your fingerprint',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Show this to ${widget.peerBareJid} (e.g. side-by-side '
                    'on both devices) so they can compare it against what '
                    'their client shows for you.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  if (_ownFingerprint != null) ...[
                    Center(
                      child: QrImageView(
                        data:
                            _qrUriFor(
                              widget.service.currentUserBareJid,
                              _ownDeviceId,
                              _ownFingerprint,
                            ) ??
                            _ownFingerprint!,
                        size: 180,
                        key: const Key('own-fingerprint-qr'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _formatFingerprint(_ownFingerprint!),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ] else
                    const Text('No local OMEMO2 identity yet.'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('export-omemo2-identity-key'),
                        onPressed: () => _exportIdentityKey(
                          widget.service.exportOmemo2IdentityKey,
                          'OMEMO2',
                        ),
                        icon: const Icon(Icons.copy),
                        label: const Text('Export identity key'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('import-omemo2-identity-key'),
                        onPressed: () => _importIdentityKey(
                          widget.service.importOmemo2IdentityKey,
                          'OMEMO2',
                        ),
                        icon: const Icon(Icons.paste),
                        label: const Text('Import identity key'),
                      ),
                    ],
                  ),
                  const Divider(height: 32),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          "${widget.peerBareJid}'s devices",
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        key: const Key('refresh-omemo2-devices'),
                        tooltip: 'Refresh devices from PEP',
                        icon: _refreshingOmemo2Devices
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                        onPressed: _refreshingOmemo2Devices
                            ? null
                            : _refreshOmemo2Devices,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_peerDevices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('No known OMEMO2 devices for this contact yet.'),
                    ),
                  for (final device in _peerDevices)
                    Card(
                      key: Key('peer-device-${device.deviceId}'),
                      child: ListTile(
                        leading: Icon(
                          _trustIcon(device.trust),
                          color: _trustColor(context, device.trust),
                        ),
                        title: Text('Device ${device.deviceId}'),
                        subtitle: Text(
                          device.fingerprint == null
                              ? 'Fingerprint unknown (bundle not fetched yet)'
                              : '${_formatFingerprint(device.fingerprint!)}\n'
                                    '${_trustLabel(device.trust)}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        isThreeLine: device.fingerprint != null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (device.trust != TrustState.verified)
                              TextButton(
                                onPressed: device.fingerprint == null
                                    ? null
                                    : () => _verify(device),
                                child: const Text('Mark verified'),
                              ),
                            if (device.trust != TrustState.untrusted &&
                                device.trust != TrustState.revoked)
                              TextButton(
                                onPressed: () => _revoke(device),
                                child: const Text('Untrust'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  const Divider(height: 32),
                  Text(
                    'Your legacy OMEMO fingerprint',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This is a *different* identity key from OMEMO2 above. '
                    'Contacts using legacy OMEMO (e.g. Conversations, Gajim, '
                    'Dino) must compare this fingerprint, not the OMEMO2 one '
                    '-- they will never match, since the two protocols use '
                    'separate identities.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  if (_ownLegacyFingerprint != null) ...[
                    Center(
                      child: QrImageView(
                        data:
                            _qrUriFor(
                              widget.service.currentUserBareJid,
                              _ownLegacyDeviceId,
                              _ownLegacyFingerprint,
                            ) ??
                            _ownLegacyFingerprint!,
                        size: 180,
                        key: const Key('own-legacy-fingerprint-qr'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _formatFingerprint(_ownLegacyFingerprint!),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ] else
                    const Text('No local legacy-OMEMO identity yet.'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('export-legacy-omemo-identity-key'),
                        onPressed: () => _exportIdentityKey(
                          widget.service.exportLegacyOmemoIdentityKey,
                          'OMEMO',
                        ),
                        icon: const Icon(Icons.copy),
                        label: const Text('Export identity key'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('import-legacy-omemo-identity-key'),
                        onPressed: () => _importIdentityKey(
                          widget.service.importLegacyOmemoIdentityKey,
                          'OMEMO',
                        ),
                        icon: const Icon(Icons.paste),
                        label: const Text('Import identity key'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          "${widget.peerBareJid}'s legacy OMEMO devices",
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        key: const Key('refresh-legacy-omemo-devices'),
                        tooltip: 'Refresh devices from PEP',
                        icon: _refreshingLegacyOmemoDevices
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                        onPressed: _refreshingLegacyOmemoDevices
                            ? null
                            : _refreshLegacyOmemoDevices,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_peerLegacyDevices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No known legacy-OMEMO devices for this contact yet.',
                      ),
                    ),
                  for (final device in _peerLegacyDevices)
                    Card(
                      key: Key('peer-legacy-device-${device.deviceId}'),
                      child: ListTile(
                        leading: Icon(
                          _trustIcon(device.trust),
                          color: _trustColor(context, device.trust),
                        ),
                        title: Text('Device ${device.deviceId}'),
                        subtitle: Text(
                          device.fingerprint == null
                              ? 'Fingerprint unknown (bundle not fetched yet)'
                              : '${_formatFingerprint(device.fingerprint!)}\n'
                                    '${_trustLabel(device.trust)}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        isThreeLine: device.fingerprint != null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (device.trust != TrustState.verified)
                              TextButton(
                                onPressed: device.fingerprint == null
                                    ? null
                                    : () => _verifyLegacy(device),
                                child: const Text('Mark verified'),
                              ),
                            if (device.trust != TrustState.untrusted &&
                                device.trust != TrustState.revoked)
                              TextButton(
                                onPressed: () => _revokeLegacy(device),
                                child: const Text('Untrust'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  const Divider(height: 32),
                  Text(
                    'Your OX (OpenPGP) fingerprint',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (_ownOxFingerprint != null)
                    SelectableText(
                      _formatFingerprint(_ownOxFingerprint!),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontFamily: 'monospace'),
                    )
                  else
                    const Text('No local OX identity yet.'),
                  const SizedBox(height: 16),
                  Text(
                    "${widget.peerBareJid}'s OX keys",
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (_peerOxKeys.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('No known OX keys for this contact yet.'),
                    ),
                  for (final key in _peerOxKeys)
                    Card(
                      key: Key('peer-ox-key-${key.fingerprint}'),
                      child: ListTile(
                        leading: Icon(
                          _trustIcon(key.trust),
                          color: _trustColor(context, key.trust),
                        ),
                        title: Text(
                          '${_formatFingerprint(key.fingerprint)}\n'
                          '${_trustLabel(key.trust)}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        isThreeLine: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (key.trust != TrustState.verified)
                              TextButton(
                                onPressed: () => _verifyOxKey(key),
                                child: const Text('Mark verified'),
                              ),
                            if (key.trust != TrustState.untrusted &&
                                key.trust != TrustState.revoked)
                              TextButton(
                                onPressed: () => _revokeOxKey(key),
                                child: const Text('Untrust'),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
