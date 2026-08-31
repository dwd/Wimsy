enum ControlMessageKind { receipt, marker, mds }

class ControlMessageOperation {
  const ControlMessageOperation({
    required this.kind,
    required this.toJid,
    required this.referencedId,
    this.markerName,
    this.byValue,
  });

  final ControlMessageKind kind;
  final String toJid;
  final String referencedId;
  final String? markerName;
  final String? byValue;

  String get key => switch (kind) {
    ControlMessageKind.receipt => 'receipt:$toJid:$referencedId',
    ControlMessageKind.marker => 'marker:$toJid:${markerName ?? ''}',
    ControlMessageKind.mds => 'mds:$toJid',
  };

  Map<String, dynamic> toMap() => {
    'kind': kind.name,
    'toJid': toJid,
    'referencedId': referencedId,
    'markerName': markerName,
    'byValue': byValue,
  };

  static ControlMessageOperation? fromMap(Map<String, dynamic> map) {
    final kindName = map['kind']?.toString();
    ControlMessageKind? kind;
    for (final value in ControlMessageKind.values) {
      if (value.name == kindName) kind = value;
    }
    final toJid = map['toJid']?.toString() ?? '';
    final referencedId = map['referencedId']?.toString() ?? '';
    if (kind == null || toJid.isEmpty || referencedId.isEmpty) return null;
    return ControlMessageOperation(
      kind: kind,
      toJid: toJid,
      referencedId: referencedId,
      markerName: map['markerName']?.toString(),
      byValue: map['byValue']?.toString(),
    );
  }
}

/// A semantic outbox: receipts are unique per message while marker and MDS
/// state are coalesced so reconnect never replays stale display positions.
class ControlMessageOutbox {
  ControlMessageOutbox({required this.onChanged});

  final void Function(List<Map<String, dynamic>> entries) onChanged;
  final Map<String, ControlMessageOperation> _operations = {};
  final Map<String, ControlMessageOperation> _stanzaToOperation = {};

  List<ControlMessageOperation> get pending =>
      List.unmodifiable(_operations.values);

  void restore(List<Map<String, dynamic>> entries) {
    _operations.clear();
    _stanzaToOperation.clear();
    for (final entry in entries) {
      final operation = ControlMessageOperation.fromMap(entry);
      if (operation != null) _operations[operation.key] = operation;
    }
  }

  void put(ControlMessageOperation operation) {
    _operations[operation.key] = operation;
    _persist();
  }

  void correlate(String stanzaId, ControlMessageOperation operation) {
    _stanzaToOperation[stanzaId] = operation;
  }

  void acknowledgeStanza(String stanzaId) {
    final operation = _stanzaToOperation.remove(stanzaId);
    if (operation != null) complete(operation);
  }

  void complete(ControlMessageOperation operation) {
    final current = _operations[operation.key];
    if (current != null &&
        current.referencedId == operation.referencedId &&
        current.toJid == operation.toJid &&
        current.kind == operation.kind) {
      _operations.remove(operation.key);
      _persist();
    }
  }

  void clear() {
    _operations.clear();
    _stanzaToOperation.clear();
    _persist();
  }

  void _persist() => onChanged(
    _operations.values
        .map((operation) => operation.toMap())
        .toList(growable: false),
  );
}
