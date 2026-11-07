import 'package:flutter/material.dart';

import 'pep/pep_explorer.dart';
import 'xmpp/xmpp_service.dart';

/// Lists all nodes on the logged-in user's PEP (XEP-0163) service,
/// discovered via a XEP-0030 disco#items query against their own bare JID.
///
/// Tapping a node opens [PepNodeDetailScreen], which shows the node's
/// configuration form and its currently published items.
class PepExplorerScreen extends StatefulWidget {
  const PepExplorerScreen({super.key, required this.service});

  final XmppService service;

  @override
  State<PepExplorerScreen> createState() => _PepExplorerScreenState();
}

class _PepExplorerScreenState extends State<PepExplorerScreen> {
  late Future<List<PepNodeSummary>> _nodesFuture;

  @override
  void initState() {
    super.initState();
    _nodesFuture = widget.service.fetchPepNodes();
  }

  void _refresh() {
    setState(() {
      _nodesFuture = widget.service.fetchPepNodes();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PEP explorer'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<PepNodeSummary>>(
        future: _nodesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final nodes = snapshot.data ?? const <PepNodeSummary>[];
          if (nodes.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No PEP nodes found.',
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: nodes.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final node = nodes[index];
              return ListTile(
                title: Text(node.node),
                subtitle: node.name != null ? Text(node.name!) : null,
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => PepNodeDetailScreen(
                        service: widget.service,
                        node: node.node,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

/// Shows a single PEP node's configuration fields and published items.
class PepNodeDetailScreen extends StatefulWidget {
  const PepNodeDetailScreen({
    super.key,
    required this.service,
    required this.node,
  });

  final XmppService service;
  final String node;

  @override
  State<PepNodeDetailScreen> createState() => _PepNodeDetailScreenState();
}

class _PepNodeDetailScreenState extends State<PepNodeDetailScreen> {
  late Future<List<PepNodeConfigField>> _configFuture;
  late Future<List<PepNodeItem>> _itemsFuture;

  /// Whether the configuration section is currently in edit mode.
  bool _editing = false;

  /// Whether a configuration submission is in flight.
  bool _saving = false;

  /// `FORM_TYPE` of the node's configuration form, needed to submit edits
  /// back unchanged (see XEP-0060 §8.2.4).
  String? _formType;

  /// Text controllers for the currently edited fields, keyed by `var` name.
  /// Edited values are comma-joined/split, which keeps multi-value fields
  /// editable without needing per-type widgets. Not used for `list-single`
  /// fields that declare `<option/>`s; see [_listSingleSelections].
  final Map<String, TextEditingController> _controllers = {};

  /// The currently selected value for `list-single` fields that declare
  /// `<option/>`s, keyed by `var` name. Using a dropdown restricted to the
  /// server-declared options (XEP-0004 §3.3) rather than free text avoids
  /// submitting a value the server doesn't recognize (e.g. a typo'd access
  /// model).
  final Map<String, String?> _listSingleSelections = {};

  /// The original field metadata (type, label) for the fields being edited,
  /// keyed by `var` name, so submission can preserve each field's `type`.
  Map<String, PepNodeConfigField> _editedFieldsByVar = {};

  bool _isDropdownField(PepNodeConfigField field) =>
      field.type == 'list-single' && field.options.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _itemsFuture = widget.service.fetchPepNodeItems(widget.node);
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _loadConfig() {
    _configFuture = widget.service.fetchPepNodeConfig(widget.node);
    _configFuture.then((fields) {
      if (!mounted) {
        return;
      }
      _editedFieldsByVar = {for (final field in fields) field.varName: field};
      for (final controller in _controllers.values) {
        controller.dispose();
      }
      _controllers.clear();
      _listSingleSelections.clear();
      for (final field in fields) {
        if (_isDropdownField(field)) {
          _listSingleSelections[field.varName] =
              field.values.isNotEmpty ? field.values.first : null;
        } else {
          _controllers[field.varName] = TextEditingController(
            text: field.values.join(', '),
          );
        }
      }
    });
    widget.service.fetchPepNodeConfigFormType(widget.node).then((formType) {
      if (mounted) {
        _formType = formType;
      }
    });
  }

  void _refresh() {
    setState(() {
      _editing = false;
      _loadConfig();
      _itemsFuture = widget.service.fetchPepNodeItems(widget.node);
    });
  }

  void _startEditing() {
    setState(() {
      _editing = true;
    });
  }

  void _cancelEditing() {
    setState(() {
      _editing = false;
      // Reset controls back to the last fetched values.
      for (final entry in _editedFieldsByVar.entries) {
        _controllers[entry.key]?.text = entry.value.values.join(', ');
        if (_listSingleSelections.containsKey(entry.key)) {
          _listSingleSelections[entry.key] =
              entry.value.values.isNotEmpty ? entry.value.values.first : null;
        }
      }
    });
  }

  /// Returns `true` if [a] and [b] contain the same values in the same
  /// order, i.e. the field's current value is unchanged from its original.
  bool _sameValues(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  Future<void> _saveEditing() async {
    setState(() {
      _saving = true;
    });
    // XEP-0004 §3.5 ("Partial Form Submission") only requires fields the
    // submitter actually changed to be included; sending every field back
    // unconditionally (even ones left at their original value) is not
    // required by the spec and some servers reject such "full" submissions
    // for fields they don't expect a client to set. So only the fields
    // whose values the user actually edited are included here.
    final editedFields = [
      for (final entry in _editedFieldsByVar.entries)
        if (!_sameValues(
          _isDropdownField(entry.value)
              ? [
                  if (_listSingleSelections[entry.key] != null)
                    _listSingleSelections[entry.key]!,
                ]
              : _controllers[entry.key]!
                  .text
                  .split(',')
                  .map((v) => v.trim())
                  .where((v) => v.isNotEmpty)
                  .toList(),
          entry.value.values,
        ))
          PepNodeConfigField(
            varName: entry.key,
            label: entry.value.label,
            type: entry.value.type,
            options: entry.value.options,
            values: _isDropdownField(entry.value)
                ? [
                    if (_listSingleSelections[entry.key] != null)
                      _listSingleSelections[entry.key]!,
                  ]
                : _controllers[entry.key]!
                    .text
                    .split(',')
                    .map((v) => v.trim())
                    .where((v) => v.isNotEmpty)
                    .toList(),
          ),
    ];
    if (editedFields.isEmpty) {
      setState(() {
        _saving = false;
        _editing = false;
      });
      return;
    }
    final error = await widget.service.submitPepNodeConfig(
      widget.node,
      _formType,
      editedFields,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _saving = false;
    });
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save configuration: $error')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Configuration saved.')),
    );
    setState(() {
      _editing = false;
      _loadConfig();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.node, overflow: TextOverflow.ellipsis),
        actions: [
          if (!_editing)
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Configuration', style: theme.textTheme.titleMedium),
              ),
              if (_editing) ...[
                TextButton(
                  onPressed: _saving ? null : _cancelEditing,
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: _saving ? null : _saveEditing,
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ] else
                TextButton.icon(
                  onPressed: _startEditing,
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<PepNodeConfigField>>(
            future: _configFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final fields = snapshot.data ?? const <PepNodeConfigField>[];
              if (fields.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'No configuration available.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final field in fields)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: _editing
                          ? (_isDropdownField(field)
                              ? DropdownButtonFormField<String>(
                                  initialValue: _listSingleSelections[field.varName],
                                  decoration: InputDecoration(
                                    labelText: field.label?.isNotEmpty == true
                                        ? field.label!
                                        : field.varName,
                                    isDense: true,
                                  ),
                                  items: [
                                    for (final option in field.options)
                                      DropdownMenuItem(
                                        value: option.value,
                                        child: Text(
                                          option.label?.isNotEmpty == true
                                              ? option.label!
                                              : option.value,
                                        ),
                                      ),
                                  ],
                                  onChanged: (value) {
                                    setState(() {
                                      _listSingleSelections[field.varName] = value;
                                    });
                                  },
                                )
                              : TextField(
                                  controller: _controllers[field.varName],
                                  decoration: InputDecoration(
                                    labelText: field.label?.isNotEmpty == true
                                        ? field.label!
                                        : field.varName,
                                    helperText: 'Comma-separated for multiple values',
                                    isDense: true,
                                  ),
                                ))
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    field.label?.isNotEmpty == true
                                        ? field.label!
                                        : field.varName,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    field.values.isEmpty
                                        ? '(empty)'
                                        : field.values.join(', '),
                                    textAlign: TextAlign.end,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                ],
              );
            },
          ),
          const Divider(height: 32),
          Text('Items', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          FutureBuilder<List<PepNodeItem>>(
            future: _itemsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final items = snapshot.data ?? const <PepNodeItem>[];
              if (items.isEmpty) {
                return Text(
                  'No items published.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in items)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (item.id.isNotEmpty)
                              Text(
                                item.id,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            const SizedBox(height: 4),
                            SelectableText(
                              item.xml.isEmpty ? '(empty payload)' : item.xml,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
