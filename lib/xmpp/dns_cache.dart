import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// A single cached hostname resolution result.
class _DnsCacheEntry {
  _DnsCacheEntry({required this.addresses, required this.expiresAt});

  final List<InternetAddress> addresses;
  final DateTime expiresAt;

  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

/// A TTL-aware in-memory cache for hostname (A/AAAA) DNS results.
///
/// Fresh entries (within TTL) are returned immediately. Stale entries are
/// returned as a fallback when a live lookup fails, so that a transient DNS
/// outage (e.g. after the machine wakes from sleep) does not prevent
/// reconnection when the addresses are unlikely to have changed.
class DnsCache {
  DnsCache({Duration? ttl, Duration? maxStaleness})
    : _ttl = ttl ?? const Duration(minutes: 5),
      _maxStaleness = maxStaleness ?? const Duration(hours: 1);

  /// Default TTL applied to every successful lookup result.
  final Duration _ttl;

  /// How long after expiry a stale entry may still be used as a fallback.
  final Duration _maxStaleness;

  final Map<String, _DnsCacheEntry> _entries = {};

  /// Store [addresses] for [host].
  void store(String host, List<InternetAddress> addresses) {
    _entries[host] = _DnsCacheEntry(
      addresses: List.unmodifiable(addresses),
      expiresAt: DateTime.now().add(_ttl),
    );
  }

  /// Return fresh cached addresses for [host], or `null` if none / expired.
  List<InternetAddress>? getFresh(String host) {
    final entry = _entries[host];
    if (entry == null || !entry.isFresh) return null;
    return entry.addresses;
  }

  /// Return stale cached addresses for [host] if within [_maxStaleness],
  /// or `null` if no usable stale entry exists.
  List<InternetAddress>? getStale(String host) {
    final entry = _entries[host];
    if (entry == null) return null;
    if (entry.isFresh) return null;
    final staleSince = DateTime.now().difference(entry.expiresAt);
    if (staleSince > _maxStaleness) return null;
    return entry.addresses;
  }

  /// Remove all entries from the cache.
  void clear() => _entries.clear();

  /// Remove the entry for [host] from the cache.
  void evict(String host) => _entries.remove(host);
}

/// The process-wide hostname DNS cache shared by all lookups.
final dnsCache = DnsCache();

/// Signature for a hostname-to-address lookup function.
typedef HostLookupFn =
    Future<List<InternetAddress>> Function(
      String host, {
      InternetAddressType type,
    });

/// How many times to retry a failed hostname lookup before giving up.
const _dnsRetryCount = 3;

/// Delay between hostname lookup retry attempts.
const _dnsRetryDelay = Duration(seconds: 2);

/// Resolves [host] to a list of [InternetAddress] values, with caching and
/// automatic retries on failure.
///
/// Fresh cached results are returned immediately without a network round-trip.
/// On a successful live lookup the result is stored in [dnsCache].
/// If the live lookup fails (e.g. DNS is temporarily unavailable after the
/// machine wakes from sleep), the lookup is retried up to [_dnsRetryCount]
/// times with a short delay between attempts. If all retries fail, stale
/// cached records are returned as a last resort before throwing.
///
/// The [type] parameter is forwarded to [InternetAddress.lookup] unchanged.
Future<List<InternetAddress>> resolveHostCached(
  String host, {
  InternetAddressType type = InternetAddressType.any,
}) => resolveHostCachedWith(host, _defaultLookup, type: type);

Future<List<InternetAddress>> _defaultLookup(
  String host, {
  InternetAddressType type = InternetAddressType.any,
}) => InternetAddress.lookup(host, type: type);

/// Testable core of [resolveHostCached] with injectable [lookup], [cache],
/// [retryCount], and [retryDelay].
///
/// Production code should call [resolveHostCached] instead.
Future<List<InternetAddress>> resolveHostCachedWith(
  String host,
  HostLookupFn lookup, {
  InternetAddressType type = InternetAddressType.any,
  DnsCache? cache,
  int retryCount = _dnsRetryCount,
  Duration retryDelay = _dnsRetryDelay,
}) async {
  final unwrappedHost = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  final literalAddress = InternetAddress.tryParse(unwrappedHost);
  if (literalAddress != null) {
    debugPrint('DNS lookup: using literal address $host directly');
    return <InternetAddress>[literalAddress];
  }
  final effectiveCache = cache ?? dnsCache;

  // Return fresh cached result immediately.
  final fresh = effectiveCache.getFresh(host);
  if (fresh != null) {
    debugPrint('DNS cache: fresh hit for $host (${fresh.length} address(es))');
    return fresh;
  }

  Object? lastError;
  for (var attempt = 1; attempt <= retryCount; attempt++) {
    try {
      debugPrint('DNS lookup: host=$host attempt=$attempt/$retryCount');
      final addresses = await lookup(host, type: type);
      if (addresses.isNotEmpty) {
        effectiveCache.store(host, addresses);
        debugPrint(
          'DNS lookup: host=$host resolved ${addresses.length} address(es) '
          'on attempt $attempt',
        );
        return addresses;
      }
      // Empty result — treat as a soft failure and retry.
      lastError = const SocketException('DNS lookup returned no addresses');
    } catch (e) {
      lastError = e;
      debugPrint('DNS lookup: host=$host attempt=$attempt failed: $e');
    }

    if (attempt < retryCount) {
      await Future<void>.delayed(retryDelay);
    }
  }

  // All live attempts failed — try stale cache as fallback.
  final stale = effectiveCache.getStale(host);
  if (stale != null && stale.isNotEmpty) {
    debugPrint(
      'DNS cache: all live lookups failed for $host, '
      'using stale records (${stale.length} address(es))',
    );
    return stale;
  }

  throw lastError ?? SocketException('DNS lookup failed for $host');
}
