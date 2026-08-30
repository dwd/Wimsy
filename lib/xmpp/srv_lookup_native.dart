import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'srv_cache.dart';
import 'srv_ordering.dart';
import 'srv_target.dart';

/// How many times to retry a failed SRV lookup before falling back to cache.
const _srvRetryCount = 3;

/// Delay between SRV lookup retry attempts.
const _srvRetryDelay = Duration(seconds: 2);
final Map<String, Timer> _srvRefreshTimers = <String, Timer>{};

const MethodChannel _channel = MethodChannel('wimsy/dns');

Future<XmppSrvTarget?> resolveXmppSrv(String domain) async {
  final candidates = await resolveXmppSrvCandidates(domain);
  if (candidates.isEmpty) {
    return null;
  }
  return candidates.first;
}

/// Resolves all TCP SRV candidates for [domain] (both Direct-TLS and
/// StartTLS), running the two DNS queries concurrently.
///
/// Results are cached by DNS TTL. On timeout or failure the cache is
/// consulted for stale records before returning an empty list.
Future<List<XmppSrvTarget>> resolveXmppSrvCandidates(String domain) async {
  debugPrint('SRV lookup: domain=$domain');

  // Run _xmpps-client._tcp (Direct TLS) and _xmpp-client._tcp concurrently.
  final results = await Future.wait([
    _lookupSrv('_xmpps-client._tcp.$domain', directTls: true),
    _lookupSrv('_xmpp-client._tcp.$domain', directTls: false),
  ]);

  final records = [...results[0], ...results[1]];
  if (records.isEmpty) {
    debugPrint('SRV lookup: no records found');
    return const [];
  }
  final ordered = orderXmppSrvTargets(records);
  final selected = ordered.first;
  final orderSummary = ordered
      .map(
        (r) =>
            '${r.host}:${r.port}/p${r.priority}/w${r.weight}/tls=${r.directTls}',
      )
      .join(', ');
  debugPrint('SRV lookup: ordered candidates=[$orderSummary]');
  debugPrint(
    'SRV lookup: selected host=${selected.host} port=${selected.port} '
    'priority=${selected.priority} weight=${selected.weight} '
    'directTls=${selected.directTls}',
  );
  return ordered;
}

/// Resolves all three SRV record sets (QUIC, Direct-TLS TCP, StartTLS TCP)
/// for [domain] concurrently and returns them as a named record.
///
/// This is the preferred entry point when the caller needs all three sets at
/// once, because it issues all DNS queries in parallel.
Future<({List<XmppSrvTarget> quic, List<XmppSrvTarget> tcp})>
resolveAllSrvCandidates(String domain, {required bool includeQuic}) async {
  debugPrint('SRV parallel lookup: domain=$domain includeQuic=$includeQuic');

  if (includeQuic) {
    // All three queries in parallel.
    final results = await Future.wait([
      _lookupSrv('_xmpp-client._quic.$domain', directTls: false),
      _lookupSrv('_xmpps-client._tcp.$domain', directTls: true),
      _lookupSrv('_xmpp-client._tcp.$domain', directTls: false),
    ]);
    final quicRecords = results[0];
    final tcpRecords = [...results[1], ...results[2]];
    return (
      quic: quicRecords.isEmpty
          ? const <XmppSrvTarget>[]
          : orderXmppSrvTargets(quicRecords),
      tcp: tcpRecords.isEmpty
          ? const <XmppSrvTarget>[]
          : orderXmppSrvTargets(tcpRecords),
    );
  } else {
    // Only TCP queries in parallel.
    final results = await Future.wait([
      _lookupSrv('_xmpps-client._tcp.$domain', directTls: true),
      _lookupSrv('_xmpp-client._tcp.$domain', directTls: false),
    ]);
    final tcpRecords = [...results[0], ...results[1]];
    return (
      quic: const <XmppSrvTarget>[],
      tcp: tcpRecords.isEmpty
          ? const <XmppSrvTarget>[]
          : orderXmppSrvTargets(tcpRecords),
    );
  }
}

Future<List<XmppSrvTarget>> resolveXmppQuicSrvCandidates(String domain) async {
  debugPrint('QUIC SRV lookup: domain=$domain');
  final records = await _lookupSrv(
    '_xmpp-client._quic.$domain',
    directTls: false,
  );
  if (records.isEmpty) {
    debugPrint('QUIC SRV lookup: no records found');
    return const [];
  }
  final ordered = orderXmppSrvTargets(records);
  final orderSummary = ordered
      .map(
        (record) =>
            '${record.host}:${record.port}/p${record.priority}/w${record.weight}',
      )
      .join(', ');
  debugPrint('QUIC SRV lookup: ordered candidates=[$orderSummary]');
  return ordered;
}

/// Looks up SRV records for [name], using the cache when possible.
///
/// On a successful live lookup the results are stored in [srvCache] with the
/// TTL returned by DNS. If the live lookup fails or times out, the lookup is
/// retried up to [_srvRetryCount] times with a short delay between attempts
/// (to handle transient DNS unavailability after the machine wakes from sleep).
/// If all retries fail, stale cached records are returned as a last resort.
Future<List<XmppSrvTarget>> _lookupSrv(
  String name, {
  required bool directTls,
  bool forceRefresh = false,
}) async {
  // Return fresh cached records immediately.
  final fresh = forceRefresh ? null : srvCache.getFresh(name);
  if (fresh != null) {
    debugPrint('SRV cache: fresh hit for $name (${fresh.length} records)');
    return fresh;
  }

  Future<List<XmppSrvTarget>> liveLookup() async {
    List<XmppSrvTarget> results = const [];
    for (var attempt = 1; attempt <= _srvRetryCount; attempt++) {
      var timedOut = false;
      try {
        final native = await _lookupSrvNative(name);
        if (native.isNotEmpty) {
          results = native
              .map(
                (entry) => XmppSrvTarget(
                  host: entry.host,
                  port: entry.port,
                  priority: entry.priority,
                  weight: entry.weight,
                  directTls: directTls,
                ),
              )
              .toList();
          // Native resolver doesn't expose TTL; use a conservative default.
          srvCache.store(name, results, const Duration(minutes: 5));
          _scheduleSrvRefresh(name, directTls);
          return results;
        }
        results = await _lookupSrvUdp(name, directTls: directTls);
      } on TimeoutException {
        timedOut = true;
        results = const [];
      } catch (_) {
        results = const [];
      }

      if (results.isNotEmpty) {
        _scheduleSrvRefresh(name, directTls);
        return results;
      }

      debugPrint(
        'SRV lookup: attempt $attempt/$_srvRetryCount failed for $name'
        '${timedOut ? ' (timeout)' : ''}',
      );
      if (attempt < _srvRetryCount) {
        await Future<void>.delayed(_srvRetryDelay);
      }
    }
    return const [];
  }

  final stale = srvCache.getStale(name);
  if (stale != null && stale.isNotEmpty) {
    final refresh = liveLookup();
    try {
      final freshResult = await refresh.timeout(const Duration(seconds: 1));
      if (freshResult.isNotEmpty) return freshResult;
    } on TimeoutException {
      unawaited(refresh);
    }
    debugPrint(
      'SRV cache: using stale records for $name (${stale.length} records) '
      'while refresh continues',
    );
    return stale;
  }
  return liveLookup();
}

void _scheduleSrvRefresh(String name, bool directTls) {
  _srvRefreshTimers.remove(name)?.cancel();
  _srvRefreshTimers[name] = Timer(const Duration(minutes: 4), () {
    _srvRefreshTimers.remove(name);
    unawaited(_lookupSrv(name, directTls: directTls, forceRefresh: true));
  });
}

class _NativeSrvRecord {
  _NativeSrvRecord({
    required this.host,
    required this.port,
    required this.priority,
    required this.weight,
  });

  final String host;
  final int port;
  final int priority;
  final int weight;
}

Future<List<_NativeSrvRecord>> _lookupSrvNative(String name) async {
  debugPrint('SRV native: query=$name');
  try {
    final result = await _channel.invokeMethod<List<dynamic>>(
      'resolveSrv',
      <String, dynamic>{'name': name},
    );
    if (result == null) {
      debugPrint('SRV native: empty result');
      return const [];
    }
    final records = <_NativeSrvRecord>[];
    for (final entry in result) {
      if (entry is! Map) {
        continue;
      }
      final host = entry['host']?.toString() ?? '';
      final port = _toInt(entry['port']);
      final priority = _toInt(entry['priority']);
      final weight = _toInt(entry['weight']);
      if (host.isEmpty || port == null || priority == null || weight == null) {
        continue;
      }
      records.add(
        _NativeSrvRecord(
          host: host,
          port: port,
          priority: priority,
          weight: weight,
        ),
      );
    }
    debugPrint('SRV native: records=${records.length}');
    return records;
  } on PlatformException {
    debugPrint('SRV native: PlatformException');
    return const [];
  } catch (_) {
    debugPrint('SRV native: error');
    return const [];
  }
}

int? _toInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

Future<List<XmppSrvTarget>> _lookupSrvUdp(
  String name, {
  required bool directTls,
}) async {
  debugPrint('SRV udp: query=$name');
  final resolvers = await _systemResolvers();
  if (resolvers.isEmpty) {
    debugPrint('SRV udp: no resolvers found');
    return const [];
  }
  final records = <XmppSrvTarget>[];
  int? minTtl;
  for (final resolver in resolvers) {
    debugPrint('SRV udp: resolver=$resolver');
    final response = await _querySrv(name, resolver);
    if (response.isEmpty) {
      continue;
    }
    for (final record in response) {
      records.add(
        XmppSrvTarget(
          host: record.target,
          port: record.port,
          priority: record.priority,
          weight: record.weight,
          directTls: directTls,
        ),
      );
      if (minTtl == null || record.ttl < minTtl) {
        minTtl = record.ttl;
      }
    }
    if (records.isNotEmpty) {
      break;
    }
  }
  debugPrint('SRV udp: records=${records.length} minTtl=$minTtl');
  if (records.isNotEmpty) {
    final ttl = Duration(seconds: minTtl ?? 300);
    srvCache.store(name, records, ttl);
  }
  return records;
}

Future<List<InternetAddress>> _systemResolvers() async {
  if (!Platform.isLinux && !Platform.isMacOS && !Platform.isAndroid) {
    return const [];
  }
  final file = File('/etc/resolv.conf');
  if (!await file.exists()) {
    return const [];
  }
  final lines = await file.readAsLines();
  final servers = <InternetAddress>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('nameserver')) {
      continue;
    }
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      continue;
    }
    final addr = parts[1];
    try {
      servers.add(InternetAddress(addr));
    } catch (_) {
      continue;
    }
  }
  return servers;
}

class _SrvRecord {
  _SrvRecord({
    required this.priority,
    required this.weight,
    required this.port,
    required this.target,
    required this.ttl,
  });

  final int priority;
  final int weight;
  final int port;
  final String target;

  /// Time-to-live in seconds as returned by the DNS response.
  final int ttl;
}

Future<List<_SrvRecord>> _querySrv(String name, InternetAddress server) async {
  final socket = await RawDatagramSocket.bind(
    server.type == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4,
    0,
  );
  try {
    socket.readEventsEnabled = true;
    final queryId = Random().nextInt(0xffff);
    final packet = _buildSrvQuery(name, queryId);
    socket.send(packet, server, 53);
    final completer = Completer<Datagram?>();
    late final StreamSubscription sub;
    sub = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = socket.receive();
        if (datagram == null) {
          return;
        }
        if (datagram.data.length < 2) {
          return;
        }
        final responseId = (datagram.data[0] << 8) | datagram.data[1];
        if (responseId == queryId && !completer.isCompleted) {
          completer.complete(datagram);
        }
      }
    });
    final datagram = await completer.future.timeout(
      const Duration(seconds: 4),
      onTimeout: () {
        return null;
      },
    );
    await sub.cancel();
    if (datagram == null) {
      return const [];
    }
    return _parseSrvResponse(datagram.data);
  } catch (_) {
    return const [];
  } finally {
    socket.close();
  }
}

Uint8List _buildSrvQuery(String name, int id) {
  final builder = BytesBuilder();
  builder.addByte((id >> 8) & 0xff);
  builder.addByte(id & 0xff);
  builder.add([0x01, 0x00]);
  builder.add([0x00, 0x01]);
  builder.add([0x00, 0x00]);
  builder.add([0x00, 0x00]);
  builder.add([0x00, 0x00]);
  builder.add(_encodeName(name));
  builder.add([0x00, 0x21]);
  builder.add([0x00, 0x01]);
  return builder.toBytes();
}

Uint8List _encodeName(String name) {
  final builder = BytesBuilder();
  final labels = name.split('.');
  for (final label in labels) {
    final bytes = label.codeUnits;
    builder.addByte(bytes.length);
    builder.add(bytes);
  }
  builder.addByte(0);
  return builder.toBytes();
}

List<_SrvRecord> _parseSrvResponse(Uint8List data) {
  if (data.length < 12) {
    return const [];
  }
  final qdCount = (data[4] << 8) | data[5];
  final anCount = (data[6] << 8) | data[7];
  var offset = 12;
  for (var i = 0; i < qdCount; i++) {
    offset = _skipName(data, offset);
    if (offset + 4 > data.length) {
      return const [];
    }
    offset += 4;
  }
  final records = <_SrvRecord>[];
  for (var i = 0; i < anCount; i++) {
    offset = _skipName(data, offset);
    if (offset + 10 > data.length) {
      return records;
    }
    final type = (data[offset] << 8) | data[offset + 1];
    offset += 2; // type
    offset += 2; // class
    // Extract the 32-bit TTL field (seconds).
    final ttl =
        (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4; // ttl
    final rdLength = (data[offset] << 8) | data[offset + 1];
    offset += 2;
    if (offset + rdLength > data.length) {
      return records;
    }
    if (type == 33 && rdLength >= 7) {
      final priority = (data[offset] << 8) | data[offset + 1];
      final weight = (data[offset + 2] << 8) | data[offset + 3];
      final port = (data[offset + 4] << 8) | data[offset + 5];
      final decoded = _readName(data, offset + 6);
      if (decoded.name.isNotEmpty) {
        final target = decoded.name.endsWith('.')
            ? decoded.name.substring(0, decoded.name.length - 1)
            : decoded.name;
        records.add(
          _SrvRecord(
            priority: priority,
            weight: weight,
            port: port,
            target: target,
            ttl: ttl,
          ),
        );
      }
    }
    offset += rdLength;
  }
  return records;
}

int _skipName(Uint8List data, int offset) {
  var current = offset;
  while (current < data.length) {
    final length = data[current];
    if (length == 0) {
      return current + 1;
    }
    if ((length & 0xC0) == 0xC0) {
      return current + 2;
    }
    current += length + 1;
  }
  return data.length;
}

class _NameDecode {
  _NameDecode(this.name, this.nextOffset);

  final String name;
  final int nextOffset;
}

_NameDecode _readName(Uint8List data, int offset) {
  final labels = <String>[];
  var current = offset;
  var jumped = false;
  var jumpOffset = 0;
  while (current < data.length) {
    final length = data[current];
    if (length == 0) {
      current += 1;
      break;
    }
    if ((length & 0xC0) == 0xC0) {
      final pointer = ((length & 0x3F) << 8) | data[current + 1];
      if (!jumped) {
        jumpOffset = current + 2;
      }
      current = pointer;
      jumped = true;
      continue;
    }
    final end = current + 1 + length;
    if (end > data.length) {
      break;
    }
    labels.add(String.fromCharCodes(data.sublist(current + 1, end)));
    current = end;
  }
  final name = labels.join('.');
  final nextOffset = jumped ? jumpOffset : current;
  return _NameDecode(name, nextOffset);
}
