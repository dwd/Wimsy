/// Compile-time defaults for a branded web deployment.
///
/// Supply these with `flutter build web --dart-define=NAME=value`. They are
/// intentionally empty in ordinary builds.
const defaultJid = String.fromEnvironment('WIMSY_DEFAULT_JID');
const defaultWebTransportUrl = String.fromEnvironment(
  'WIMSY_DEFAULT_WEBTRANSPORT_URL',
);
const defaultServerCertificateHash = String.fromEnvironment(
  'WIMSY_SERVER_CERTIFICATE_HASH',
);
