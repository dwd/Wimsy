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
