import 'package:flutter/material.dart';
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
  List<Omemo2DeviceFingerprint> _peerDevices = const [];
  String? _ownOxFingerprint;
  List<OxKeyFingerprint> _peerOxKeys = const [];
  bool _loading = true;
  String? _error;

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
      final peerDevices = await widget.service.omemo2FingerprintsFor(
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
        _peerDevices = peerDevices;
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

  Future<void> _verifyOxKey(OxKeyFingerprint key) async {
    await widget.service.setOxKeyTrust(
      widget.peerBareJid,
      key.fingerprint,
      TrustState.verified,
    );
    await _load();
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
                        data: _ownFingerprint!,
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
                  const Divider(height: 32),
                  Text(
                    "${widget.peerBareJid}'s devices",
                    style: Theme.of(context).textTheme.titleMedium,
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
                        trailing: device.trust == TrustState.verified
                            ? null
                            : TextButton(
                                onPressed: device.fingerprint == null
                                    ? null
                                    : () => _verify(device),
                                child: const Text('Mark verified'),
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
                        trailing: key.trust == TrustState.verified
                            ? null
                            : TextButton(
                                onPressed: () => _verifyOxKey(key),
                                child: const Text('Mark verified'),
                              ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
