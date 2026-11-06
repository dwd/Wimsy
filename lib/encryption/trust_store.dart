import '../storage/storage_service.dart';
import 'encryption_backend.dart';

/// Generic, protocol-agnostic trust-state store shared by every
/// [EncryptionBackend] (OMEMO2 today; legacy OMEMO/OX in later plan
/// steps).
///
/// Trust is tracked per `(bareJid, deviceOrKeyId)` pair, not scoped to any
/// particular protocol, so backends for different protocols that happen
/// to identify the same contact device/key (e.g. by fingerprint) can share
/// a single verification decision. An unseen pair defaults to
/// [TrustState.tofu] ("Trust On First Use") the first time it is looked
/// up, and that decision is recorded so subsequent lookups are stable.
///
/// Persisted via [StorageService] (see `storeTrustState`/`loadTrustState`
/// in `lib/storage/storage_service.dart`), with an in-memory cache kept on
/// top so trust-state transitions are immediately visible even if the
/// underlying storage write is a no-op (e.g. in tests using an in-memory
/// fake with no open Hive box).
class TrustStore {
  TrustStore(this.storage);

  final StorageService storage;

  /// In-memory cache keyed by `'bareJid:deviceOrKeyId'`, acting as the
  /// source of truth for the current process; writes are mirrored to
  /// [storage] for persistence across restarts.
  final Map<String, TrustState> _cache = {};

  static String _key(String bareJid, String deviceOrKeyId) =>
      '$bareJid:$deviceOrKeyId';

  /// Returns the current [TrustState] for [deviceOrKeyId] belonging to
  /// [bareJid]. If this pair has never been seen before, it is recorded
  /// (both in-memory and in [storage]) as [TrustState.tofu] and that value
  /// is returned.
  Future<TrustState> trustStateFor(
    String bareJid,
    String deviceOrKeyId,
  ) async {
    final key = _key(bareJid, deviceOrKeyId);
    final cached = _cache[key];
    if (cached != null) {
      return cached;
    }
    final storedName = storage.loadTrustState(bareJid, deviceOrKeyId);
    final stored = storedName == null ? null : _parse(storedName);
    if (stored != null) {
      _cache[key] = stored;
      return stored;
    }
    // Unseen pair: Trust-on-First-Use, recorded so it's stable going
    // forward.
    _cache[key] = TrustState.tofu;
    await storage.storeTrustState(bareJid, deviceOrKeyId, TrustState.tofu.name);
    return TrustState.tofu;
  }

  /// Explicitly sets the trust state for [deviceOrKeyId] belonging to
  /// [bareJid] (e.g. after the user verifies a fingerprint, or revokes a
  /// previously trusted device).
  Future<void> setTrust(
    String bareJid,
    String deviceOrKeyId,
    TrustState state,
  ) async {
    _cache[_key(bareJid, deviceOrKeyId)] = state;
    await storage.storeTrustState(bareJid, deviceOrKeyId, state.name);
  }

  /// Returns every `(deviceOrKeyId, TrustState)` pair currently cached for
  /// [bareJid]. Only reflects pairs already looked up or set via this
  /// [TrustStore] instance during the current process lifetime (there is
  /// no bulk "list all known devices" persisted query, since device
  /// discovery is owned by each [EncryptionBackend]).
  Map<String, TrustState> knownStatesFor(String bareJid) {
    final prefix = '$bareJid:';
    return {
      for (final entry in _cache.entries)
        if (entry.key.startsWith(prefix))
          entry.key.substring(prefix.length): entry.value,
    };
  }

  TrustState? _parse(String name) {
    for (final state in TrustState.values) {
      if (state.name == name) {
        return state;
      }
    }
    return null;
  }
}
