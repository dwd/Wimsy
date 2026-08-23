/// Cached server configuration needed to pipeline SASL2 with XMPP IAP.
class IapCacheRecord {
  const IapCacheRecord({
    required this.configVersion,
    required this.sasl2Mechanisms,
    required this.lastMechanism,
    this.configVersionScheme,
    this.bind2Features = const <String>[],
    this.fastMechanisms = const <String>[],
  });

  final String configVersion;
  final String? configVersionScheme;
  final List<String> sasl2Mechanisms;
  final String lastMechanism;
  final List<String> bind2Features;
  final List<String> fastMechanisms;

  Map<String, dynamic> toMap() => {
    'configVersion': configVersion,
    'configVersionScheme': configVersionScheme,
    'sasl2Mechanisms': sasl2Mechanisms,
    'lastMechanism': lastMechanism,
    'bind2Features': bind2Features,
    'fastMechanisms': fastMechanisms,
  };

  static IapCacheRecord? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final configVersion = map['configVersion']?.toString() ?? '';
    final lastMechanism = map['lastMechanism']?.toString() ?? '';
    final mechanisms = _strings(map['sasl2Mechanisms']);
    if (configVersion.isEmpty || lastMechanism.isEmpty || mechanisms.isEmpty) {
      return null;
    }
    final scheme = map['configVersionScheme']?.toString();
    return IapCacheRecord(
      configVersion: configVersion,
      configVersionScheme: scheme == null || scheme.isEmpty ? null : scheme,
      sasl2Mechanisms: mechanisms,
      lastMechanism: lastMechanism,
      bind2Features: _strings(map['bind2Features']),
      fastMechanisms: _strings(map['fastMechanisms']),
    );
  }

  static List<String> _strings(Object? value) => value is List
      ? value
            .map((item) => item.toString())
            .where((item) => item.isNotEmpty)
            .toList()
      : const <String>[];
}
