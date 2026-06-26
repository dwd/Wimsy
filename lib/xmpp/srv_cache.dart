import 'srv_target.dart';

/// A single cached SRV result for one DNS name.
class _SrvCacheEntry {
  _SrvCacheEntry({
    required this.records,
    required this.expiresAt,
  });

  /// The ordered list of SRV targets returned by the last successful lookup.
  final List<XmppSrvTarget> records;

  /// Wall-clock time at which the cached records expire (based on DNS TTL).
  final DateTime expiresAt;

  /// Whether the entry is still within its TTL.
  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

/// A TTL-aware in-memory cache for SRV DNS results.
///
/// Fresh entries (within TTL) are returned immediately. Stale entries are
/// returned as a fallback when a live lookup fails or times out, so that a
/// poor network does not cause a complete connection failure.
class SrvCache {
  SrvCache({Duration? maxStaleness})
      : _maxStaleness = maxStaleness ?? const Duration(hours: 1);

  /// How long after expiry a stale entry may still be used as a fallback.
  final Duration _maxStaleness;

  final Map<String, _SrvCacheEntry> _entries = {};

  /// Store [records] for [name] with the given [ttl].
  ///
  /// A [ttl] of zero is treated as a minimum of 30 seconds so that a server
  /// advertising TTL=0 does not thrash the cache on every lookup.
  void store(String name, List<XmppSrvTarget> records, Duration ttl) {
    final effectiveTtl =
        ttl < const Duration(seconds: 30) ? const Duration(seconds: 30) : ttl;
    _entries[name] = _SrvCacheEntry(
      records: List.unmodifiable(records),
      expiresAt: DateTime.now().add(effectiveTtl),
    );
  }

  /// Return fresh cached records for [name], or `null` if none exist / expired.
  List<XmppSrvTarget>? getFresh(String name) {
    final entry = _entries[name];
    if (entry == null || !entry.isFresh) return null;
    return entry.records;
  }

  /// Return stale cached records for [name] if they are within [_maxStaleness]
  /// of their expiry, or `null` if no usable stale entry exists.
  ///
  /// This is used as a fallback when a live DNS lookup fails or times out.
  List<XmppSrvTarget>? getStale(String name) {
    final entry = _entries[name];
    if (entry == null) return null;
    if (entry.isFresh) return null; // fresh, not stale
    final staleSince = DateTime.now().difference(entry.expiresAt);
    if (staleSince > _maxStaleness) return null;
    return entry.records;
  }

  /// Remove all entries from the cache.
  void clear() => _entries.clear();

  /// Remove the entry for [name] from the cache.
  void evict(String name) => _entries.remove(name);
}

/// The process-wide SRV cache shared by all lookups.
final srvCache = SrvCache();
