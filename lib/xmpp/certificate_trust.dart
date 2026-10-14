import 'package:crypto/crypto.dart';
import 'package:universal_io/io.dart' show X509Certificate;

/// Computes the lower-case hex SHA-256 fingerprint of [certificate]'s DER
/// encoding, used both to look up and to record trust-on-first-use
/// decisions for TLS certificates that fail standard CA validation.
String certificateSha256Fingerprint(X509Certificate certificate) {
  return sha256.convert(certificate.der).toString();
}

/// Formats [fingerprint] (as returned by [certificateSha256Fingerprint]) as
/// upper-case colon-separated hex pairs (e.g. `AB:CD:EF:...`), the
/// conventional presentation for certificate fingerprints.
String formatCertificateFingerprint(String fingerprint) {
  final upper = fingerprint.toUpperCase();
  final pairs = <String>[
    for (var i = 0; i < upper.length; i += 2)
      upper.substring(i, i + 2 > upper.length ? upper.length : i + 2),
  ];
  return pairs.join(':');
}

/// Describes a TLS certificate that failed standard validation (e.g. a
/// self-signed certificate) and is awaiting a trust decision from the user,
/// surfaced by [XmppService.pendingCertificate].
class PendingCertificateTrust {
  const PendingCertificateTrust({
    required this.host,
    required this.port,
    required this.subject,
    required this.issuer,
    required this.sha256Fingerprint,
  });

  final String host;
  final int port;
  final String subject;
  final String issuer;

  /// Lower-case hex SHA-256 fingerprint, as returned by
  /// [certificateSha256Fingerprint].
  final String sha256Fingerprint;
}
