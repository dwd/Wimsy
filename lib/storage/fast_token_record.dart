/// Persisted XEP-0484 (FAST) credentials for a single account.
///
/// The token is issued by the server during SASL2 authentication and lets the
/// client skip the password exchange on subsequent connections. Tokens are
/// stored in the encrypted Hive box alongside the rest of the account data and
/// are dropped as soon as the server rejects them.
class FastTokenRecord {
  const FastTokenRecord({
    required this.token,
    this.expiry,
    this.mechanism,
  });

  /// The base64-encoded token as issued by the server.
  final String token;

  /// ISO-8601 expiry timestamp, when the server supplied one.
  final String? expiry;

  /// Wire-name of the FAST mechanism the token was issued for, e.g.
  /// `HT2-SHA-256-NONE`.
  final String? mechanism;

  /// Whether the token has an expiry that already lies in the past.
  bool get isExpired {
    final value = expiry;
    if (value == null || value.isEmpty) {
      return false;
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return false;
    }
    return DateTime.now().isAfter(parsed);
  }

  Map<String, dynamic> toMap() {
    return {
      'token': token,
      'expiry': expiry,
      'mechanism': mechanism,
    };
  }

  static FastTokenRecord? fromMap(Map<String, dynamic>? map) {
    if (map == null) {
      return null;
    }
    final token = map['token']?.toString() ?? '';
    if (token.isEmpty) {
      return null;
    }
    final expiry = map['expiry']?.toString();
    final mechanism = map['mechanism']?.toString();
    return FastTokenRecord(
      token: token,
      expiry: (expiry == null || expiry.isEmpty) ? null : expiry,
      mechanism: (mechanism == null || mechanism.isEmpty) ? null : mechanism,
    );
  }
}
