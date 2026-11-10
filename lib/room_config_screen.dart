import 'package:flutter/material.dart';

import 'xmpp/room_config.dart';
import 'xmpp/xmpp_service.dart';

/// Lets a room owner/admin inspect and edit a MUC room's configuration form
/// (XEP-0045 §10.2 "Subsequent Room Configuration"), reusing the generic
/// XEP-0004 data forms engine. Mirrors [PepNodeDetailScreen]'s editing UI.
class RoomConfigScreen extends StatefulWidget {
  const RoomConfigScreen({super.key, required this.service, required this.roomJid});

  final XmppService service;
  final String roomJid;

  @override
  State<RoomConfigScreen> createState() => _RoomConfigScreenState();
}

class _RoomConfigScreenState extends State<RoomConfigScreen> {
  late Future<List<RoomConfigField>> _configFuture;

  /// Whether the configuration form is currently in edit mode.
  bool _editing = false;

  /// Whether a configuration submission is in flight.
  bool _saving = false;

  /// `FORM_TYPE` of the room's configuration form, needed to submit edits
  /// back unchanged (see XEP-0045 §10.2).
  String? _formType;

  /// Text controllers for the currently edited fields, keyed by `var` name.
  /// Edited values are comma-joined/split, which keeps multi-value fields
  /// editable without needing per-type widgets. Not used for `list-single`
  /// fields that declare `<option/>`s, or `boolean` fields; see
  /// [_listSingleSelections] and [_booleanSelections].
  final Map<String, TextEditingController> _controllers = {};

  /// The currently selected value for `list-single` fields that declare
  /// `<option/>`s, keyed by `var` name. Using a dropdown restricted to the
  /// server-declared options (XEP-0004 §3.3) rather than free text avoids
  /// submitting a value the server doesn't recognize.
  final Map<String, String?> _listSingleSelections = {};

  /// The currently selected value for `boolean` fields, keyed by `var` name.
  final Map<String, bool> _booleanSelections = {};

  /// The original field metadata (type, label) for the fields being edited,
  /// keyed by `var` name, so submission can preserve each field's `type`.
  Map<String, RoomConfigField> _editedFieldsByVar = {};

  bool _isDropdownField(RoomConfigField field) =>
      field.type == 'list-single' && field.options.isNotEmpty;

  bool _isBooleanField(RoomConfigField field) => field.type == 'boolean';

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _loadConfig() {
    _configFuture = widget.service.fetchRoomConfig(widget.roomJid);
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
      _booleanSelections.clear();
      for (final field in fields) {
        if (_isDropdownField(field)) {
          _listSingleSelections[field.varName] =
              field.values.isNotEmpty ? field.values.first : null;
        } else if (_isBooleanField(field)) {
          _booleanSelections[field.varName] =
              field.values.isNotEmpty && field.values.first == '1';
        } else {
          _controllers[field.varName] = TextEditingController(
            text: field.values.join(', '),
          );
        }
      }
    });
    widget.service.fetchRoomConfigFormType(widget.roomJid).then((formType) {
      if (mounted) {
        _formType = formType;
      }
    });
  }

  void _refresh() {
    setState(() {
      _editing = false;
      _loadConfig();
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
        if (_booleanSelections.containsKey(entry.key)) {
          _booleanSelections[entry.key] =
              entry.value.values.isNotEmpty && entry.value.values.first == '1';
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

  List<String> _currentValues(String varName, RoomConfigField field) {
    if (_isDropdownField(field)) {
      final selection = _listSingleSelections[varName];
      return [?selection];
    }
    if (_isBooleanField(field)) {
      return [_booleanSelections[varName] == true ? '1' : '0'];
    }
    return _controllers[varName]!
        .text
        .split(',')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();
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
          _currentValues(entry.key, entry.value),
          entry.value.values,
        ))
          RoomConfigField(
            varName: entry.key,
            label: entry.value.label,
            type: entry.value.type,
            options: entry.value.options,
            values: _currentValues(entry.key, entry.value),
          ),
    ];
    if (editedFields.isEmpty) {
      setState(() {
        _saving = false;
        _editing = false;
      });
      return;
    }
    final error = await widget.service.submitRoomConfig(
      widget.roomJid,
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
        SnackBar(content: Text('Failed to save room configuration: $error')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Room configuration saved.')),
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
        title: const Text('Room configuration'),
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
          Text(
            widget.roomJid,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
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
          FutureBuilder<List<RoomConfigField>>(
            future: _configFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final fields = snapshot.data ?? const <RoomConfigField>[];
              if (fields.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'No configuration available. You may not be a room owner.',
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
                          ? _buildEditor(theme, field)
                          : _buildViewer(theme, field),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEditor(ThemeData theme, RoomConfigField field) {
    if (_isDropdownField(field)) {
      return DropdownButtonFormField<String>(
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
                option.label?.isNotEmpty == true ? option.label! : option.value,
              ),
            ),
        ],
        onChanged: (value) {
          setState(() {
            _listSingleSelections[field.varName] = value;
          });
        },
      );
    }
    if (_isBooleanField(field)) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          field.label?.isNotEmpty == true ? field.label! : field.varName,
        ),
        value: _booleanSelections[field.varName] ?? false,
        onChanged: (value) {
          setState(() {
            _booleanSelections[field.varName] = value;
          });
        },
      );
    }
    return TextField(
      controller: _controllers[field.varName],
      decoration: InputDecoration(
        labelText: field.label?.isNotEmpty == true
            ? field.label!
            : field.varName,
        helperText: 'Comma-separated for multiple values',
        isDense: true,
      ),
    );
  }

  Widget _buildViewer(ThemeData theme, RoomConfigField field) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            field.label?.isNotEmpty == true ? field.label! : field.varName,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            field.values.isEmpty ? '(empty)' : field.values.join(', '),
            textAlign: TextAlign.end,
            style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}
