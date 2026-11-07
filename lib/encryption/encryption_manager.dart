import 'dart:async';

import 'package:xmpp_stone/xmpp_stone.dart';

import '../storage/storage_service.dart';
import '../xmpp/omemo_pep.dart' hide omemo2Namespace, legacyOmemoNamespace;
import '../xmpp/ox_pep.dart' hide oxNamespace;
import 'encryption_backend.dart';
import 'omemo2_backend.dart';
import 'omemo2_serialization.dart';
import 'omemo_backend.dart';
import 'ox_backend.dart';

typedef EncryptionUpdateCallback = void Function();

/// Identifies which end-to-end-encryption protocol (if any) is selected
/// for a given 1:1 conversation.
///
/// [none], [omemo2], [legacyOmemo], and [ox] are all implemented.
enum EncryptionProtocol {
  /// No end-to-end encryption; messages are sent/received in plaintext.
  none,

  /// `urn:xmpp:omemo:2` (XEP-0384 "OMEMO2").
  omemo2,

  /// Legacy OMEMO (`eu.siacs.conversations.axolotl`, XEP-0384 v0.3.0), for
  /// interop with legacy-OMEMO-only clients (e.g. Conversations, Gajim,
  /// Dino). Dispatches to [OmemoBackend].
  legacyOmemo,

  /// OpenPGP for XMPP (XEP-0373/XEP-0374, "OX"). Dispatches to
  /// [OxBackend].
  ox,
}

/// Maps an [EncryptionProtocol] to the stable string id used for
/// persistence and for matching [EncryptionBackend.protocolId].
String encryptionProtocolId(EncryptionProtocol protocol) {
  switch (protocol) {
    case EncryptionProtocol.none:
      return 'none';
    case EncryptionProtocol.omemo2:
      return 'omemo2';
    case EncryptionProtocol.legacyOmemo:
      return 'omemo';
    case EncryptionProtocol.ox:
      return 'ox';
  }
}

/// Parses a persisted/serialized protocol id back into an
/// [EncryptionProtocol], defaulting to [EncryptionProtocol.none] for
/// unknown/absent values.
EncryptionProtocol encryptionProtocolFromId(String? id) {
  switch (id) {
    case 'omemo2':
      return EncryptionProtocol.omemo2;
    case 'omemo':
      return EncryptionProtocol.legacyOmemo;
    case 'ox':
      return EncryptionProtocol.ox;
    default:
      return EncryptionProtocol.none;
  }
}

/// Tracks, per bare JID (1:1 conversation), which [EncryptionProtocol] is
/// currently selected, persists that selection, and dispatches
/// encrypt/decrypt calls to the matching [EncryptionBackend].
///
/// Constructed similarly to [PepManager] (see `lib/pep/pep_manager.dart`):
/// takes the live [connection]/[storage]/[selfBareJid] plus an
/// [onUpdate] callback invoked whenever the manager's state changes in a
/// way the UI may care about (e.g. a protocol selection changed).
class EncryptionManager {
  EncryptionManager({
    required this.connection,
    required this.storage,
    required this.selfBareJid,
    required EncryptionUpdateCallback onUpdate,
  }) : _onUpdate = onUpdate;

  final Connection connection;
  final StorageService storage;
  final String selfBareJid;
  final EncryptionUpdateCallback _onUpdate;

  final Map<String, EncryptionProtocol> _selectedProtocol = {};
  final Map<String, EncryptionBackend> _backendsByProtocolId = {};

  OmemoPep? _omemoPep;
  OxPep? _oxPep;
  Future<Omemo2Backend>? _omemo2BackendFuture;
  Future<OmemoBackend>? _legacyOmemoBackendFuture;
  Future<OxBackend>? _oxBackendFuture;

  /// Returns the currently selected [EncryptionProtocol] for [bareJid],
  /// loading it from persisted storage on first access.
  EncryptionProtocol protocolFor(String bareJid) {
    return _selectedProtocol.putIfAbsent(
      bareJid,
      () => encryptionProtocolFromId(
        storage.loadEncryptionProtocolForJid(bareJid),
      ),
    );
  }

  /// Selects [protocol] for [bareJid] and persists the choice.
  Future<void> setProtocolFor(String bareJid, EncryptionProtocol protocol) async {
    _selectedProtocol[bareJid] = protocol;
    if (protocol == EncryptionProtocol.none) {
      await storage.storeEncryptionProtocolForJid(bareJid, null);
    } else {
      await storage.storeEncryptionProtocolForJid(
        bareJid,
        encryptionProtocolId(protocol),
      );
    }
    // Proactively kick off device discovery as soon as encryption is
    // turned on for this conversation, rather than waiting for the first
    // outgoing message to trigger `omemo_dart`'s own fetch-on-encrypt
    // logic. Fire-and-forget: failures are logged and retried on the next
    // call/send.
    switch (protocol) {
      case EncryptionProtocol.omemo2:
        unawaited(ensureOmemo2DevicesKnown(bareJid));
      case EncryptionProtocol.legacyOmemo:
        unawaited(ensureLegacyOmemoDevicesKnown(bareJid));
      case EncryptionProtocol.ox:
      case EncryptionProtocol.none:
        break;
    }
    _onUpdate();
  }

  /// Proactively fetches/refreshes [bareJid]'s OMEMO2 device list/bundles
  /// and subscribes to its device-list PEP node, instead of relying on
  /// this happening only as a side effect of actually sending an
  /// encrypted message. See `Omemo2Backend.ensureDevicesKnown`.
  Future<void> ensureOmemo2DevicesKnown(String bareJid) async {
    final backend = await _omemo2Backend();
    await backend.ensureDevicesKnown(bareJid);
  }

  /// Proactively fetches/refreshes [bareJid]'s legacy-OMEMO device
  /// list/bundles and subscribes to its device-list PEP node, instead of
  /// relying on this happening only as a side effect of actually sending
  /// an encrypted message. See `OmemoBackend.ensureDevicesKnown`.
  Future<void> ensureLegacyOmemoDevicesKnown(String bareJid) async {
    final backend = await _legacyOmemoBackend();
    await backend.ensureDevicesKnown(bareJid);
  }

  /// Wipes the locally cached OMEMO2 device list/bundles for [bareJid] and
  /// re-fetches both live from PEP. See `Omemo2Backend.refreshDevices` for
  /// why this is a separate operation from [ensureOmemo2DevicesKnown].
  /// Returns `false` if the live PEP fetch failed (e.g. offline).
  Future<bool> refreshOmemo2Devices(String bareJid) async {
    final backend = await _omemo2Backend();
    return backend.refreshDevices(bareJid);
  }

  /// Wipes the locally cached legacy-OMEMO device list/bundles for
  /// [bareJid] and re-fetches both live from PEP. See
  /// `OmemoBackend.refreshDevices` for details. Returns `false` if the
  /// live PEP fetch failed (e.g. offline).
  Future<bool> refreshLegacyOmemoDevices(String bareJid) async {
    final backend = await _legacyOmemoBackend();
    return backend.refreshDevices(bareJid);
  }

  /// Whether encryption is turned on for [bareJid] (i.e. its selected
  /// protocol is not [EncryptionProtocol.none]).
  bool isEncryptionEnabled(String bareJid) {
    return protocolFor(bareJid) != EncryptionProtocol.none;
  }

  /// Returns the [EncryptionBackend] for [protocol], creating/caching it
  /// lazily on first use. Returns `null` for [EncryptionProtocol.none] or
  /// for protocols that aren't implemented yet.
  Future<EncryptionBackend?> backendFor(EncryptionProtocol protocol) async {
    switch (protocol) {
      case EncryptionProtocol.none:
        return null;
      case EncryptionProtocol.omemo2:
        return _omemo2Backend();
      case EncryptionProtocol.legacyOmemo:
        return _legacyOmemoBackend();
      case EncryptionProtocol.ox:
        return _oxBackend();
    }
  }

  Future<Omemo2Backend> _omemo2Backend() {
    final cached = _backendsByProtocolId['omemo2'];
    if (cached is Omemo2Backend) {
      return Future.value(cached);
    }
    return _omemo2BackendFuture ??= () async {
      final pep = _omemoPep ??= OmemoPep(connection);
      final backend = await Omemo2Backend.create(
        selfBareJid: selfBareJid,
        storage: storage,
        pep: pep,
      );
      _backendsByProtocolId['omemo2'] = backend;
      _publishIdentitySafely(backend, 'omemo2');
      return backend;
    }();
  }

  Future<OmemoBackend> _legacyOmemoBackend() {
    final cached = _backendsByProtocolId['omemo'];
    if (cached is OmemoBackend) {
      return Future.value(cached);
    }
    return _legacyOmemoBackendFuture ??= () async {
      final pep = _omemoPep ??= OmemoPep(connection);
      final backend = await OmemoBackend.create(
        selfBareJid: selfBareJid,
        storage: storage,
        pep: pep,
      );
      _backendsByProtocolId['omemo'] = backend;
      _publishIdentitySafely(backend, 'omemo');
      return backend;
    }();
  }

  Future<OxBackend> _oxBackend() {
    final cached = _backendsByProtocolId['ox'];
    if (cached is OxBackend) {
      return Future.value(cached);
    }
    return _oxBackendFuture ??= () async {
      final pep = _oxPep ??= OxPep(connection);
      final backend = await OxBackend.create(
        selfBareJid: selfBareJid,
        storage: storage,
        pep: pep,
      );
      _backendsByProtocolId['ox'] = backend;
      _publishIdentitySafely(backend, 'ox');
      return backend;
    }();
  }

  /// Publishes [backend]'s identity (device-list/bundle or public key) via
  /// PEP right after it's created.
  ///
  /// Previously nothing in production code ever called
  /// [EncryptionBackend.publishIdentity]: it was only exercised from unit
  /// tests. In practice this meant our own OMEMO/OMEMO2 device-list and
  /// bundle were never (re-)announced, so contacts kept a stale device id
  /// from whatever one-off publish (if any) happened to occur -- e.g. a
  /// device id persisted before an app reinstall/local-storage reset, or
  /// after `_loadOrGenerateDevice`/`Omemo2Backend`'s equivalent silently
  /// generated a brand-new device because none was found in storage. Real
  /// clients (Conversations/Gajim/Dino) then kept encrypting to that old,
  /// unpublished device id forever, which `omemo_dart` correctly rejects
  /// with `NotEncryptedForDeviceError` since it doesn't match our actual
  /// current device id.
  ///
  /// Fired-and-forgotten (not awaited by callers) so a slow/failed PEP
  /// publish never blocks encrypting/decrypting a message; failures are
  /// just logged; the next backend use (or reconnect) will retry since
  /// publishing is cheap and idempotent.
  void _publishIdentitySafely(EncryptionBackend backend, String protocolId) {
    unawaited(
      backend.publishIdentity().catchError((Object error) {
        Log.w(
          'EncryptionManager',
          'Failed to publish identity for $protocolId: $error',
        );
      }),
    );
  }

  /// Proactively creates (if not already created) the OMEMO2 and
  /// legacy-OMEMO backends right after connecting, so our own device
  /// list/bundle get published to PEP immediately -- see the doc comment
  /// on [_publishIdentitySafely].
  ///
  /// Without this, backend creation (and therefore [publishIdentity]) was
  /// purely reactive: it only happened once the user explicitly selected
  /// an encryption protocol for a given conversation, or sent/received an
  /// encrypted message in one. If Wimsy's user never did that from this
  /// device for a particular account (e.g. only ever *received* OMEMO
  /// messages, or never selected encryption at all), our own device-list
  /// and key bundle were simply never published, even though we're
  /// perfectly able to *read* contacts' device lists -- matching the
  /// observed asymmetry ("Conversations cannot see any OMEMO devices for
  /// Wimsy" despite Wimsy seeing Conversations' devices fine).
  ///
  /// OX is intentionally not included here: unlike OMEMO's device-list
  /// discovery model (where *any* contact needs to be able to find our
  /// device to start a session), OX's public-key announcement is only
  /// useful once the user has actually generated/selected an OpenPGP key
  /// for a conversation, so eagerly creating it on every connect would
  /// just add unnecessary PEP traffic.
  void publishAllIdentities() {
    unawaited(_omemo2Backend());
    unawaited(_legacyOmemoBackend());
  }

  /// Encrypts [plaintext] for sending to [toBareJid] using [toBareJid]'s
  /// currently selected protocol. Returns `null` when encryption is off
  /// for that conversation (callers should then send plaintext as usual).
  Future<EncryptedPayload?> encryptForSend(
    String toBareJid,
    String plaintext,
  ) async {
    final protocol = protocolFor(toBareJid);
    final backend = await backendFor(protocol);
    if (backend == null) {
      return null;
    }
    return backend.encryptForSend(toBareJid, plaintext);
  }

  /// Attempts to decrypt an incoming [stanza] using [fromBareJid]'s
  /// currently selected protocol. Returns `null` if encryption is off for
  /// that conversation; otherwise always returns a [DecryptResult] (which
  /// may carry a non-null [DecryptResult.error] on failure).
  Future<DecryptResult?> decryptIncoming(
    String fromBareJid,
    XmppElement stanza,
  ) async {
    final protocol = protocolFor(fromBareJid);
    final backend = await backendFor(protocol);
    if (backend == null) {
      return null;
    }
    return backend.decryptIncoming(stanza);
  }

  /// Convenience used by the incoming-stanza pipeline: returns the matching
  /// backend for whichever protocol namespace the stanza's top-level
  /// `<encrypted/>` child element declares, regardless of the selected
  /// protocol for the conversation (e.g. so a message can still be
  /// decrypted even if the local selection has since changed).
  Future<DecryptResult?> decryptIncomingByNamespace(XmppElement stanza) async {
    final encrypted = stanza.getChild('encrypted');
    final xmlns = encrypted?.getAttribute('xmlns')?.value;
    if (xmlns == omemo2Namespace) {
      final backend = await _omemo2Backend();
      return backend.decryptIncoming(stanza);
    }
    if (xmlns == legacyOmemoNamespace) {
      final backend = await _legacyOmemoBackend();
      return backend.decryptIncoming(stanza);
    }
    // OX (XEP-0373/0374) uses a differently-named/-shaped top-level
    // <openpgp/> element rather than <encrypted/>, so it is detected
    // separately here.
    final openpgp = stanza.getChild('openpgp');
    if (openpgp?.getAttribute('xmlns')?.value == oxNamespace) {
      final backend = await _oxBackend();
      return backend.decryptIncoming(stanza);
    }
    return null;
  }

  /// Aggregate trust state for the currently selected protocol's backend
  /// for [bareJid] (e.g. for a chat-header trust indicator), or `null`
  /// when encryption is off for that conversation. See
  /// `lib/widgets/fingerprint_verification_screen.dart`.
  Future<TrustState?> trustSummaryFor(String bareJid) async {
    final backend = await backendFor(protocolFor(bareJid));
    if (backend == null) {
      return null;
    }
    return backend.trustStateFor(bareJid);
  }

  /// Every known OMEMO2 device (and its fingerprint/trust state) of
  /// [bareJid], for the fingerprint verification screen. Always uses the
  /// OMEMO2 backend regardless of the currently selected protocol, since
  /// the user may want to verify fingerprints before turning encryption
  /// on for a conversation.
  Future<List<Omemo2DeviceFingerprint>> omemo2FingerprintsFor(
    String bareJid,
  ) async {
    final backend = await _omemo2Backend();
    // Make sure we've actually tried to discover this contact's devices
    // before reading what's cached -- otherwise a contact we've never
    // sent an encrypted message to always shows up with zero devices.
    await backend.ensureDevicesKnown(bareJid);
    return backend.deviceFingerprintsFor(bareJid);
  }

  /// Our own OMEMO2 device's fingerprint, for display (e.g. as a QR code)
  /// so a contact can visually compare it against their own view of us.
  Future<String> omemo2OwnFingerprint() async {
    final backend = await _omemo2Backend();
    return backend.ownFingerprint();
  }

  /// Our own OMEMO2 device id, paired with [omemo2OwnFingerprint] to build
  /// a proper `xmpp:<jid>?omemo-sid-<id>=<fingerprint>` QR code.
  Future<int> omemo2OwnDeviceId() async {
    final backend = await _omemo2Backend();
    return backend.ownDeviceId();
  }

  /// Marks [deviceId] of [bareJid] as [TrustState.verified] via the OMEMO2
  /// backend, e.g. after the user confirms a fingerprint match. See
  /// `lib/widgets/fingerprint_verification_screen.dart`.
  Future<void> setOmemo2DeviceTrust(
    String bareJid,
    int deviceId,
    TrustState state,
  ) async {
    final backend = await _omemo2Backend();
    await backend.setTrust(bareJid, '$deviceId', state);
  }

  /// Every known legacy-OMEMO (XEP-0384 v0.3.0,
  /// `eu.siacs.conversations.axolotl`) device (and its fingerprint/trust
  /// state) of [bareJid], for the fingerprint verification screen. This is
  /// a distinct identity key from OMEMO2's -- the two protocols never
  /// share a fingerprint, so a contact only using legacy OMEMO (e.g.
  /// Conversations/Gajim/Dino) must be verified against *this* fingerprint,
  /// not the OMEMO2 one.
  Future<List<Omemo2DeviceFingerprint>> legacyOmemoFingerprintsFor(
    String bareJid,
  ) async {
    final backend = await _legacyOmemoBackend();
    // Make sure we've actually tried to discover this contact's devices
    // before reading what's cached -- otherwise a contact we've never
    // sent an encrypted message to always shows up with zero devices.
    await backend.ensureDevicesKnown(bareJid);
    return backend.deviceFingerprintsFor(bareJid);
  }

  /// Our own legacy-OMEMO device's fingerprint, for display (e.g. as a QR
  /// code) so a contact can visually compare it against their own view of
  /// us. Distinct from [omemo2OwnFingerprint].
  Future<String> legacyOmemoOwnFingerprint() async {
    final backend = await _legacyOmemoBackend();
    return backend.ownFingerprint();
  }

  /// Our own legacy-OMEMO device id, paired with [legacyOmemoOwnFingerprint]
  /// to build a proper `xmpp:<jid>?omemo-sid-<id>=<fingerprint>` QR code.
  Future<int> legacyOmemoOwnDeviceId() async {
    final backend = await _legacyOmemoBackend();
    return backend.ownDeviceId();
  }

  /// Marks [deviceId] of [bareJid] as [TrustState.verified] via the
  /// legacy-OMEMO backend, e.g. after the user confirms a fingerprint
  /// match. See `lib/widgets/fingerprint_verification_screen.dart`.
  Future<void> setLegacyOmemoDeviceTrust(
    String bareJid,
    int deviceId,
    TrustState state,
  ) async {
    final backend = await _legacyOmemoBackend();
    await backend.setTrust(bareJid, '$deviceId', state);
  }

  /// Every known OX key fingerprint (and its trust state) of [bareJid], for
  /// the fingerprint verification screen. Always uses the OX backend
  /// regardless of the currently selected protocol.
  Future<List<OxKeyFingerprint>> oxFingerprintsFor(String bareJid) async {
    final backend = await _oxBackend();
    return backend.keyFingerprintsFor(bareJid);
  }

  /// Our own OX key's fingerprint, for display.
  Future<String> oxOwnFingerprint() async {
    final backend = await _oxBackend();
    return backend.ownFingerprint;
  }

  /// Marks [fingerprint] of [bareJid] as [state] via the OX backend, e.g.
  /// after the user confirms a fingerprint match. See
  /// `lib/widgets/fingerprint_verification_screen.dart`.
  Future<void> setOxKeyTrust(
    String bareJid,
    String fingerprint,
    TrustState state,
  ) async {
    final backend = await _oxBackend();
    await backend.setTrust(bareJid, fingerprint, state);
  }

  /// Exports our own OMEMO2 long-term identity key as a PEM-style block,
  /// for the user to copy somewhere safe (e.g. a password manager). See
  /// `Omemo2Backend.exportIdentityKey`.
  Future<String> exportOmemo2IdentityKey() async {
    final backend = await _omemo2Backend();
    return backend.exportIdentityKey();
  }

  /// Exports our own legacy-OMEMO long-term identity key as a PEM-style
  /// block, for the user to copy somewhere safe (e.g. a password manager).
  /// See `OmemoBackend.exportIdentityKey`.
  Future<String> exportLegacyOmemoIdentityKey() async {
    final backend = await _legacyOmemoBackend();
    return backend.exportIdentityKey();
  }

  /// Replaces our own OMEMO2 identity with one built from a previously
  /// exported identity key [pem] (see [exportOmemo2IdentityKey]), so a
  /// restored device keeps the same fingerprint as before. Drops any
  /// already-created [Omemo2Backend] instance so the next use rebuilds it
  /// from the newly-stored identity. Throws a [FormatException] if [pem]
  /// isn't a valid OMEMO2 identity key export.
  Future<void> importOmemo2IdentityKey(String pem) async {
    final ik = identityKeyPairFromPem(pem, 'OMEMO2');
    final device = await deviceFromIdentityKeyExport(selfBareJid, ik);
    await storage.storeOmemo2Identity(
      selfBareJid,
      await omemoDeviceToJson(device),
    );
    _backendsByProtocolId.remove('omemo2');
    _omemo2BackendFuture = null;
  }

  /// Replaces our own legacy-OMEMO identity with one built from a
  /// previously exported identity key [pem] (see
  /// [exportLegacyOmemoIdentityKey]). Mirrors [importOmemo2IdentityKey].
  /// Throws a [FormatException] if [pem] isn't a valid legacy OMEMO
  /// identity key export.
  Future<void> importLegacyOmemoIdentityKey(String pem) async {
    final ik = identityKeyPairFromPem(pem, 'OMEMO');
    final device = await deviceFromIdentityKeyExport(selfBareJid, ik);
    await storage.storeOmemoIdentity(
      selfBareJid,
      await omemoDeviceToJson(device),
    );
    _backendsByProtocolId.remove('omemo');
    _legacyOmemoBackendFuture = null;
  }
}
