import 'dart:async';

import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';

// Minimal fake socket — does nothing, just satisfies the interface.
class _FakeSocket extends Stream<String> implements XmppWebSocket {
  @override
  Future<XmppWebSocket> connect<S>(
    String host,
    int port, {
    String Function(String event)? map,
    List<String>? wsProtocols,
    String? wsPath,
    Uri? wsUri,
    bool useWebSocket = false,
    bool useQuic = false,
    bool directTls = false,
    String? tlsHost,
  }) async => this;

  @override
  void write(Object? message) {}

  @override
  void close() {}
  @override
  Future<dynamic> getQuicStats() => Future.value(null);

  @override
  bool get isQuic => false;

  @override
  Future<SecureSocket?> secure({
    host,
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    List<String>? supportedProtocols,
  }) async => null;

  @override
  String getStreamOpeningElement(String domain) => '<stream:stream to="$domain">';

  @override
  StreamSubscription<String> listen(
    void Function(String event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      const Stream<String>.empty().listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
}

Connection _newConnection() {
  final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
    ..bufferedWritesEnabled = false;
  final connection = Connection.getInstance(account);
  connection.socket = _FakeSocket();
  return connection;
}

void main() {
  tearDown(() {
    for (final connection in Connection.instances.values.toList()) {
      connection.dispose();
      Connection.removeInstance(connection.account);
    }
  });

  group('makeStreamResponseMapper — independence', () {
    test('two mappers maintain separate buffers', () {
      final connection = _newConnection();
      final mapperA = connection.makeStreamResponseMapper();
      final mapperB = connection.makeStreamResponseMapper();

      // Feed an incomplete stanza to A only.
      const partial = '<message to="a@example.com">';
      expect(mapperA(partial), isEmpty,
          reason: 'incomplete XML should be buffered, not returned');

      // B has not received anything — it should still return empty for its own
      // partial chunk, not be contaminated by A's buffer.
      expect(mapperB('<presence'), isEmpty,
          reason: "B's buffer must be independent of A's");
    });

    test('completing A does not affect B', () {
      final connection = _newConnection();
      final mapperA = connection.makeStreamResponseMapper();
      final mapperB = connection.makeStreamResponseMapper();

      // Feed a complete stanza to A.
      const stanza = '<message to="a@example.com" id="1"/>';
      final resultA = mapperA(stanza);
      expect(resultA, isNotEmpty, reason: 'complete stanza should be returned');

      // B should still have an empty buffer — feeding it the same stanza
      // should also succeed independently.
      final resultB = mapperB(stanza);
      expect(resultB, isNotEmpty,
          reason: 'B should process its own stanza independently');
    });

    test('partial chunk in A is not visible to B', () {
      final connection = _newConnection();
      final mapperA = connection.makeStreamResponseMapper();
      final mapperB = connection.makeStreamResponseMapper();

      // A receives first half of a stanza.
      mapperA('<iq id="1" type="get"><ping xmlns="urn:xmpp:ping"');

      // B receives a complete, different stanza — should succeed without
      // being confused by A's buffered partial data.
      final resultB = mapperB('<presence/>');
      expect(resultB, isNotEmpty,
          reason: 'B must not be affected by A buffering a partial stanza');
    });
  });

  group('makeStreamResponseMapper — buffering behaviour', () {
    test('returns empty string for incomplete XML', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      expect(mapper('<message to="x@y.com"'), isEmpty);
    });

    test('accumulates partial chunks and returns result when complete', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      // Split a complete stanza across two chunks.
      expect(mapper('<message to="x@y.com" id="m1"'), isEmpty,
          reason: 'first half is incomplete');
      final result = mapper('/>');
      expect(result, isNotEmpty, reason: 'second half completes the stanza');
      expect(result, contains('message'));
    });

    test('buffer is cleared after a complete stanza', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      // Complete stanza.
      mapper('<presence/>');

      // A subsequent complete stanza should also succeed (buffer was cleared).
      final result = mapper('<presence type="unavailable"/>');
      expect(result, isNotEmpty,
          reason: 'mapper should work correctly after buffer was cleared');
    });

    test('wraps output in xmpp_stone root element', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      final result = mapper('<presence/>');
      expect(result, startsWith('<xmpp_stone>'));
      expect(result, endsWith('</xmpp_stone>'));
    });

    test('handles stream:stream opener by appending synthetic close tag', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      // A stream:stream opener without a matching close is valid mid-session.
      const opener =
          "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' to='example.com'>";
      final result = mapper(opener);
      // The mapper should not return empty — it appends </stream:stream> to
      // make the fragment parseable.
      expect(result, isNotEmpty,
          reason: 'stream opener should be returned after synthetic close');
    });

    test('multiple complete stanzas in one chunk are all returned', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      const chunk = '<presence/><presence type="unavailable"/>';
      final result = mapper(chunk);
      expect(result, isNotEmpty);
      expect(result, contains('unavailable'));
    });
  });

  group('makeStreamResponseMapper — stream close', () {
    test('returns empty string when </stream:stream> is received', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      final result = mapper('</stream:stream>');
      expect(result, isEmpty,
          reason: 'stream close should not produce output');
    });
  });

  group('makeStreamResponseMapper — burst with trailing partial (regression)', () {
    // This is the core bug: under high latency a burst of complete stanzas
    // arrives followed by a partial fragment. The old implementation would
    // hold back ALL complete stanzas until the partial was completed, causing
    // stanza starvation. The new implementation must emit the complete stanzas
    // immediately and only buffer the trailing partial.

    test('emits complete stanzas even when followed by a partial fragment', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      // Two complete stanzas followed by an incomplete one — all in one chunk.
      const chunk =
          '<presence/>'
          '<presence type="unavailable"/>'
          '<message to="x@y.com" id="m1"'; // incomplete — no closing >
      final result = mapper(chunk);
      expect(result, isNotEmpty,
          reason: 'complete stanzas must be emitted despite trailing partial');
      expect(result, contains('unavailable'),
          reason: 'both complete stanzas must be present in output');
    });

    test('trailing partial is buffered and completed on next chunk', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      // First chunk: two complete stanzas + start of a third.
      const chunk1 =
          '<presence/>'
          '<iq id="ping" type="get"/>'
          '<message to="x@y.com" id="m1"';
      final result1 = mapper(chunk1);
      expect(result1, isNotEmpty,
          reason: 'complete stanzas in chunk1 must be emitted immediately');
      expect(result1, contains('ping'));

      // Second chunk: completes the partial message stanza.
      final result2 = mapper('/>');
      expect(result2, isNotEmpty,
          reason: 'completing the partial stanza must produce output');
      expect(result2, contains('message'));
    });

    test('prepareStreamResponse also emits complete stanzas before partial', () {
      final connection = _newConnection();

      const chunk =
          '<presence/>'
          '<iq id="q1" type="result"/>'
          '<message to="a@b.com"'; // incomplete
      final result = connection.prepareStreamResponse(chunk);
      expect(result, isNotEmpty,
          reason: 'prepareStreamResponse must not hold back complete stanzas');
      expect(result, contains('q1'));
    });

    test('many complete stanzas followed by partial — all complete ones emitted', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      // Simulate a MUC presence flood: 10 complete presence stanzas + partial.
      final buffer = StringBuffer();
      for (var i = 0; i < 10; i++) {
        buffer.write('<presence from="room@conf.example.com/user$i"/>');
      }
      buffer.write('<presence from="room@conf.example.com/user10"'); // partial

      final result = mapper(buffer.toString());
      expect(result, isNotEmpty,
          reason: 'all 10 complete presence stanzas must be emitted');
      // All 10 complete ones should be present.
      for (var i = 0; i < 10; i++) {
        expect(result, contains('user$i'));
      }
      // The partial one must NOT be in the output yet.
      expect(result, isNot(contains('user10')));
    });
  });

  group('makeStreamResponseMapper vs prepareStreamResponse — parity', () {
    test('both produce the same output for a complete stanza', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      const stanza = '<message to="a@b.com" id="1"/>';
      final fromMapper = mapper(stanza);
      final fromPrepare = connection.prepareStreamResponse(stanza);

      // Both should be non-empty and contain the stanza.
      expect(fromMapper, isNotEmpty);
      expect(fromPrepare, isNotEmpty);
      expect(fromMapper, contains('message'));
      expect(fromPrepare, contains('message'));
    });

    test('both buffer incomplete XML and return empty', () {
      final connection = _newConnection();
      final mapper = connection.makeStreamResponseMapper();

      const partial = '<iq id="1" type="get">';
      expect(mapper(partial), isEmpty);
      expect(connection.prepareStreamResponse(partial), isEmpty);
    });
  });
}
