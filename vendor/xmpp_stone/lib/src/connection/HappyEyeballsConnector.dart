import 'dart:async';

import 'package:universal_io/io.dart';

typedef HostLookup = Future<List<InternetAddress>> Function(
  String host, {
  InternetAddressType type,
});

typedef TcpAddressConnect = Future<Socket> Function(
  InternetAddress host,
  int port, {
  Duration? timeout,
});

class HappyEyeballsConnector {
  HappyEyeballsConnector({
    required HostLookup hostLookup,
    required TcpAddressConnect tcpConnect,
    this.fallbackDelay = const Duration(milliseconds: 250),
    this.connectTimeout = const Duration(seconds: 5),
  })  : _hostLookup = hostLookup,
        _tcpConnect = tcpConnect;

  final HostLookup _hostLookup;
  final TcpAddressConnect _tcpConnect;
  final Duration fallbackDelay;
  final Duration connectTimeout;

  Future<Socket> connect(String host, int port) async {
    final unwrappedHost = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    final literalAddress = InternetAddress.tryParse(unwrappedHost);
    final addresses = literalAddress == null
        ? await _hostLookup(host)
        : <InternetAddress>[literalAddress];
    if (addresses.isEmpty) {
      throw const SocketException('Host lookup returned no addresses');
    }
    final candidates = _interleaveByFamily(addresses);
    final completer = Completer<Socket>();
    final timers = <Timer>[];
    final errors = <Object>[];
    var completed = false;
    var launched = 0;
    var finished = 0;

    void maybeCompleteError() {
      if (completed) {
        return;
      }
      if (launched < candidates.length || finished < candidates.length) {
        return;
      }
      completed = true;
      final lastError = errors.isNotEmpty
          ? errors.last
          : const SocketException('Connect failed');
      completer.completeError(lastError);
    }

    void launch(InternetAddress address) {
      if (completed) {
        return;
      }
      launched += 1;
      Future.sync(() => _tcpConnect(address, port, timeout: connectTimeout))
          .then((socket) {
        if (completed) {
          socket.close();
          return;
        }
        completed = true;
        completer.complete(socket);
      }).catchError((error) {
        errors.add(error);
      }).whenComplete(() {
        finished += 1;
        maybeCompleteError();
      });
    }

    for (var i = 0; i < candidates.length; i++) {
      final delay = Duration(milliseconds: fallbackDelay.inMilliseconds * i);
      final timer = Timer(delay, () => launch(candidates[i]));
      timers.add(timer);
    }

    try {
      return await completer.future;
    } finally {
      for (final timer in timers) {
        timer.cancel();
      }
    }
  }
}

List<InternetAddress> _interleaveByFamily(List<InternetAddress> addresses) {
  final ipv6 = <InternetAddress>[];
  final ipv4 = <InternetAddress>[];
  for (final address in addresses) {
    if (address.type == InternetAddressType.IPv6) {
      ipv6.add(address);
    } else if (address.type == InternetAddressType.IPv4) {
      ipv4.add(address);
    }
  }
  if (ipv4.isEmpty || ipv6.isEmpty) {
    return addresses;
  }
  final preferV6First = addresses.first.type == InternetAddressType.IPv6;
  final first = preferV6First ? ipv6 : ipv4;
  final second = preferV6First ? ipv4 : ipv6;
  final interleaved = <InternetAddress>[];
  final maxLen = first.length > second.length ? first.length : second.length;
  for (var i = 0; i < maxLen; i++) {
    if (i < first.length) {
      interleaved.add(first[i]);
    }
    if (i < second.length) {
      interleaved.add(second[i]);
    }
  }
  return interleaved;
}
