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

### XEdDSA fix: our own identity key and verifying real clients' XEdDSA-signed bundles

Real legacy-OMEMO clients (Conversations/Gajim/Dino, all libsignal-based)
use a single **Curve25519 (X25519) identity keypair** for both ECDH *and*
signing their signed-prekey (SPK), via the **XEdDSA** signature scheme
(https://signal.org/docs/specifications/xeddsa) -- *not* a genuine
Ed25519 identity keypair, unlike OMEMO2 (and unlike `omemo_dart`'s
built-in `OmemoDevice.generateNewDevice()`, which always generates an
Ed25519 `ik`). Treating a real client's raw X25519 identity-key bytes
directly as an Ed25519 public key (the previous behavior) is
mathematically wrong -- the SPK signature essentially never verifies,
causing `InvalidKeyExchangeSignatureError` for every real contact, and
(on the rarer incoming-session path, which has no signature check)
silently wrong ECDH results.

- `lib/encryption/xeddsa.dart` (new, app-level, not vendored): a
  from-scratch, pure-Dart implementation of XEdDSA's
  `calculate_key_pair`/`xeddsa_sign` (BigInt-based field arithmetic for
  the Montgomery<->Edwards birational map, plus a minimal extended
  twisted-Edwards25519 point/scalar-multiplication implementation), used
  to generate our own legacy-OMEMO device's `ik` as a genuine X25519
  keypair and sign our SPK the way real clients expect. No existing Dart
  package was found exposing the lower-level primitives this needs
  (checked `package:cryptography`'s public API). *Verifying* a remote
  bundle's signature doesn't need this file at all -- just the
  Montgomery->Edwards conversion (`convert_mont`) followed by a standard
  `package:cryptography` `Ed25519().verify()`, since "XEd25519 signatures
  are valid Ed25519 signatures and vice versa" per the spec.
- `lib/src/xeddsa_convert.dart` (new, vendored): a small,
  conversion-only (`convertMontgomeryToEdwards`, i.e. `convert_mont`)
  re-implementation of the same birational map, needed *inside* the
  vendored library itself (`OmemoManager._onIncomingStanzaImpl`, see
  below) where application-level code can't intercept. Exported from
  `lib/omemo_dart.dart`. Duplicated rather than shared with
  `lib/encryption/xeddsa.dart` to avoid a dependency cycle between the
  vendored package and the app; `test/xeddsa_test.dart` cross-checks that
  both agree.
- `lib/src/crypto.dart`'s `omemoDH`: only converts an identity
  key/keypair from Ed25519 to X25519 when it's actually Ed25519-typed;
  an already-X25519 identity key/keypair (our own legacy-OMEMO `ik`) is
  now used directly for the DH, instead of asserting (`toCurve25519`
  requires Ed25519 input).
- `lib/src/omemo/bundle.dart`: added an optional `ikIsX25519` field to
  `OmemoBundle` (default `false`, so OMEMO2 is unaffected). When `true`,
  the `ik` getter applies `convertMontgomeryToEdwards` to `ikEncoded`
  before returning it, so the *unmodified* `x3dhFromBundle` Ed25519
  verification and the *unmodified* `OmemoPublicKey.toCurve25519()`
  forward conversion (used for the actual X3DH ECDH step) both "just
  work" -- the forward map is the algebraic inverse of `convert_mont`,
  independent of the discarded sign bit (`test/xeddsa_test.dart` has a
  dedicated round-trip test of this property, using real X25519-generated
  keys; note the round-trip is *not* guaranteed for arbitrary byte
  strings, only genuine X25519 public keys, since some byte strings
  correspond to the curve's quadratic twist). `getFingerprint()` was
  changed to always hash `ikEncoded` directly (not `ik.getBytes()`), so
  the Edwards-converted form never leaks into the user-visible
  fingerprint -- real clients (e.g. Conversations) always display the raw
  X25519 bytes.
- `lib/src/omemo/omemo.dart`: added an optional
  `remoteIdentityKeysAreX25519` field to `OmemoManager` (default `false`).
  When `true`, `_onIncomingStanzaImpl` applies
  `convertMontgomeryToEdwards` to an incoming `<key kex="true">`
  element's `OMEMOKeyExchange.ik` field before treating it as an Ed25519
  point, mirroring `OmemoBundle.ikIsX25519` for the bundle-fetch side.
  `lib/encryption/omemo_backend.dart`'s `OmemoBackend.create()` passes
  `true`; `omemo2_backend.dart`'s `Omemo2Backend.create()` leaves it at
  its default.
- `lib/src/x3dh/x3dh.dart`: `X3DHMessage` gained an optional
  `ikRawBytes` field (and `getIkBytesForAd()` accessor), and
  `x3dhFromBundle`'s associated-data (`ad`) computation now uses
  `bundle.ikEncoded`'s raw bytes instead of `bundle.ik.getBytes()`. This
  was needed because `ad` is folded into the Double Ratchet's per-message
  HMAC (see `OmemoDoubleRatchet._decrypt`/`ratchetEncrypt`'s `sessionAd`
  use) and **both parties must compute byte-identical `ad`** for the same
  identity key -- but with the Montgomery->Edwards conversion applied
  asymmetrically (one party's own `ik` is raw X25519, the same key as
  seen by the other party via `bundle.ik`/`kexIk` is Edwards-converted),
  naively using `ik.getBytes()` on each side produced *different* bytes
  for the same identity, silently breaking every message's HMAC check
  with `InvalidMessageHMACError`. Using the canonical raw-encoded bytes on
  both sides (regardless of which form is needed for the DH/signature
  math) fixes this; a no-op for OMEMO2 (`ikIsX25519`/
  `remoteIdentityKeysAreX25519` both `false`), whose `ikEncoded`/raw
  `kexMessage.ik` bytes already equal what `ik.getBytes()` returns.
- `lib/encryption/omemo_backend.dart`: generates a genuine X25519 `ik`
  for new legacy-OMEMO devices (`_generateNewLegacyDevice`, bypassing
  `OmemoDevice.generateNewDevice()`/the generic `sig()` helper, both of
  which assert Ed25519), signs the SPK via `xeddsaSign` over the
  DJB-type-prefixed SPK bytes (matching `spkSignatureMessageEncoded`'s
  convention), and sets `ikIsX25519: true` when loading a
  legacy-OMEMO bundle from cache or PEP. **Migration**: a legacy-OMEMO
  identity persisted before this fix has an incompatible Ed25519 `ik`
  (not reusable as X25519 -- the two key types are cryptographically
  unrelated secrets); `_loadOrGenerateDevice` detects this (by checking
  the stored `ik`'s `KeyPairType`) and transparently regenerates a fresh
  X25519-based device instead, logging a warning. This is a
  **user-visible, unavoidable one-time reset** of the legacy-OMEMO
  fingerprint and all trust/session state for accounts that had already
  used legacy OMEMO before this fix shipped.
- `lib/xmpp/omemo_pep.dart`: `_legacyBundleFromElement` sets
  `ikIsX25519: true` on bundles parsed from the wire, matching real
  clients' identity-key convention.

### `RatchetAccessQueue` deadlock fix (incoming message never processed, no logging at all)

`RatchetAccessQueue.synchronized` (`lib/src/omemo/queue.dart`) wraps every
per-JID ratchet/session operation (including `OmemoManager.onIncomingStanza`,
the fallback path used by `lib/encryption/omemo_backend.dart`'s
`decryptIncoming` for a peer not yet on the libsignal wire-format stack) in
`enterCriticalSection`/`leaveCriticalSection`. The original implementation
only called `leaveCriticalSection` *after* `await function()` returned,
unconditionally assuming success:

```dart
await enterCriticalSection(jids);
final result = await function();
await leaveCriticalSection(jids);
return result;
```

If `function()` ever threw (e.g. a malformed/undecryptable incoming message,
or any other exception along the decrypt path) the `leaveCriticalSection`
call was skipped entirely, permanently leaving those JIDs marked "running"
in `runningOperations`. Every *subsequent* `synchronized` call for the same
JID(s) -- including completely unrelated ones, like a later incoming message
from the same contact, or a fingerprint lookup for the verification screen
-- then queued up behind the stuck entry forever, since nothing was ever
left to complete its `_RatchetAccessQueueEntry.completer`. This is the root
cause behind reports of a message appearing to do nothing at all (not even
an error log line): the `await` on `onIncomingStanza` for that contact's
next message never completes, so none of `decryptIncoming`'s own logging or
error handling ever runs.

- `lib/src/omemo/queue.dart`: `synchronized` now wraps `await function()` in
  a `try`/`finally`, so `leaveCriticalSection` always runs, even when
  `function()` throws. The thrown exception still propagates to the caller
  as before; only the critical-section bookkeeping is now exception-safe.

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
