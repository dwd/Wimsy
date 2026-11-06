import 'package:xmpp_stone/xmpp_stone.dart';

import '../storage/storage_service.dart';
import '../xmpp/omemo_pep.dart' hide omemo2Namespace;
import 'encryption_backend.dart';
import 'omemo2_backend.dart';

typedef EncryptionUpdateCallback = void Function();

/// Identifies which end-to-end-encryption protocol (if any) is selected
/// for a given 1:1 conversation.
///
/// Only [none] and [omemo2] are implemented so far (Step 2 of the E2EE
/// plan). [legacyOmemo] and [ox] are reserved here so a later step can
/// introduce them without requiring call sites that already switch over
/// this enum to be revisited/broken.
enum EncryptionProtocol {
  /// No end-to-end encryption; messages are sent/received in plaintext.
  none,

  /// `urn:xmpp:omemo:2` (XEP-0384 "OMEMO2").
  omemo2,

  /// Legacy OMEMO (`eu.siacs.conversations.axolotl`). Not yet implemented;
  /// reserved for a later plan step.
  legacyOmemo,

  /// OpenPGP for XMPP (XEP-0373/XEP-0374, "OX"). Not yet implemented;
  /// reserved for a later plan step.
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
  Future<Omemo2Backend>? _omemo2BackendFuture;

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
    _onUpdate();
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
      case EncryptionProtocol.ox:
        // Not yet implemented (later plan steps).
        return null;
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
      return backend;
    }();
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
    return null;
  }
}
