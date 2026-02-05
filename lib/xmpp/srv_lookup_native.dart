import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class XmppSrvTarget {
  XmppSrvTarget({
    required this.host,
    required this.port,
    required this.priority,
    required this.weight,
    required this.directTls,
  });

  final String host;
  final int port;
  final int priority;
  final int weight;
  final bool directTls;
}

const MethodChannel _channel = MethodChannel('zimpy/dns');

Future<XmppSrvTarget?> resolveXmppSrv(String domain) async {
  debugPrint('SRV lookup: domain=$domain');
  final records = <XmppSrvTarget>[];
  records.addAll(await _lookupSrv('_xmpps-client._tcp.$domain', directTls: true));
  records.addAll(await _lookupSrv('_xmpp-client._tcp.$domain', directTls: false));
  if (records.isEmpty) {
    debugPrint('SRV lookup: no records found');
    return null;
  }
  final selected = _pickSrvTarget(records);
  if (selected != null) {
    debugPrint(
      'SRV lookup: selected host=${selected.host} port=${selected.port} '
      'priority=${selected.priority} weight=${selected.weight} directTls=${selected.directTls}',
    );
  }
  return selected;
}

Future<List<XmppSrvTarget>> _lookupSrv(String name, {required bool directTls}) async {
  final native = await _lookupSrvNative(name);
  if (native.isNotEmpty) {
    return native
        .map((entry) => XmppSrvTarget(
              host: entry.host,
              port: entry.port,
              priority: entry.priority,
              weight: entry.weight,
              directTls: directTls,
            ))
        .toList();
  }
  return _lookupSrvUdp(name, directTls: directTls);
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
      records.add(_NativeSrvRecord(
        host: host,
        port: port,
        priority: priority,
        weight: weight,
      ));
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

Future<List<XmppSrvTarget>> _lookupSrvUdp(String name, {required bool directTls}) async {
  debugPrint('SRV udp: query=$name');
  final resolvers = await _systemResolvers();
  if (resolvers.isEmpty) {
    debugPrint('SRV udp: no resolvers found');
    return const [];
  }
  final records = <XmppSrvTarget>[];
  for (final resolver in resolvers) {
    debugPrint('SRV udp: resolver=$resolver');
    final response = await _querySrv(name, resolver);
    if (response.isEmpty) {
      continue;
    }
    for (final record in response) {
      records.add(XmppSrvTarget(
        host: record.target,
        port: record.port,
        priority: record.priority,
        weight: record.weight,
        directTls: directTls,
      ));
    }
    if (records.isNotEmpty) {
      break;
    }
  }
  debugPrint('SRV udp: records=${records.length}');
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
  });

  final int priority;
  final int weight;
  final int port;
  final String target;
}

Future<List<_SrvRecord>> _querySrv(String name, InternetAddress server) async {
  final socket = await RawDatagramSocket.bind(
    server.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
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
    final datagram = await completer.future.timeout(const Duration(seconds: 4), onTimeout: () {
      return null;
    });
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
    offset += 2;
    offset += 2;
    offset += 4;
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
        records.add(_SrvRecord(
          priority: priority,
          weight: weight,
          port: port,
          target: target,
        ));
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

XmppSrvTarget? _pickSrvTarget(List<XmppSrvTarget> records) {
  if (records.isEmpty) {
    return null;
  }
  records.sort((a, b) => a.priority.compareTo(b.priority));
  final bestPriority = records.first.priority;
  final candidates = records.where((record) => record.priority == bestPriority).toList();
  if (candidates.length == 1) {
    return candidates.first;
  }
  final totalWeight = candidates.fold<int>(0, (sum, record) => sum + record.weight);
  if (totalWeight <= 0) {
    return candidates[Random().nextInt(candidates.length)];
  }
  final roll = Random().nextInt(totalWeight);
  var running = 0;
  for (final record in candidates) {
    running += record.weight;
    if (roll < running) {
      return record;
    }
  }
  return candidates.last;
}
