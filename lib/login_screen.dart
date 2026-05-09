import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'storage/account_record.dart';
import 'storage/preferences_service.dart';
import 'storage/storage_service.dart';
import 'xmpp/alt_connection.dart';
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
  });

  final XmppService service;
  final StorageService storage;
  final PreferencesService preferences;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _jidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController(
    text: '5222',
  );
  final TextEditingController _resourceController = TextEditingController(
    text: 'wimsy',
  );
  final TextEditingController _wsEndpointController = TextEditingController();
  final TextEditingController _wsProtocolsController = TextEditingController();

  bool _loadedAccount = false;
  bool _rememberPassword = false;
  bool _useWebSocket = kIsWeb;
  bool _useDirectTls = false;
  /// Whether to attempt plain TCP (`_xmpp-client._tcp` SRV records and the
  /// non-TLS fallback). When false, plain-TCP SRV records are ignored.
  bool _useTcp = true;
  /// Whether to attempt QUIC transport (XEP-0467) when available.
  bool _useQuic = true;
  bool _advancedOptionsExpanded = false;
  bool _endpointDiscoveryBusy = false;
  String? _endpointDiscoveryMessage;
  String? _lastEndpointDiscoveryDomain;
  Timer? _endpointDiscoveryDebounce;

  @override
  void initState() {
    super.initState();
    _loadAccount();
  }

  @override
  void dispose() {
    _endpointDiscoveryDebounce?.cancel();
    _jidController.dispose();
    _passwordController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _resourceController.dispose();
    _wsEndpointController.dispose();
    _wsProtocolsController.dispose();
    super.dispose();
  }

  Future<void> _loadAccount() async {
    final cachedJid = widget.preferences.lastJid;
    final account = AccountRecord.fromMap(widget.storage.loadAccount());
    if (!mounted) {
      return;
    }
    setState(() {
      if (cachedJid != null && cachedJid.isNotEmpty) {
        _jidController.text = cachedJid;
      }
      if (account != null) {
        _jidController.text = account.jid;
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
        _wsEndpointController.text = account.wsEndpoint;
        if (account.wsProtocols.isNotEmpty) {
          _wsProtocolsController.text = account.wsProtocols.join(', ');
        } else {
          _wsProtocolsController.clear();
        }
      }
      _loadedAccount = true;
    });
  }

  void _handleConnect() {
    final port = int.tryParse(_portController.text.trim()) ?? 5222;
    final useWebSocket = kIsWeb || _useWebSocket;
    final useDirectTls = kIsWeb ? false : _useDirectTls;
    final useTcp = kIsWeb ? true : _useTcp;
    final wsProtocols = _wsProtocolsController.text
        .split(',')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList();
    final account = AccountRecord(
      jid: _jidController.text.trim(),
      password: _rememberPassword ? _passwordController.text : '',
      host: _hostController.text.trim(),
      port: port,
      resource: _resourceController.text.trim().isEmpty
          ? 'wimsy'
          : _resourceController.text.trim(),
      rememberPassword: _rememberPassword,
      useWebSocket: useWebSocket,
      directTls: useDirectTls,
      wsEndpoint: _wsEndpointController.text.trim(),
      wsProtocols: wsProtocols,
      useQuic: _useQuic,
      useTcp: useTcp,
    );
    widget.storage.storeAccount(account.toMap());
    unawaited(widget.preferences.setLastJid(account.jid));
    widget.service.connect(
      jid: account.jid,
      password: _passwordController.text,
      resource: account.resource,
      host: account.host,
      port: port,
      useWebSocket: useWebSocket,
      directTls: useDirectTls,
      wsEndpoint: account.wsEndpoint,
      wsProtocols: wsProtocols,
      useQuic: _useQuic,
      useTcp: useTcp,
    );
  }

  void _scheduleEndpointDiscovery(String jid, {bool immediate = false}) {
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
        _wsEndpointController.text.trim().isNotEmpty) {
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
        _wsEndpointController.text = parsedEndpoint.uri.toString();
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
          'Could not discover a WebSocket endpoint for $domain. Enter one in advanced options.';
      _advancedOptionsExpanded = true;
    });
  }

  String _domainFromBareJid(String bareJid) {
    final parts = bareJid.split('@');
    return parts.length == 2 ? parts[1] : '';
  }

  Widget _buildAdvancedOptions(XmppService service, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: service.isConnecting
              ? null
              : () {
                  setState(() {
                    _advancedOptionsExpanded = !_advancedOptionsExpanded;
                  });
                },
          icon: Icon(
            _advancedOptionsExpanded ? Icons.expand_less : Icons.expand_more,
          ),
          label: Text(
            _advancedOptionsExpanded
                ? 'Hide advanced options'
                : 'Show advanced options',
          ),
        ),
        if (_advancedOptionsExpanded) ...[
          const SizedBox(height: 4),
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
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Direct TLS (XEP-0368)'),
            subtitle: const Text(
              'Uses direct TLS when the server advertises it via SRV. '
              'When off, _xmpps-client._tcp SRV records are ignored.',
            ),
            value: _useDirectTls,
            onChanged: service.isConnecting || kIsWeb
                ? null
                : (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _useDirectTls = value;
                    });
                  },
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Plain TCP'),
            subtitle: const Text(
              'Allows plain TCP connections via _xmpp-client._tcp SRV. '
              'When off, plain-TCP SRV records are ignored and no plain-TCP '
              'connection will be attempted.',
            ),
            value: kIsWeb ? true : _useTcp,
            onChanged: service.isConnecting || kIsWeb
                ? null
                : (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _useTcp = value;
                    });
                  },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _resourceController,
            enabled: !service.isConnecting,
            decoration: const InputDecoration(labelText: 'Resource'),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Use QUIC transport (XEP-0467)'),
            subtitle: const Text(
              'Enables QUIC when the server advertises it via SRV. Disable to isolate QUIC issues.',
            ),
            value: kIsWeb ? false : _useQuic,
            onChanged: service.isConnecting || kIsWeb
                ? null
                : (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _useQuic = value;
                    });
                  },
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Use WebSocket transport'),
            subtitle: kIsWeb
                ? const Text('Required for web builds.')
                : const Text('Useful for testing server WebSocket support.'),
            value: kIsWeb ? true : _useWebSocket,
            onChanged: service.isConnecting || kIsWeb
                ? null
                : (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _useWebSocket = value;
                    });
                  },
          ),
          if (_useWebSocket || kIsWeb) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _wsEndpointController,
              enabled: !service.isConnecting,
              decoration: const InputDecoration(
                labelText: 'WebSocket endpoint',
                hintText: 'wss://host/xmpp-websocket',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _wsProtocolsController,
              enabled: !service.isConnecting,
              decoration: const InputDecoration(
                labelText: 'WebSocket subprotocols (optional)',
                hintText: 'xmpp, stanza',
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
                        _buildAdvancedOptions(service, theme),
                        const SizedBox(height: 12),
                        CheckboxListTile(
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
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: service.isConnecting
                                    ? null
                                    : _handleConnect,
                                child: Text(
                                  service.isConnecting
                                      ? 'Connecting...'
                                      : 'Connect',
                                ),
                              ),
                            ),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
