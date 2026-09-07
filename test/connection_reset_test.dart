import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:universal_io/io.dart';
import 'package:wimsy/background/service_lifecycle.dart';
import 'package:wimsy/xmpp/dns_cache.dart';
import 'package:wimsy/xmpp/srv_cache.dart';
import 'package:wimsy/xmpp/srv_lookup.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SRV reset discards native answers from the old network', () async {
    final pending = Completer<List<Map<String, Object>>>();
    const channel = MethodChannel('wimsy/dns');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) => pending.future);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      resetSrvCache();
    });
    final discovery = resolveAllSrvCandidates('example.com', includeQuic: true);
    await Future<void>.delayed(Duration.zero);
    resetSrvCache();
    pending.complete([
      {'host': 'old.example.com', 'port': 5222, 'priority': 0, 'weight': 0},
    ]);
    final result = await discovery;
    expect(result.quic, isEmpty);
    expect(result.tcp, isEmpty);
    expect(srvCache.getFresh('_xmpp-client._tcp.example.com'), isNull);
  });

  test(
    'exhausted connection restarts service and Stop cancels recovery',
    () async {
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      final service = XmppService();
      service.applyKeepaliveTuning(
        service.keepaliveTuning.copyWith(
          connectRetryDelay: const Duration(milliseconds: 20),
        ),
      );
      final secondStart = Completer<void>();
      final releaseStart = Completer<void>();
      var starts = 0;
      var stops = 0;
      service.startBackgroundService = () async {
        starts++;
        if (starts == 2) {
          secondStart.complete();
          await releaseStart.future;
        }
      };
      service.stopBackgroundService = () async {
        stops++;
      };
      final connecting = service.connect(
        jid: 'alice@example.com',
        password: 'secret',
        resource: 'test',
        host: '127.0.0.1',
        port: port,
        useQuic: false,
      );
      await secondStart.future.timeout(const Duration(seconds: 5));
      expect(stops, 1);
      await service.disconnect();
      releaseStart.complete();
      await connecting;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(starts, 2);
      expect(stops, 2);
      expect(service.status, XmppStatus.disconnected);
      service.dispose();
    },
  );

  test('service operations remain ordered across a failure', () async {
    final lifecycle = ServiceLifecycle();
    final starting = Completer<void>();
    final events = <String>[];
    final start = lifecycle.run(() async {
      events.add('start');
      await starting.future;
      throw StateError('platform start failed');
    });
    final failure = expectLater(start, throwsStateError);
    final stop = lifecycle.run(() async => events.add('stop'));
    final restart = lifecycle.run(() async => events.add('restart'));
    await Future<void>.delayed(Duration.zero);
    expect(events, ['start']);
    starting.complete();
    await failure;
    await stop;
    await restart;
    expect(events, ['start', 'stop', 'restart']);
  });

  test(
    'reset rejects late DNS results instead of refilling the cache',
    () async {
      final result = Completer<List<InternetAddress>>();
      final cache = DnsCache();
      final lookup = resolveHostCachedWith(
        'example.com',
        (host, {type = InternetAddressType.any}) => result.future,
        cache: cache,
      );
      final rejected = expectLater(lookup, throwsStateError);
      cache.clear();
      result.complete([InternetAddress('10.0.0.1')]);
      await rejected;
      expect(cache.getFresh('example.com'), isNull);
    },
  );

  test(
    'Stop during service startup cancels login and clears DNS state',
    () async {
      final service = XmppService();
      final starting = Completer<void>();
      final enteredStart = Completer<void>();
      var stops = 0;
      service.startBackgroundService = () {
        enteredStart.complete();
        return starting.future;
      };
      service.stopBackgroundService = () async {
        stops++;
      };
      dnsCache.store('example.com', [InternetAddress('10.0.0.1')]);
      srvCache.store('example.com', [], const Duration(minutes: 5));
      final connecting = service.connect(
        jid: 'alice@example.com',
        password: 'secret',
        resource: 'test',
        host: '127.0.0.1',
        port: 5222,
      );
      await enteredStart.future;
      await service.disconnect();
      starting.complete();
      await connecting;
      expect(stops, 1);
      expect(service.status, XmppStatus.disconnected);
      expect(dnsCache.getFresh('example.com'), isNull);
      expect(srvCache.getFresh('example.com'), isNull);
      service.dispose();
    },
  );

  test(
    'concurrent stops share teardown; next login waits before validation',
    () async {
      final service = XmppService();
      final stopped = Completer<void>();
      var stops = 0;
      var starts = 0;
      service.stopBackgroundService = () {
        stops++;
        return stopped.future;
      };
      service.startBackgroundService = () async {
        starts++;
      };
      final firstStop = service.disconnect();
      final secondStop = service.disconnect();
      final connecting = service.connect(
        jid: 'invalid',
        password: '',
        resource: 'test',
        port: 5222,
      );
      await Future<void>.delayed(Duration.zero);
      expect(stops, 1);
      expect(starts, 0);
      stopped.complete();
      await Future.wait([firstStop, secondStop, connecting]);
      expect(starts, 0);
      expect(service.errorMessage, contains('JID'));
      service.dispose();
    },
  );
}
