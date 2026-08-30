import 'dart:async';

import 'package:flutter_quic/flutter_quic.dart'
    show
        QuicConnectionStats,
        QuicConnection,
        QuicEndpoint,
        QuicFrameStats,
        QuicPathStats,
        QuicUdpStats;
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/quic_xmpp_socket.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Minimal fake [QuicEndpoint] that satisfies the [RustOpaqueInterface]
/// contract without touching any real FFI.
class _FakeEndpoint implements QuicEndpoint {
  @override
  void dispose() {}

  @override
  bool get isDisposed => false;
}

class _FakeConnection implements QuicConnection {
  @override
  void dispose() {}

  @override
  bool get isDisposed => false;
}

/// Testable subclass of [QuicCapableXmppSocket] that returns a controlled
/// sequence of stats from [getQuicStats] without touching real FFI.
class _TestableSocket extends QuicCapableXmppSocket {
  _TestableSocket({
    required List<QuicConnectionStats?> statsSequence,
    required super.migrationProbeTimeout,
    required super.migrationProbeInterval,
  }) : _statsSequence = List.of(statsSequence);

  final List<QuicConnectionStats?> _statsSequence;
  int _statsCallCount = 0;

  @override
  Future<QuicConnectionStats?> getQuicStats() async {
    if (_statsCallCount < _statsSequence.length) {
      return _statsSequence[_statsCallCount++];
    }
    return _statsSequence.isEmpty ? null : _statsSequence.last;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds migration-relevant connection statistics; all other counters are
/// zero.
QuicConnectionStats makeStats(int pathChallengeRx, {int udpDatagramsRx = 0}) {
  final zero = BigInt.zero;
  final zeroFrame = QuicFrameStats(
    acks: zero,
    crypto: zero,
    connectionClose: zero,
    dataBlocked: zero,
    datagram: zero,
    handshakeDone: zero,
    maxData: zero,
    maxStreamData: zero,
    maxStreamsBidi: zero,
    maxStreamsUni: zero,
    newConnectionId: zero,
    newToken: zero,
    pathChallenge: BigInt.from(pathChallengeRx),
    pathResponse: zero,
    ping: zero,
    resetStream: zero,
    retireConnectionId: zero,
    stream: zero,
    streamDataBlocked: zero,
    streamsBlockedBidi: zero,
    streamsBlockedUni: zero,
    stopSending: zero,
  );
  final zeroPath = QuicPathStats(
    rttMillis: zero,
    cwnd: zero,
    bytesInFlight: zero,
    ackElicitingPacketsInFlight: zero,
    lostPackets: zero,
    lostBytes: zero,
    sentPackets: zero,
    congestionEvents: zero,
  );
  final zeroUdp = QuicUdpStats(datagrams: zero, bytes: zero, ios: zero);
  final rxUdp = QuicUdpStats(
    datagrams: BigInt.from(udpDatagramsRx),
    bytes: zero,
    ios: zero,
  );
  return QuicConnectionStats(
    path: zeroPath,
    frameTx: zeroFrame,
    frameRx: zeroFrame,
    udpTx: zeroUdp,
    udpRx: rxUdp,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  final fakeEndpoint = _FakeEndpoint();
  final fakeConnection = _FakeConnection();

  /// Builds a socket with QUIC active, a fake endpoint, and a no-op rebind.
  _TestableSocket makeQuicSocket({
    required List<QuicConnectionStats?> statsSequence,
    Duration timeout = const Duration(milliseconds: 50),
  }) {
    final socket = _TestableSocket(
      statsSequence: statsSequence,
      migrationProbeTimeout: timeout,
      migrationProbeInterval: const Duration(milliseconds: 10),
    );
    socket.useQuicForTesting = true;
    socket.endpointForTesting = fakeEndpoint;
    socket.connectionForTesting = fakeConnection;
    socket.rebindOverride = (_) async {};
    socket.migrationPingOverride = (_) async {};
    return socket;
  }

  group('attemptMigration()', () {
    test('returns failed immediately when _useQuic is false', () async {
      final socket = _TestableSocket(
        statsSequence: const [],
        migrationProbeTimeout: const Duration(milliseconds: 50),
        migrationProbeInterval: const Duration(milliseconds: 10),
      );
      // _useQuic defaults to false; no endpoint set.
      final result = await socket.attemptMigration();
      expect(result, MigrationResult.failed);
    });

    test('returns failed immediately when endpoint is null', () async {
      final socket = _TestableSocket(
        statsSequence: const [],
        migrationProbeTimeout: const Duration(milliseconds: 50),
        migrationProbeInterval: const Duration(milliseconds: 10),
      );
      socket.useQuicForTesting = true;
      // endpoint left null — rebindOverride won't be reached
      socket.connectionForTesting = fakeConnection;
      socket.rebindOverride = (_) async {};
      final result = await socket.attemptMigration();
      expect(result, MigrationResult.failed);
    });

    test('returns success when path_challenge RX counter increments', () async {
      // Baseline read returns counter = 0; first poll returns counter = 1.
      final socket = makeQuicSocket(
        statsSequence: [
          makeStats(0), // baseline
          makeStats(1), // first poll — incremented
        ],
        timeout: const Duration(milliseconds: 500),
      );
      final result = await socket.attemptMigration();
      expect(result, MigrationResult.success);
    });

    test(
      'returns success when the rebound socket receives a datagram',
      () async {
        final socket = makeQuicSocket(
          statsSequence: [
            makeStats(0, udpDatagramsRx: 10),
            makeStats(0, udpDatagramsRx: 11),
          ],
          timeout: const Duration(milliseconds: 500),
        );

        final result = await socket.attemptMigration();

        expect(result, MigrationResult.success);
      },
    );

    test('returns failed when counter never changes (timeout)', () async {
      final socket = makeQuicSocket(
        statsSequence: List.filled(20, makeStats(5)),
        timeout: const Duration(milliseconds: 50),
      );
      final result = await socket.attemptMigration();
      expect(result, MigrationResult.failed);
    });

    test('returns failed when rebind throws', () async {
      final socket = _TestableSocket(
        statsSequence: [makeStats(0)],
        migrationProbeTimeout: const Duration(milliseconds: 50),
        migrationProbeInterval: const Duration(milliseconds: 10),
      );
      socket.useQuicForTesting = true;
      socket.endpointForTesting = fakeEndpoint;
      socket.connectionForTesting = fakeConnection;
      socket.rebindOverride = (_) async => throw Exception('rebind error');
      final result = await socket.attemptMigration();
      expect(result, MigrationResult.failed);
    });

    test('coalesces overlapping migration attempts into one rebind', () async {
      final socket = makeQuicSocket(
        statsSequence: [makeStats(0), makeStats(1)],
        timeout: const Duration(milliseconds: 500),
      );
      final rebindStarted = Completer<void>();
      final allowRebind = Completer<void>();
      var rebindCount = 0;
      socket.rebindOverride = (_) async {
        rebindCount++;
        rebindStarted.complete();
        await allowRebind.future;
      };

      final first = socket.attemptMigration();
      await rebindStarted.future;
      final second = socket.attemptMigration();
      allowRebind.complete();

      expect(await first, MigrationResult.success);
      expect(await second, MigrationResult.success);
      expect(rebindCount, 1);
    });

    test('repeats migration probes until the slow path responds', () async {
      final socket = makeQuicSocket(
        statsSequence: [
          makeStats(0, udpDatagramsRx: 10),
          makeStats(0, udpDatagramsRx: 10),
          makeStats(0, udpDatagramsRx: 10),
          makeStats(0, udpDatagramsRx: 11),
        ],
        timeout: const Duration(seconds: 1),
      );
      var probeCount = 0;
      socket.migrationPingOverride = (_) async => probeCount++;

      final result = await socket.attemptMigration();

      expect(result, MigrationResult.success);
      expect(probeCount, greaterThan(1));
    });
  });

  group('MigrationResult enum', () {
    test('success is distinct from failed', () {
      expect(MigrationResult.success, isNot(MigrationResult.failed));
    });

    test('has exactly two values', () {
      expect(MigrationResult.values.length, 2);
    });
  });
}
