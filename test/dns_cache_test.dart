import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/dns_cache.dart';

InternetAddress _addr(String ip) => InternetAddress(ip);

void main() {
  test('literal IPv4 and IPv6 addresses bypass hostname lookup', () async {
    var lookupCount = 0;
    Future<List<InternetAddress>> lookup(
      String host, {
      InternetAddressType type = InternetAddressType.any,
    }) async {
      lookupCount++;
      return <InternetAddress>[];
    }

    final ipv4 = await resolveHostCachedWith('192.0.2.10', lookup);
    final ipv6 = await resolveHostCachedWith('[2001:db8::10]', lookup);

    expect(ipv4.single.address, '192.0.2.10');
    expect(ipv6.single.address, '2001:db8::10');
    expect(lookupCount, 0);
  });

  group('DnsCache', () {
    late DnsCache cache;

    setUp(() {
      cache = DnsCache();
    });

    test('returns null when cache is empty', () {
      expect(cache.getFresh('example.com'), isNull);
      expect(cache.getStale('example.com'), isNull);
    });

    test('getFresh returns stored addresses within TTL', () {
      final addrs = [_addr('1.2.3.4')];
      cache.store('example.com', addrs);

      final fresh = cache.getFresh('example.com');
      expect(fresh, isNotNull);
      expect(fresh!.length, 1);
      expect(fresh.first.address, '1.2.3.4');
    });

    test('getFresh returns null for unknown host', () {
      cache.store('example.com', [_addr('1.2.3.4')]);
      expect(cache.getFresh('other.com'), isNull);
    });

    test('getStale returns null for a fresh entry', () {
      cache.store('example.com', [_addr('1.2.3.4')]);
      expect(cache.getStale('example.com'), isNull);
    });

    test('evict removes the entry', () {
      cache.store('example.com', [_addr('1.2.3.4')]);
      cache.evict('example.com');
      expect(cache.getFresh('example.com'), isNull);
    });

    test('clear removes all entries', () {
      cache.store('a.example.com', [_addr('1.2.3.4')]);
      cache.store('b.example.com', [_addr('5.6.7.8')]);
      cache.clear();
      expect(cache.getFresh('a.example.com'), isNull);
      expect(cache.getFresh('b.example.com'), isNull);
    });

    test('overwriting an entry replaces the previous addresses', () {
      cache.store('example.com', [_addr('1.2.3.4')]);
      cache.store('example.com', [_addr('9.9.9.9')]);
      expect(cache.getFresh('example.com')!.first.address, '9.9.9.9');
    });

    test('stores multiple independent hosts', () {
      cache.store('a.example.com', [_addr('1.1.1.1')]);
      cache.store('b.example.com', [_addr('2.2.2.2')]);
      expect(cache.getFresh('a.example.com')!.first.address, '1.1.1.1');
      expect(cache.getFresh('b.example.com')!.first.address, '2.2.2.2');
    });

    test('getStale returns null when maxStaleness is zero', () {
      final strictCache = DnsCache(
        ttl: const Duration(minutes: 5),
        maxStaleness: Duration.zero,
      );
      strictCache.store('example.com', [_addr('1.2.3.4')]);
      // Entry is still fresh, so getStale returns null regardless.
      expect(strictCache.getStale('example.com'), isNull);
    });
  });

  group('resolveHostCached', () {
    setUp(() {
      // Clear the global cache before each test so tests are independent.
      dnsCache.clear();
    });

    test(
      'returns cached result on second call without invoking lookup again',
      () async {
        var lookupCount = 0;
        final fakeAddresses = [_addr('10.0.0.1')];

        Future<List<InternetAddress>> fakeLookup(
          String host, {
          InternetAddressType type = InternetAddressType.any,
        }) async {
          lookupCount++;
          return fakeAddresses;
        }

        // First call — populates cache.
        final result1 = await resolveHostCachedWith('example.com', fakeLookup);
        expect(result1.first.address, '10.0.0.1');
        expect(lookupCount, 1);

        // Second call — should hit cache, not call lookup again.
        final result2 = await resolveHostCachedWith('example.com', fakeLookup);
        expect(result2.first.address, '10.0.0.1');
        expect(lookupCount, 1);
      },
    );

    test('retries on failure and succeeds on second attempt', () async {
      var callCount = 0;

      Future<List<InternetAddress>> fakeLookup(
        String host, {
        InternetAddressType type = InternetAddressType.any,
      }) async {
        callCount++;
        if (callCount < 2) {
          throw const SocketException('DNS temporarily unavailable');
        }
        return [_addr('10.0.0.2')];
      }

      final result = await resolveHostCachedWith(
        'example.com',
        fakeLookup,
        retryDelay: Duration.zero,
      );
      expect(result.first.address, '10.0.0.2');
      expect(callCount, 2);
    });

    test('returns stale cache after all retries fail', () async {
      // Pre-populate the cache with a stale entry by using a custom DnsCache.
      final testCache = DnsCache(
        ttl: const Duration(milliseconds: 1),
        maxStaleness: const Duration(hours: 1),
      );
      testCache.store('example.com', [_addr('10.0.0.3')]);
      // Wait for the TTL to expire.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      Future<List<InternetAddress>> failingLookup(
        String host, {
        InternetAddressType type = InternetAddressType.any,
      }) async {
        throw const SocketException('DNS unavailable');
      }

      final result = await resolveHostCachedWith(
        'example.com',
        failingLookup,
        cache: testCache,
        retryDelay: Duration.zero,
      );
      expect(result.first.address, '10.0.0.3');
    });

    test('throws when all retries fail and no stale cache exists', () async {
      Future<List<InternetAddress>> failingLookup(
        String host, {
        InternetAddressType type = InternetAddressType.any,
      }) async {
        throw const SocketException('DNS unavailable');
      }

      expect(
        () => resolveHostCachedWith(
          'example.com',
          failingLookup,
          retryDelay: Duration.zero,
        ),
        throwsA(isA<SocketException>()),
      );
    });

    test('retries on empty result and succeeds on later attempt', () async {
      var callCount = 0;

      Future<List<InternetAddress>> fakeLookup(
        String host, {
        InternetAddressType type = InternetAddressType.any,
      }) async {
        callCount++;
        if (callCount < 3) {
          return const []; // empty — treated as soft failure
        }
        return [_addr('10.0.0.4')];
      }

      final result = await resolveHostCachedWith(
        'example.com',
        fakeLookup,
        retryDelay: Duration.zero,
      );
      expect(result.first.address, '10.0.0.4');
      expect(callCount, 3);
    });
  });
}
