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
