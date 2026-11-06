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
- `lib/omemo_dart.dart`: Added `export 'src/protobuf/schema.pb.dart';` so
  `lib/encryption/omemo_backend.dart` can decode/re-encode the
  `OMEMOKeyExchange` protobuf via a public import instead of an
  `implementation_imports`-flagged `package:omemo_dart/src/...` import. See
  the libsignal DJB-type-byte fix below for why it needs to.

### libsignal DJB-type-byte fix for legacy OMEMO's `<key kex="true">` exchange

Real legacy-OMEMO clients (Conversations/Gajim/Dino, all libsignal-based)
serialize the `ik`/`ek` fields of the `OMEMOKeyExchange` protobuf embedded
in a `<key kex="true">` element using libsignal's DJB-type-prefixed public
key format (a leading `0x05` byte + 32 raw bytes = 33 bytes), not the raw
32-byte form `omemo_dart`'s own schema expects. Unpatched, this causes:

- Incoming: `Algorithm ed25519 expects a public key with 32 bytes, but
  got: 33 bytes` when establishing a new session from such a client's
  prekey message (`OmemoPublicKey.fromBytes(kexMessage.ik, ...)` in
  `lib/src/omemo/omemo.dart`).
- Outgoing: Conversations/Gajim/Dino report "Message was not encrypted for
  this device" because they can't parse our un-prefixed `ik`/`ek` fields.

This is **not** patched in the vendored library itself (since OMEMO2 never
uses this prefix and must not be affected); instead
`lib/encryption/omemo_backend.dart`'s `_fixOutgoingKexKey`/
`_fixIncomingKexKey` decode/re-encode the `OMEMOKeyExchange` protobuf
directly to add/strip the byte for legacy OMEMO only, and
`lib/encryption/omemo2_serialization.dart`'s `omemoPublicKeyFromJson`
defensively strips a stray 33rd byte when loading a previously-persisted
ratchet session (whose `ik` may have been baked in with the bug before
this fix existed, and which is never otherwise re-derived). This mirrors
the identical, already-existing fix for PEP-published bundles in
`lib/xmpp/omemo_pep.dart`.

### SPK-signature-message fix for legacy OMEMO's PEP `<bundle/>`

Per the XEdDSA/libsignal convention (see
https://signal.org/docs/specifications/xeddsa and libsignal's
`SignedPreKeyRecord`, which signs `publicKey.serialize()`), real
legacy-OMEMO clients (Conversations/Gajim/Dino) sign the *serialized*,
DJB-type-prefixed form of their signed prekey (33 bytes: `0x05` + 32 raw
bytes), not the raw 32-byte key. `lib/xmpp/omemo_pep.dart` strips that
type byte from every key before handing it to `omemo_dart` for X3DH/ECDH
(see the DJB-type-byte fix above), but `x3dhFromBundle` in
`lib/src/x3dh/x3dh.dart` verified the signature against those same
stripped bytes -- which never matches a real client's signature, so every
session with a real contact failed with `InvalidKeyExchangeSignatureError`
("Failed to prepare legacy OMEMO keys for ...").

- `lib/src/omemo/bundle.dart`: added an optional
  `spkSignatureMessageEncoded` field (and `spkSignatureMessage` getter) to
  `OmemoBundle`, defaulting to `spkEncoded` when unset so OMEMO2 and any
  other caller that doesn't set it is unaffected.
- `lib/src/x3dh/x3dh.dart`: `x3dhFromBundle` now verifies the SPK
  signature against `bundle.spkSignatureMessage` instead of
  `await bundle.spk.getBytes()`.
- `lib/xmpp/omemo_pep.dart`'s `_legacyBundleFromElement` sets
  `spkSignatureMessageEncoded` to the original, un-stripped SPK bytes as
  received on the wire.
- `lib/encryption/omemo_backend.dart`'s bundle JSON cache
  (`_bundleToJson`/`_bundleFromJson`) persists/loads this new field, and
  treats a cached bundle written before this fix (missing the field) as a
  cache miss so it gets refetched instead of reproducing the signature
  failure forever.

## Upstream clone with our patches as real commits

This directory (`vendor/omemo_dart/`) is a flat copy (no `.git`), so our local
patches above aren't visible as actual git history. For that, a full clone of
the upstream repository exists at `vendor/omemo_dart-upstream-clone/`
(git-ignored by Wimsy's own repo — see `.gitignore` — since it's a separate
git history, not part of Wimsy's):

- Cloned from `https://github.com/PapaTutuWawa/omemo_dart.git`.
- Checked out at the same vendored commit, `124c997fa3f0792fa50ff66b80f43c3b71382f89`.
- Branch `wimsy/local-patches` contains one commit applying the exact same
  changes described above to `lib/src/omemo/stanza.dart`,
  `lib/src/omemo/decryption_result.dart`, and `lib/src/omemo/omemo.dart`.

Use this clone to rebase our patch onto a newer upstream release, or to open
a pull request upstream (e.g. by pushing the branch to a fork and opening a
PR against `PapaTutuWawa/omemo_dart`). After rebasing, copy the three patched
files back into this flat `vendor/omemo_dart/` directory and update the
"Vendored commit" note above accordingly.
