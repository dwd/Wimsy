# Vendoring note

This directory contains a vendored copy of the upstream [`omemo_dart`](https://github.com/PapaTutuWawa/omemo_dart)
package, which is MIT licensed (see `LICENSE` in this directory).

- Upstream repository: https://github.com/PapaTutuWawa/omemo_dart
- Vendored commit: `124c997fa3f0792fa50ff66b80f43c3b71382f89` (2024-09-29)
- Vendored version: `0.6.0` (per upstream `pubspec.yaml`)

It is vendored flatly (no nested `.git`, CI config, or Nix flake files) the same way
`vendor/xmpp_stone` and `vendor/flutter_quic` are vendored in this repository, and is referenced
from the top-level `pubspec.yaml` as a `path:` dependency.

As noted in upstream's own `README.md`: **this library has not been audited for its security**.
Use at your own risk, and track upstream for security-relevant fixes.

## Local patches

- `lib/src/omemo/stanza.dart`, `lib/src/omemo/decryption_result.dart`,
  `lib/src/omemo/omemo.dart`: Added additive, backward-compatible optional
  parameters so a caller of `OmemoManager` can supply its own payload-cipher
  key material/ciphertext on send (`OmemoOutgoingStanza.rawKeyMaterial`,
  `OmemoOutgoingStanza.ciphertext`) and request the raw ratchet-unwrapped key
  material instead of automatic decryption on receive
  (`OmemoIncomingStanza.skipPayloadDecryption`,
  `DecryptionResult.rawKeyMaterial`). This reuses all of the existing
  X3DH/Double-Ratchet session/device/bundle/trust machinery but allows the
  caller to substitute a different payload cipher than the library's
  built-in AES-256-CBC+HMAC-SHA-256 (e.g. `lib/encryption/omemo_backend.dart`
  uses this to implement legacy OMEMO's XEP-0384 v0.3.0 mandated
  AES-128-GCM payload cipher, since that XEP has no ciphersuite negotiation
  unlike OMEMO2/XEP-0420). None of the new parameters are used by
  `lib/encryption/omemo2_backend.dart`, which keeps relying on the default
  AES-256-CBC+HMAC-SHA-256 behavior unmodified.
