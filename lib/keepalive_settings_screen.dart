import 'package:flutter/material.dart';

import 'models/keepalive_tuning.dart';
import 'storage/preferences_service.dart';
import 'xmpp/xmpp_service.dart';

/// A control panel that lists every keepalive/ping/reconnect/call timer used
/// by the XMPP client and lets the user adjust or reset them.
///
/// Changes are applied to the running [XmppService] immediately (so an
/// active connection picks up the new cadence right away) and persisted via
/// [PreferencesService] so they survive app restarts.
class KeepaliveSettingsScreen extends StatefulWidget {
  const KeepaliveSettingsScreen({
    super.key,
    required this.service,
    required this.preferences,
  });

  final XmppService service;
  final PreferencesService preferences;

  @override
  State<KeepaliveSettingsScreen> createState() =>
      _KeepaliveSettingsScreenState();
}

class _KeepaliveSettingsScreenState extends State<KeepaliveSettingsScreen> {
  late KeepaliveTuning _tuning;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _tuning = widget.preferences.keepaliveTuning;
  }

  Future<void> _save() async {
    await widget.preferences.setKeepaliveTuning(_tuning);
    widget.service.applyKeepaliveTuning(_tuning);
    if (!mounted) {
      return;
    }
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Keepalive settings applied')),
    );
  }

  void _resetToDefaults() {
    setState(() {
      _tuning = KeepaliveTuning.defaults;
      _dirty = true;
    });
  }

  void _updateSeconds(
    Duration current,
    int seconds,
    KeepaliveTuning Function(Duration) apply,
  ) {
    if (seconds <= 0) {
      return;
    }
    setState(() {
      _tuning = apply(Duration(seconds: seconds));
      _dirty = true;
    });
  }

  void _updateRatio(double value, KeepaliveTuning Function(double) apply) {
    setState(() {
      _tuning = apply(value);
      _dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Keepalive settings'),
        actions: [
          IconButton(
            tooltip: 'Reset to defaults',
            icon: const Icon(Icons.restore),
            onPressed: _resetToDefaults,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionHeader('Stream management / XMPP ping'),
          _DurationField(
            label: 'SM ack interval (foreground)',
            help: 'How often we request a XEP-0198 ack while the app is active.',
            value: _tuning.smAckIntervalForeground,
            onChanged: (s) => _updateSeconds(
              _tuning.smAckIntervalForeground,
              s,
              (d) => _tuning.copyWith(smAckIntervalForeground: d),
            ),
          ),
          _DurationField(
            label: 'SM ack interval (background)',
            help: 'How often we request a XEP-0198 ack while backgrounded.',
            value: _tuning.smAckIntervalBackground,
            onChanged: (s) => _updateSeconds(
              _tuning.smAckIntervalBackground,
              s,
              (d) => _tuning.copyWith(smAckIntervalBackground: d),
            ),
          ),
          _DurationField(
            label: 'Ping interval (foreground)',
            help: 'XEP-0199 ping cadence when Stream Management is unavailable.',
            value: _tuning.pingIntervalForeground,
            onChanged: (s) => _updateSeconds(
              _tuning.pingIntervalForeground,
              s,
              (d) => _tuning.copyWith(pingIntervalForeground: d),
            ),
          ),
          _DurationField(
            label: 'Ping interval (background)',
            help: 'XEP-0199 ping cadence while backgrounded.',
            value: _tuning.pingIntervalBackground,
            onChanged: (s) => _updateSeconds(
              _tuning.pingIntervalBackground,
              s,
              (d) => _tuning.copyWith(pingIntervalBackground: d),
            ),
          ),
          _DurationField(
            label: 'Pending ack request delay',
            help: 'How long unacked stanzas wait before we request an ack proactively.',
            value: _tuning.pendingAckRequestDelay,
            onChanged: (s) => _updateSeconds(
              _tuning.pendingAckRequestDelay,
              s,
              (d) => _tuning.copyWith(pendingAckRequestDelay: d),
            ),
          ),
          _DurationField(
            label: 'Keepalive max timeout',
            help: 'Upper bound on the latency-derived keepalive timeout.',
            value: _tuning.keepaliveMaxTimeout,
            onChanged: (s) => _updateSeconds(
              _tuning.keepaliveMaxTimeout,
              s,
              (d) => _tuning.copyWith(keepaliveMaxTimeout: d),
            ),
          ),
          const Divider(height: 32),
          _SectionHeader('Reconnection'),
          _DurationField(
            label: 'Reconnect base delay',
            help: 'Delay before the first reconnection attempt.',
            value: _tuning.reconnectBaseDelay,
            onChanged: (s) => _updateSeconds(
              _tuning.reconnectBaseDelay,
              s,
              (d) => _tuning.copyWith(reconnectBaseDelay: d),
            ),
          ),
          _DurationField(
            label: 'Reconnect max delay',
            help: 'Upper bound on the exponential reconnection backoff.',
            value: _tuning.reconnectMaxDelay,
            onChanged: (s) => _updateSeconds(
              _tuning.reconnectMaxDelay,
              s,
              (d) => _tuning.copyWith(reconnectMaxDelay: d),
            ),
          ),
          _RatioField(
            label: 'Reconnect jitter ratio',
            help: 'Fraction of the backoff delay applied as random jitter (0-1).',
            value: _tuning.reconnectJitterRatio,
            onChanged: (v) => _updateRatio(
              v,
              (r) => _tuning.copyWith(reconnectJitterRatio: r),
            ),
          ),
          _DurationField(
            label: 'Connect retry delay',
            help: 'Delay before retrying a fully failed initial connection attempt.',
            value: _tuning.connectRetryDelay,
            onChanged: (s) => _updateSeconds(
              _tuning.connectRetryDelay,
              s,
              (d) => _tuning.copyWith(connectRetryDelay: d),
            ),
          ),
          const Divider(height: 32),
          _SectionHeader('QUIC transport ping'),
          _DurationField(
            label: 'QUIC ping interval (default)',
            help: 'Used when neither a QUIC nor XMPP idle timeout is known.',
            value: _tuning.quicPingIntervalDefault,
            onChanged: (s) => _updateSeconds(
              _tuning.quicPingIntervalDefault,
              s,
              (d) => _tuning.copyWith(quicPingIntervalDefault: d),
            ),
          ),
          _DurationField(
            label: 'QUIC ping interval (minimum floor)',
            help: 'Lower bound so a short idle timeout can\'t cause excessive pings.',
            value: _tuning.quicPingIntervalMinFloor,
            onChanged: (s) => _updateSeconds(
              _tuning.quicPingIntervalMinFloor,
              s,
              (d) => _tuning.copyWith(quicPingIntervalMinFloor: d),
            ),
          ),
          const Divider(height: 32),
          _SectionHeader('MUC self-ping (XEP-0410)'),
          _DurationField(
            label: 'Idle threshold',
            help: 'How long a room must be idle before self-pinging it.',
            value: _tuning.mucSelfPingIdle,
            onChanged: (s) => _updateSeconds(
              _tuning.mucSelfPingIdle,
              s,
              (d) => _tuning.copyWith(mucSelfPingIdle: d),
            ),
          ),
          _DurationField(
            label: 'Check interval',
            help: 'How often the idle-room sweep runs.',
            value: _tuning.mucSelfPingCheckInterval,
            onChanged: (s) => _updateSeconds(
              _tuning.mucSelfPingCheckInterval,
              s,
              (d) => _tuning.copyWith(mucSelfPingCheckInterval: d),
            ),
          ),
          _DurationField(
            label: 'Response timeout',
            help: 'How long to wait for a self-ping response before rejoining.',
            value: _tuning.mucSelfPingTimeout,
            onChanged: (s) => _updateSeconds(
              _tuning.mucSelfPingTimeout,
              s,
              (d) => _tuning.copyWith(mucSelfPingTimeout: d),
            ),
          ),
          const Divider(height: 32),
          _SectionHeader('Client state & calls'),
          _DurationField(
            label: 'CSI idle delay',
            help: 'Delay before sending XEP-0352 <inactive/> in the background.',
            value: _tuning.csiIdleDelay,
            onChanged: (s) => _updateSeconds(
              _tuning.csiIdleDelay,
              s,
              (d) => _tuning.copyWith(csiIdleDelay: d),
            ),
          ),
          _DurationField(
            label: 'Outgoing call timeout',
            help: 'How long an outgoing call may ring before it\'s unanswered.',
            value: _tuning.outgoingCallTimeout,
            onChanged: (s) => _updateSeconds(
              _tuning.outgoingCallTimeout,
              s,
              (d) => _tuning.copyWith(outgoingCallTimeout: d),
            ),
          ),
          _DurationField(
            label: 'Incoming call timeout',
            help: 'How long an incoming call may ring before it\'s missed.',
            value: _tuning.incomingCallTimeout,
            onChanged: (s) => _updateSeconds(
              _tuning.incomingCallTimeout,
              s,
              (d) => _tuning.copyWith(incomingCallTimeout: d),
            ),
          ),
          _DurationField(
            label: 'Call stats interval',
            help: 'How often call quality statistics are sampled.',
            value: _tuning.callStatsInterval,
            onChanged: (s) => _updateSeconds(
              _tuning.callStatsInterval,
              s,
              (d) => _tuning.copyWith(callStatsInterval: d),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const ValueKey('saveAndApplyButton'),
            onPressed: _dirty ? _save : null,
            child: const Text('Save & apply'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}

class _DurationField extends StatefulWidget {
  const _DurationField({
    required this.label,
    required this.help,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String help;
  final Duration value;
  final ValueChanged<int> onChanged;

  @override
  State<_DurationField> createState() => _DurationFieldState();
}

class _DurationFieldState extends State<_DurationField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value.inSeconds.toString(),
  );

  @override
  void didUpdateWidget(_DurationField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _controller.text = widget.value.inSeconds.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.label, style: Theme.of(context).textTheme.bodyLarge),
                Text(
                  widget.help,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 96,
            child: TextField(
              key: ValueKey('durationField_${widget.label}'),
              controller: _controller,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.end,
              decoration: const InputDecoration(
                suffixText: 's',
                isDense: true,
              ),
              onChanged: (text) {
                final parsed = int.tryParse(text.trim());
                if (parsed != null) {
                  widget.onChanged(parsed);
                }
              },
              onSubmitted: (text) {
                final parsed = int.tryParse(text.trim());
                if (parsed != null) {
                  widget.onChanged(parsed);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RatioField extends StatelessWidget {
  const _RatioField({
    required this.label,
    required this.help,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String help;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
          Text(
            help,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: value.clamp(0.0, 1.0),
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: value.toStringAsFixed(2),
                  onChanged: onChanged,
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  value.toStringAsFixed(2),
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
