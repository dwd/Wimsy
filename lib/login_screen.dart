import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'deployment_defaults.dart';
import 'login_link.dart';
import 'storage/account_record.dart';
import 'storage/preferences_service.dart';
import 'storage/storage_service.dart';
import 'xmpp/alt_connection.dart';
import 'xmpp/jid_normalization.dart';
import 'xmpp/ws_endpoint.dart';
import 'xmpp/xmpp_service.dart';

/// Standalone login / account-setup screen.
///
/// Reads the last-used account from [StorageService] and [PreferencesService],
/// presents the connection form (JID, password, advanced options), and calls
/// [XmppService.connect] when the user taps Connect.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.service,
    required this.storage,
    required this.preferences,
    this.loginLink,
  });

  final XmppService service;
  final StorageService storage;
  final PreferencesService preferences;
  final ValueListenable<LoginLinkValues?>? loginLink;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _ManualTransport { startTls, directTls, quic }

/// Chooses the JID shown when the login screen opens.
///
/// A last-used JID represents the user's most recent input and therefore takes
/// priority over both the stored account and a deployment-provided web default.
@visibleForTesting
String initialLoginJid({
  required String? cachedJid,
  required String? accountJid,
  required String deploymentJid,
  required bool isWeb,
}) {
  if (cachedJid != null && cachedJid.isNotEmpty) {
    return cachedJid;
  }
  if (accountJid != null && accountJid.isNotEmpty) {
    return accountJid;
  }
  return isWeb ? deploymentJid : '';
}

class _LoginScreenState extends State<LoginScreen> {
  static const int _maximumVisibleLogEntries = 200;

  final TextEditingController _jidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _displayNameController = TextEditingController();
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController(
    text: '5222',
  );
  final TextEditingController _resourceController = TextEditingController(
    text: 'wimsy',
  );
  final TextEditingController _connectionUrlController =
      TextEditingController();
  final TextEditingController _serverCertificateHashController =
      TextEditingController();

  bool _loadedAccount = false;
  bool _rememberPassword = false;
  bool _useWebSocket = kIsWeb;
  bool _useDirectTls = false;

  /// Whether to attempt plain TCP (`_xmpp-client._tcp` SRV records and the
  /// non-TLS fallback). When false, plain-TCP SRV records are ignored.
  bool _useTcp = true;

  /// Whether to attempt QUIC transport (XEP-0467) when available.
  bool _useQuic = true;
  _ManualTransport _manualTransport = _ManualTransport.startTls;
  bool _discoveryOptionsExpanded = false;
  bool _manualConnectionExpanded = false;
  bool _endpointDiscoveryBusy = false;
  String? _endpointDiscoveryMessage;
  String? _lastEndpointDiscoveryDomain;
  Timer? _endpointDiscoveryDebounce;
  final ScrollController _connectionLogScrollController = ScrollController();
  final List<String> _connectionLogEntries = [];
  StreamSubscription<String>? _connectionLogSubscription;

  @override
  void initState() {
    super.initState();
    _connectionLogSubscription = Log.messages.listen(_appendConnectionLog);
    _loadAccount();
    widget.loginLink?.addListener(_applyLoginLink);
  }

  void _appendConnectionLog(String entry) {
    if (!mounted) return;
    setState(() {
      _connectionLogEntries.add(entry);
      if (_connectionLogEntries.length > _maximumVisibleLogEntries) {
        _connectionLogEntries.removeRange(
          0,
          _connectionLogEntries.length - _maximumVisibleLogEntries,
        );
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_connectionLogScrollController.hasClients) return;
      _connectionLogScrollController.jumpTo(
        _connectionLogScrollController.position.maxScrollExtent,
      );
    });
  }

  @override
  void dispose() {
    _endpointDiscoveryDebounce?.cancel();
    _connectionLogSubscription?.cancel();
    _connectionLogScrollController.dispose();
    _jidController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    widget.loginLink?.removeListener(_applyLoginLink);
    _hostController.dispose();
    _portController.dispose();
    _resourceController.dispose();
    _connectionUrlController.dispose();
    _serverCertificateHashController.dispose();
    super.dispose();
  }

  Future<void> _loadAccount() async {
    final cachedJid = widget.preferences.lastJid;
    final account = AccountRecord.fromMap(widget.storage.loadAccount());
    if (!mounted) {
      return;
    }
    setState(() {
      if (account != null) {
        _rememberPassword = account.rememberPassword;
        if (_rememberPassword) {
          _passwordController.text = account.password;
        } else {
          _passwordController.clear();
        }
        _hostController.text = account.host;
        _portController.text = account.port.toString();
        _resourceController.text = account.resource;
        _useWebSocket = kIsWeb ? true : account.useWebSocket;
        _useDirectTls = kIsWeb ? false : account.directTls;
        _useTcp = kIsWeb ? true : account.useTcp;
        _useQuic = account.useQuic;
        if (account.host.isNotEmpty) {
          _manualTransport = account.directTls
              ? _ManualTransport.directTls
              : account.useQuic && !account.useTcp
              ? _ManualTransport.quic
              : _ManualTransport.startTls;
        }
        _connectionUrlController.text = account.connectionUrl;
        _serverCertificateHashController.text = account.serverCertificateHash;
      }
      _jidController.text = initialLoginJid(
        cachedJid: cachedJid,
        accountJid: account?.jid,
        deploymentJid: defaultJid,
        isWeb: kIsWeb,
      );
      if (kIsWeb && defaultWebTransportUrl.isNotEmpty) {
        _connectionUrlController.text = defaultWebTransportUrl;
        _manualConnectionExpanded = true;
      }
      if (kIsWeb && defaultServerCertificateHash.isNotEmpty) {
        _serverCertificateHashController.text = defaultServerCertificateHash;
        _manualConnectionExpanded = true;
      }
      _loadedAccount = true;
    });
    _applyLoginLink();
  }

  void _applyLoginLink() {
    final values = widget.loginLink?.value;
    if (!_loadedAccount || values == null || !mounted) return;
    setState(() {
      _jidController.text = values.jid;
      _passwordController.text = values.password;
      _displayNameController.text = values.displayName;
    });
    _scheduleEndpointDiscovery(values.jid, immediate: true);
  }

  void _handleConnect() {
    final port = int.tryParse(_portController.text.trim()) ?? 5222;
    final hasManualHost = _hostController.text.trim().isNotEmpty;
    final useWebSocket = kIsWeb || (!hasManualHost && _useWebSocket);
    final useDirectTls = kIsWeb
        ? false
        : hasManualHost
        ? _manualTransport == _ManualTransport.directTls
        : _useDirectTls;
    final useTcp = kIsWeb
        ? true
        : hasManualHost
        ? _manualTransport == _ManualTransport.startTls
        : _useTcp;
    final useQuic = hasManualHost
        ? _manualTransport == _ManualTransport.quic
        : _useQuic;
    final enteredJid = _jidController.text.trim();
    final normalizedJid = normalizeEnteredJid(enteredJid) ?? enteredJid;
    final account = AccountRecord(
      jid: normalizedJid,
      password: _rememberPassword ? _passwordController.text : '',
      host: _hostController.text.trim(),
      port: port,
      resource: _resourceController.text.trim().isEmpty
          ? 'wimsy'
          : _resourceController.text.trim(),
      rememberPassword: _rememberPassword,
      useWebSocket: useWebSocket,
      directTls: useDirectTls,
      connectionUrl: _connectionUrlController.text.trim(),
      serverCertificateHash: _serverCertificateHashController.text.trim(),
      useQuic: useQuic,
      useTcp: useTcp,
    );
    widget.storage.storeAccount(account.toMap());
    unawaited(widget.preferences.setLastJid(account.jid));
    widget.service.connect(
      jid: account.jid,
      password: _passwordController.text,
      displayName: _displayNameController.text,
      resource: account.resource,
      host: account.host,
      port: port,
      useWebSocket: useWebSocket,
      directTls: useDirectTls,
      connectionUrl: account.connectionUrl,
      serverCertificateHash: account.serverCertificateHash,
      useQuic: useQuic,
      useTcp: useTcp,
    );
  }

  void _scheduleEndpointDiscovery(String jid, {bool immediate = false}) {
    if (kIsWeb && defaultWebTransportUrl.isNotEmpty) {
      return;
    }
    if (!kIsWeb && !_useWebSocket) {
      return;
    }
    final trimmed = jid.trim();
    if (trimmed.isEmpty) {
      if (_endpointDiscoveryMessage != null) {
        setState(() {
          _endpointDiscoveryMessage = null;
          _endpointDiscoveryBusy = false;
        });
      }
      return;
    }
    _endpointDiscoveryDebounce?.cancel();
    if (immediate) {
      unawaited(_discoverEndpoint(trimmed));
      return;
    }
    _endpointDiscoveryDebounce = Timer(
      const Duration(milliseconds: 700),
      () => _discoverEndpoint(trimmed),
    );
  }

  Future<void> _discoverEndpoint(String jid) async {
    if (kIsWeb && defaultWebTransportUrl.isNotEmpty) {
      return;
    }
    final parsed = Jid.fromFullJid(jid);
    if (!parsed.isValid()) {
      return;
    }
    final domain = _domainFromBareJid(parsed.userAtDomain);
    if (domain.isEmpty) {
      return;
    }
    if (_endpointDiscoveryBusy && _lastEndpointDiscoveryDomain == domain) {
      return;
    }
    if (_lastEndpointDiscoveryDomain == domain &&
        _connectionUrlController.text.trim().isNotEmpty) {
      return;
    }
    setState(() {
      _endpointDiscoveryBusy = true;
      _endpointDiscoveryMessage = 'Discovering WebSocket endpoint…';
    });
    _lastEndpointDiscoveryDomain = domain;
    final discovered = await discoverWebSocketEndpoint(domain);
    if (!mounted) {
      return;
    }
    if (discovered != null) {
      final parsedEndpoint = parseWsEndpoint(discovered.toString());
      if (parsedEndpoint != null) {
        _connectionUrlController.text = parsedEndpoint.uri.toString();
      }
      setState(() {
        _endpointDiscoveryBusy = false;
        _endpointDiscoveryMessage =
            'WebSocket endpoint discovered for $domain.';
      });
      return;
    }
    setState(() {
      _endpointDiscoveryBusy = false;
      _endpointDiscoveryMessage =
          'Could not discover a WebSocket endpoint for $domain. '
          'Enter one manually below.';
      _manualConnectionExpanded = true;
    });
  }

  String _domainFromBareJid(String bareJid) {
    final parts = bareJid.split('@');
    return parts.length == 2 ? parts[1] : '';
  }

  /// Builds the "Discovery options" expandable section.
  ///
  /// Contains transport-selection toggles that control which protocols are
  /// tried during automatic SRV / host-meta discovery: Plain TCP, Direct TLS,
  /// and QUIC.  On web these are all fixed and the section is hidden.
  Widget _buildDiscoveryOptions(XmppService service) {
    // On web, discovery is always WebSocket/WebTransport — nothing to tune.
    if (kIsWeb) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: service.isConnecting
              ? null
              : () {
                  setState(() {
                    _discoveryOptionsExpanded = !_discoveryOptionsExpanded;
                  });
                },
          icon: Icon(
            _discoveryOptionsExpanded ? Icons.expand_less : Icons.expand_more,
          ),
          label: Text(
            _discoveryOptionsExpanded
                ? 'Hide discovery options'
                : 'Discovery options',
          ),
        ),
        if (_discoveryOptionsExpanded) ...[
          const SizedBox(height: 4),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Plain TCP'),
            subtitle: const Text(
              'Allows plain TCP connections via _xmpp-client._tcp SRV. '
              'When off, plain-TCP SRV records are ignored.',
            ),
            value: _useTcp,
            onChanged: service.isConnecting
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() => _useTcp = value);
                  },
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Direct TLS (XEP-0368)'),
            subtitle: const Text(
              'Uses direct TLS when the server advertises it via SRV. '
              'When off, _xmpps-client._tcp SRV records are ignored.',
            ),
            value: _useDirectTls,
            onChanged: service.isConnecting
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() => _useDirectTls = value);
                  },
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('QUIC transport (XEP-0467)'),
            subtitle: const Text(
              'Enables QUIC when the server advertises it via SRV. '
              'Disable to isolate QUIC issues.',
            ),
            value: _useQuic,
            onChanged: service.isConnecting
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() => _useQuic = value);
                  },
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('WebSocket transport'),
            subtitle: const Text(
              'Enables WebSocket when the server advertises it via host-meta. '
              'Useful for testing server WebSocket support.',
            ),
            value: _useWebSocket,
            onChanged: service.isConnecting
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() => _useWebSocket = value);
                  },
          ),
        ],
      ],
    );
  }

  /// Builds the "Manual connection" expandable section.
  ///
  /// On native platforms: host, port, transport protocol, resource, and
  /// (when WebSocket is enabled) the connection endpoint URL.
  ///
  /// On web: only resource and WebSocket endpoint fields are shown, since
  /// TCP host/port are not applicable and WebSocket is always active.
  /// WebTransport is discovered automatically from host-meta and cannot be
  /// overridden manually.
  ///
  /// This section auto-opens when automatic discovery fails.
  Widget _buildManualConnection(XmppService service) {
    // On web, WebSocket is always active; on native only when opted in.
    final showWsFields = _useWebSocket || kIsWeb;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: service.isConnecting
              ? null
              : () {
                  setState(() {
                    _manualConnectionExpanded = !_manualConnectionExpanded;
                  });
                },
          icon: Icon(
            _manualConnectionExpanded ? Icons.expand_less : Icons.expand_more,
          ),
          label: Text(
            _manualConnectionExpanded
                ? 'Hide manual connection'
                : 'Manual connection',
          ),
        ),
        if (_manualConnectionExpanded) ...[
          const SizedBox(height: 4),
          // Host and port are only meaningful on native (TCP-based) platforms.
          if (!kIsWeb) ...[
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _hostController,
                    enabled: !service.isConnecting,
                    decoration: const InputDecoration(
                      labelText: 'Host (optional)',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _portController,
                    enabled: !service.isConnecting,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<_ManualTransport>(
              key: const Key('manual-transport-selector'),
              initialValue: _manualTransport,
              decoration: const InputDecoration(labelText: 'Protocol'),
              items: const [
                DropdownMenuItem(
                  value: _ManualTransport.startTls,
                  child: Text('StartTLS'),
                ),
                DropdownMenuItem(
                  value: _ManualTransport.directTls,
                  child: Text('Direct TLS'),
                ),
                DropdownMenuItem(
                  value: _ManualTransport.quic,
                  child: Text('QUIC'),
                ),
              ],
              onChanged: service.isConnecting
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _manualTransport = value);
                    },
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _resourceController,
            enabled: !service.isConnecting,
            decoration: const InputDecoration(labelText: 'Resource'),
          ),
          if (showWsFields) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _connectionUrlController,
              enabled: !service.isConnecting,
              decoration: const InputDecoration(
                labelText: 'Connection URL',
                hintText:
                    'wss://host/xmpp-websocket  or  https://host/xmpp-webtransport',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _serverCertificateHashController,
              enabled: !service.isConnecting,
              decoration: const InputDecoration(
                labelText: 'Server certificate hash',
                hintText: 'Base64-encoded SHA-256 digest (WebTransport)',
              ),
            ),
          ],
          // On web, show a hint explaining the URL scheme convention and
          // that auto-discovery is used when the field is left blank.
          if (kIsWeb) ...[
            const SizedBox(height: 8),
            Text(
              'Use wss:// for WebSocket or https:// for WebTransport. '
              'When left blank, the endpoint is discovered automatically '
              'from host-meta.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final stateLabel = service.lastConnectionState?.name ?? 'Idle';

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF7E7CE), Color(0xFFE3F0F1), Color(0xFFFDFBF7)],
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: size.width > 640 ? 520 : double.infinity,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Wimsy',
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w300,
                      letterSpacing: 1.2,
                      color: const Color(0xFFA97BFF),
                      fontFamily: 'SF Pro Display',
                      fontFamilyFallback: const [
                        'Helvetica Neue',
                        'Arial',
                        'Roboto',
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'A modern XMPP client built for secure servers.',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 24,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Connect', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _jidController,
                          enabled: !service.isConnecting,
                          decoration: const InputDecoration(
                            labelText: 'JID',
                            hintText: 'user@domain',
                          ),
                          onChanged: (value) =>
                              _scheduleEndpointDiscovery(value),
                          onEditingComplete: () => _scheduleEndpointDiscovery(
                            _jidController.text.trim(),
                            immediate: true,
                          ),
                        ),
                        if (_endpointDiscoveryMessage != null) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              if (_endpointDiscoveryBusy)
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              if (_endpointDiscoveryBusy)
                                const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _endpointDiscoveryMessage!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(
                          controller: _passwordController,
                          enabled: !service.isConnecting,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Password',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _displayNameController,
                          enabled: !service.isConnecting,
                          decoration: const InputDecoration(
                            labelText: 'Display name',
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildDiscoveryOptions(service),
                        _buildManualConnection(service),
                        const SizedBox(height: 12),
                        Material(
                          color: Colors.transparent,
                          child: CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text(
                              'Remember password on this device',
                            ),
                            value: _rememberPassword,
                            onChanged: service.isConnecting
                                ? null
                                : (value) {
                                    if (value == null) {
                                      return;
                                    }
                                    setState(() {
                                      _rememberPassword = value;
                                    });
                                  },
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: service.isConnecting
                                    ? service.triggerImmediateReconnect
                                    : _handleConnect,
                                child: Text(
                                  service.isConnecting
                                      ? 'Connecting... (tap to retry now)'
                                      : 'Connect',
                                ),
                              ),
                            ),
                            if (service.isConnecting) ...[
                              const SizedBox(width: 12),
                              Tooltip(
                                message: 'Stop connecting',
                                child: SizedBox.square(
                                  dimension: 48,
                                  child: FilledButton(
                                    key: const Key('stop-connecting-button'),
                                    style: FilledButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      backgroundColor: theme.colorScheme.error,
                                      foregroundColor:
                                          theme.colorScheme.onError,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                    onPressed: () =>
                                        unawaited(service.disconnect()),
                                    child: const Icon(Icons.stop),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (!_loadedAccount) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Unlocking storage...',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          'Status: ${service.status.name} · $stateLabel',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (service.errorMessage != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            service.errorMessage!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildConnectionLog(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Displays the live xmpp_stone log below the login card. Keeping this log
  /// on the setup screen makes connection negotiation observable on Android,
  /// where developer console output is normally unavailable to the user.
  Widget _buildConnectionLog(ThemeData theme) {
    return Container(
      key: const Key('connection-log-panel'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF17202A).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Connection log',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: _connectionLogEntries.isEmpty
                    ? null
                    : () => setState(_connectionLogEntries.clear),
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 220,
            child: _connectionLogEntries.isEmpty
                ? Text(
                    'Connection details will appear here after you tap Connect.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                    ),
                  )
                : Scrollbar(
                    controller: _connectionLogScrollController,
                    child: ListView.builder(
                      controller: _connectionLogScrollController,
                      itemCount: _connectionLogEntries.length,
                      itemBuilder: (context, index) => SelectableText(
                        _connectionLogEntries[index],
                        style: const TextStyle(
                          color: Color(0xFFD6EAF8),
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
