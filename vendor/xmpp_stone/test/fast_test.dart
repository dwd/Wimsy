/// Tests for XEP-0484 FAST (Fast Authentication Streamlining Tokens).
///
/// Covers:
///  - Mechanism name parsing (HT-* and HT2-*).
///  - Mechanism preference selection.
///  - HT-* initial-response payload construction.
///  - HT2-* (HMAC) initial-response payload construction.
///  - Token extraction from SASL2 success elements.
///  - Request-token injection during initial SCRAM authentication.
///  - Token expiry check.
///  - FAST fallback to SCRAM when token is absent/expired.
import 'dart:convert';
import 'dart:async';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/sasl/FastAuthHandler.dart';
import 'package:xmpp_stone/src/features/sasl/Sasl2AuthHandler.dart';
import 'package:xmpp_stone/src/features/sasl/SaslAuthenticationFeature.dart';
import 'package:xmpp_stone/src/features/sasl/SaslMechanism.dart';
import 'package:xml/xml.dart' as xml;

// ---------------------------------------------------------------------------
// In-memory socket that records all writes (mirrors sasl2_test._RecordingSocket).
// ---------------------------------------------------------------------------

class _RecordingSocket extends Stream<String> implements XmppWebSocket {
  final _controller = StreamController<String>.broadcast();
  final writes = <String>[];

  @override
  Future<XmppWebSocket> connect<S>(
    String host,
    int port, {
    String Function(String event)? map,
    List<String>? wsProtocols,
    String? wsPath,
    Uri? wsUri,
    bool useWebSocket = false,
    bool useWebTransport = false,
    bool useQuic = false,
    bool directTls = false,
    String? tlsHost,
  }) async {
    return this;
  }

  @override
  void write(Object? message) => writes.add(message?.toString() ?? '');

  @override
  void close() => _controller.close();

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
  }) async =>
      null;

  @override
  String getStreamOpeningElement(String domain) =>
      "<stream:stream to='$domain'/>";

  @override
  StreamSubscription<String> listen(
    void Function(String event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _controller.stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
}

// ---------------------------------------------------------------------------
// Helpers to build FAST feature elements.
// ---------------------------------------------------------------------------

/// Builds a `<fast xmlns='urn:xmpp:fast:0'>` element listing [mechanisms].
XmppElement buildFastElement(List<String> mechanisms) {
  final fast = XmppElement()
    ..name = 'fast'
    ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:fast:0'));
  for (final m in mechanisms) {
    fast.addChild(XmppElement()
      ..name = 'mechanism'
      ..textValue = m);
  }
  return fast;
}

/// Builds a SASL2 `<authentication>` Nonza offering SCRAM-SHA-256 plus an
/// inline `<fast>` feature with [mechanisms].
Nonza buildSasl2AuthElement(List<String> fastMechanisms) {
  final authentication = Nonza()
    ..name = 'authentication'
    ..addAttribute(
      XmppAttribute('xmlns', SaslAuthenticationFeature.sasl2Namespace),
    );
  authentication.addChild(XmppElement()
    ..name = 'mechanism'
    ..textValue = 'SCRAM-SHA-256');

  final inline = XmppElement()..name = 'inline';
  inline.addChild(buildFastElement(fastMechanisms));
  authentication.addChild(inline);
  return authentication;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  group('FastAuthHandler.fromMechanismName', () {
    Connection buildConnection() =>
        Connection(XmppAccountSettings.fromJid('alice@example.com', 'secret'));

    test('parses HT2-SHA-256-NONE correctly', () {
      final handler = FastAuthHandler.fromMechanismName(
        buildConnection(),
        'HT2-SHA-256-NONE',
        base64.encode(List.filled(32, 0)),
      );
      expect(handler, isNotNull);
    });

    test('parses HT2-SHA-512-NONE correctly', () {
      final handler = FastAuthHandler.fromMechanismName(
        buildConnection(),
        'HT2-SHA-512-NONE',
        base64.encode(List.filled(32, 0)),
      );
      expect(handler, isNotNull);
    });

    test('parses HT-SHA-256-NONE correctly', () {
      final handler = FastAuthHandler.fromMechanismName(
        buildConnection(),
        'HT-SHA-256-NONE',
        base64.encode(List.filled(32, 0)),
      );
      expect(handler, isNotNull);
    });

    test('parses HT-SHA-512-NONE correctly', () {
      final handler = FastAuthHandler.fromMechanismName(
        buildConnection(),
        'HT-SHA-512-NONE',
        base64.encode(List.filled(32, 0)),
      );
      expect(handler, isNotNull);
    });

    test('returns null for unsupported channel-binding (ENDP)', () {
      final handler = FastAuthHandler.fromMechanismName(
        buildConnection(),
        'HT2-SHA-256-ENDP',
        base64.encode(List.filled(32, 0)),
      );
      expect(handler, isNull);
    });

    test('returns null for unsupported hash (SHA-1)', () {
      final handler = FastAuthHandler.fromMechanismName(
        buildConnection(),
        'HT2-SHA-1-NONE',
        base64.encode(List.filled(20, 0)),
      );
      expect(handler, isNull);
    });

    test('returns null for unknown prefix', () {
      final handler = FastAuthHandler.fromMechanismName(
        buildConnection(),
        'SCRAM-SHA-256',
        base64.encode(List.filled(32, 0)),
      );
      expect(handler, isNull);
    });

    test('is case-insensitive for the mechanism name', () {
      final handler = FastAuthHandler.fromMechanismName(
        buildConnection(),
        'ht2-sha-256-none', // lower-case
        base64.encode(List.filled(32, 0)),
      );
      expect(handler, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  group('Sasl2AuthHandler.pickFastMechanism', () {
    test('picks HT2-SHA-256-NONE as first preference', () {
      final fast = buildFastElement([
        'HT-SHA-512-NONE',
        'HT2-SHA-512-NONE',
        'HT2-SHA-256-NONE',
        'HT-SHA-256-NONE',
      ]);
      expect(
        Sasl2AuthHandler.pickFastMechanism(fast),
        equals('HT2-SHA-256-NONE'),
      );
    });

    test('picks HT2-SHA-512-NONE when HT2-SHA-256-NONE is absent', () {
      final fast = buildFastElement([
        'HT2-SHA-512-NONE',
        'HT-SHA-256-NONE',
        'HT-SHA-512-NONE',
      ]);
      expect(
        Sasl2AuthHandler.pickFastMechanism(fast),
        equals('HT2-SHA-512-NONE'),
      );
    });

    test('falls back to HT-SHA-256-NONE when HT2 is absent', () {
      final fast = buildFastElement([
        'HT-SHA-512-NONE',
        'HT-SHA-256-NONE',
      ]);
      expect(
        Sasl2AuthHandler.pickFastMechanism(fast),
        equals('HT-SHA-256-NONE'),
      );
    });

    test('returns null when no supported mechanism is offered', () {
      final fast = buildFastElement(['HT2-SHA-256-ENDP', 'HT-SHA-1-NONE']);
      expect(Sasl2AuthHandler.pickFastMechanism(fast), isNull);
    });

    test('returns null for null input', () {
      expect(Sasl2AuthHandler.pickFastMechanism(null), isNull);
    });

    test('returns null for element with no mechanism children', () {
      final fast = XmppElement()
        ..name = 'fast'
        ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:fast:0'));
      expect(Sasl2AuthHandler.pickFastMechanism(fast), isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('HT-* initial response payload', () {
    /// Decodes the initial-response payload sent by the handler.
    List<int> decodePayload(String base64Value) => base64.decode(base64Value);

    test('HT-SHA-256-NONE: payload is authcid + NUL + HMAC(token)', () async {
      final tokenBytes = List<int>.generate(32, (i) => i);
      final tokenB64 = base64.encode(tokenBytes);

      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true
        ..fastToken = tokenB64
        ..fastMechanism = 'HT-SHA-256-NONE';
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;

      // Set up the inline features so the handler includes them.
      connection.setSasl2InlineFeatures({});

      final handler = FastAuthHandler.fromMechanismName(
        connection,
        'HT-SHA-256-NONE',
        tokenB64,
      )!;
      // start() subscribes to inNonzasStream and sends; we only inspect the
      // written stanza.
      handler.start();
      await Future<void>.delayed(Duration.zero);

      expect(socket.writes, isNotEmpty, reason: 'handler should have written');
      final doc = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(doc);
      expect(auth.name, equals('authenticate'));
      expect(
        auth.getAttribute('mechanism')?.value,
        equals('HT-SHA-256-NONE'),
      );

      final initialResponseB64 =
          auth.getChild('initial-response')?.textValue ?? '';
      expect(initialResponseB64, isNotEmpty);

      final payload = decodePayload(initialResponseB64);
      final authcid = utf8.encode('alice@example.com');
      // HT-*: authcid || NUL || HMAC-<hash>(token, "Initiator").
      final expectedHmac = crypto.Hmac(crypto.sha256, tokenBytes)
          .convert(utf8.encode('Initiator'))
          .bytes;
      final expected = [...authcid, 0x00, ...expectedHmac];
      expect(payload, equals(expected));
    });
  });

  // -------------------------------------------------------------------------
  group('HT2-* initial response payload (HMAC)', () {
    test(
        'HT2-SHA-256-NONE: payload is authcid + NUL + NUL + '
        'HMAC-SHA-256(token, "Initiator")', () async {
      final tokenBytes = List<int>.generate(32, (i) => i);
      final tokenB64 = base64.encode(tokenBytes);

      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true
        ..fastToken = tokenB64
        ..fastMechanism = 'HT2-SHA-256-NONE';
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;
      connection.setSasl2InlineFeatures({});

      final handler = FastAuthHandler.fromMechanismName(
        connection,
        'HT2-SHA-256-NONE',
        tokenB64,
      )!;
      handler.start();
      await Future<void>.delayed(Duration.zero);

      expect(socket.writes, isNotEmpty);
      final doc = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(doc);
      expect(
        auth.getAttribute('mechanism')?.value,
        equals('HT2-SHA-256-NONE'),
      );

      final initialResponseB64 =
          auth.getChild('initial-response')?.textValue ?? '';
      final payload = base64.decode(initialResponseB64);

      // HT2-*: authcid || NUL || NUL (empty extra) || HMAC-SHA-256(token).
      final expectedHmac =
          crypto.Hmac(crypto.sha256, tokenBytes).convert(utf8.encode('Initiator')).bytes;
      final expected = [
        ...utf8.encode('alice@example.com'),
        0x00,
        0x00,
        ...expectedHmac,
      ];
      expect(payload, equals(expected));
    });

    test(
        'HT2-SHA-512-NONE: payload is authcid + NUL + NUL + '
        'HMAC-SHA-512(token, "Initiator")', () async {
      final tokenBytes = List<int>.generate(32, (i) => i + 1);
      final tokenB64 = base64.encode(tokenBytes);

      final account = XmppAccountSettings.fromJid('bob@example.com', 'secret')
        ..fastEnabled = true
        ..fastToken = tokenB64
        ..fastMechanism = 'HT2-SHA-512-NONE';
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;
      connection.setSasl2InlineFeatures({});

      final handler = FastAuthHandler.fromMechanismName(
        connection,
        'HT2-SHA-512-NONE',
        tokenB64,
      )!;
      handler.start();
      await Future<void>.delayed(Duration.zero);

      expect(socket.writes, isNotEmpty);
      final doc = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(doc);
      final initialResponseB64 =
          auth.getChild('initial-response')?.textValue ?? '';
      final payload = base64.decode(initialResponseB64);

      final expectedHmac =
          crypto.Hmac(crypto.sha512, tokenBytes).convert(utf8.encode('Initiator')).bytes;
      final expected = [
        ...utf8.encode('bob@example.com'),
        0x00,
        0x00,
        ...expectedHmac,
      ];
      expect(payload, equals(expected));
    });
  });

  // -------------------------------------------------------------------------
  group('Token extraction from SASL2 success', () {
    test('FAST token is stored after successful FAST authentication', () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true
        ..fastToken = base64.encode(List.filled(32, 1))
        ..fastMechanism = 'HT2-SHA-256-NONE';
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;
      connection.setSasl2InlineFeatures({});

      final tokenBytes = List.filled(32, 2);
      final newToken = base64.encode(tokenBytes);
      final expiry = '2099-01-01T00:00:00Z';

      final handler = FastAuthHandler.fromMechanismName(
        connection,
        'HT2-SHA-256-NONE',
        base64.encode(List.filled(32, 1)),
      )!;
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      // Feed a success response with a new token.
      connection.handleResponse(
        "<xmpp_stone>"
        "<success xmlns='urn:xmpp:sasl:2'>"
        "<authorization-identifier>alice@example.com</authorization-identifier>"
        "<token xmlns='urn:xmpp:fast:0' token='$newToken' expiry='$expiry'/>"
        "</success>"
        "</xmpp_stone>",
      );
      final result = await resultFuture;
      expect(result.successful, isTrue);
      expect(account.fastToken, equals(newToken));
      expect(account.fastTokenExpiry, equals(expiry));
    });

    test('FAST token cleared on authentication failure', () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true
        ..fastToken = base64.encode(List.filled(32, 1))
        ..fastMechanism = 'HT2-SHA-256-NONE';
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;
      connection.setSasl2InlineFeatures({});

      final handler = FastAuthHandler.fromMechanismName(
        connection,
        'HT2-SHA-256-NONE',
        base64.encode(List.filled(32, 1)),
      )!;
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      connection.handleResponse(
        "<xmpp_stone>"
        "<failure xmlns='urn:xmpp:sasl:2'>"
        "<not-authorized/>"
        "</failure>"
        "</xmpp_stone>",
      );
      final result = await resultFuture;
      expect(result.successful, isFalse);
      // Token must be cleared so next reconnection uses SCRAM.
      expect(account.fastToken, isNull);
      expect(account.fastMechanism, isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('Sasl2AuthHandler includes <request-token> when server offers FAST',
      () {
    test('adds <request-token> element to authenticate', () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true;
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;

      // Simulate server offering fast inline with HT2-SHA-256-NONE.
      final fastFeatureEl = buildFastElement(['HT2-SHA-256-NONE', 'HT2-SHA-512-NONE']);
      connection.setSasl2InlineFeatures({
        'urn:xmpp:fast:0': fastFeatureEl,
      });

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      handler.start();
      await Future<void>.delayed(Duration.zero);

      final authXml = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(authXml);
      final requestToken = auth.getChild('request-token');
      expect(requestToken, isNotNull,
          reason: '<request-token> should be present when FAST is offered');
      expect(
        requestToken?.getNameSpace(),
        equals('urn:xmpp:fast:0'),
      );
      // Should prefer HT2-SHA-256-NONE.
      expect(
        requestToken?.getAttribute('mechanism')?.value,
        equals('HT2-SHA-256-NONE'),
      );
    });

    test('does NOT add <request-token> when FAST is disabled', () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = false;
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;

      final fastFeatureEl = buildFastElement(['HT2-SHA-256-NONE']);
      connection.setSasl2InlineFeatures({
        'urn:xmpp:fast:0': fastFeatureEl,
      });

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      handler.start();
      await Future<void>.delayed(Duration.zero);

      final authXml = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(authXml);
      expect(
        auth.getChild('request-token'),
        isNull,
        reason: '<request-token> must be absent when FAST is disabled',
      );
    });

    test('does NOT add <request-token> when server does not offer FAST', () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true;
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;
      // No FAST in inline features.
      connection.setSasl2InlineFeatures({});

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      handler.start();
      await Future<void>.delayed(Duration.zero);

      final authXml = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(authXml);
      expect(auth.getChild('request-token'), isNull);
    });

    test('token stored in account after successful initial auth with FAST token',
        () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true;
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;

      final fastFeatureEl = buildFastElement(['HT2-SHA-256-NONE']);
      connection.setSasl2InlineFeatures({
        'urn:xmpp:fast:0': fastFeatureEl,
      });

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      const newToken = 'dGhlX3Rva2Vu';
      const expiry = '2099-06-01T00:00:00Z';

      // Feed success with a FAST token in the inline success elements.
      connection.handleResponse(
        "<xmpp_stone>"
        "<success xmlns='urn:xmpp:sasl:2'>"
        "<authorization-identifier>alice@example.com</authorization-identifier>"
        "<additional-data>dGVzdA==</additional-data>"
        "<token xmlns='urn:xmpp:fast:0' token='$newToken' expiry='$expiry'/>"
        "</success>"
        "</xmpp_stone>",
      );

      final result = await resultFuture;
      expect(result.successful, isTrue);
      expect(account.fastToken, equals(newToken));
      expect(account.fastTokenExpiry, equals(expiry));
    });
  });

  // -------------------------------------------------------------------------
  group('FAST failure falls back to SCRAM on the same stream', () {
    test('rejected token triggers a password authenticate without closing',
        () async {
      var cleared = false;
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true
        ..fastToken = base64.encode(List.filled(32, 1))
        ..fastMechanism = 'HT2-SHA-256-NONE'
        ..fastTokenExpiry = '2099-01-01T00:00:00Z'
        ..onFastCredentialsChanged = ((updated) {
          cleared = updated.fastToken == null;
        });
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;

      final authElement = buildSasl2AuthElement(['HT2-SHA-256-NONE']);
      final feature = SaslAuthenticationFeature(connection, 'secret');
      feature.negotiate([authElement]);
      await Future<void>.delayed(Duration.zero);

      expect(socket.writes, hasLength(1));
      final firstAuth =
          Nonza.parse(xml.XmlDocument.parse(socket.writes.first).rootElement);
      expect(
        firstAuth.getAttribute('mechanism')?.value,
        equals('HT2-SHA-256-NONE'),
      );

      // The server rejects the stored token.
      connection.handleResponse(
        "<xmpp_stone>"
        "<failure xmlns='urn:xmpp:sasl:2'>"
        "<not-authorized/>"
        "</failure>"
        "</xmpp_stone>",
      );
      await Future<void>.delayed(Duration.zero);

      expect(cleared, isTrue, reason: 'stale token must be forgotten');
      expect(socket.writes.length, greaterThan(1),
          reason: 'a second authenticate should be sent after FAST failed');
      final secondAuth =
          Nonza.parse(xml.XmlDocument.parse(socket.writes.last).rootElement);
      expect(secondAuth.name, equals('authenticate'));
      expect(
        secondAuth.getAttribute('mechanism')?.value,
        equals('SCRAM-SHA-256'),
        reason: 'must fall back to the password mechanism',
      );
      expect(
        connection.state,
        isNot(equals(XmppConnectionState.AuthenticationFailure)),
        reason: 'a FAST failure alone must not fail the connection',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('Token expiry checks', () {
    test('tryCreateFastHandler rejects expired token', () {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true
        ..fastToken = base64.encode(List.filled(32, 1))
        ..fastMechanism = 'HT2-SHA-256-NONE'
        // Expiry in the past.
        ..fastTokenExpiry = '2000-01-01T00:00:00Z';
      final connection = Connection(account);

      final authElement = buildSasl2AuthElement(['HT2-SHA-256-NONE']);
      final inlineFeatures =
          SaslAuthenticationFeature.parseInlineFeatures(authElement);
      connection.setSasl2InlineFeatures(inlineFeatures);

      // A SaslAuthenticationFeature will reject the expired token internally.
      // We indirectly test via checking that the token is cleared.
      //
      // Run negotiate() with enough context to trigger _tryCreateFastHandler.
      // Since negotiate() calls _process() which calls _tryCreateFastHandler(),
      // and the expired token should clear account.fastToken and return null,
      // the SaslAuthenticationFeature will fall through to SCRAM.
      //
      // We can verify by checking that fastToken becomes null after the check.
      final feature = SaslAuthenticationFeature(connection, 'secret');
      feature.negotiate([authElement]);
      // After negotiate(), expired token should be cleared.
      expect(account.fastToken, isNull);
    });

    test('tryCreateFastHandler accepts non-expired token', () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true
        ..fastToken = base64.encode(List.filled(32, 1))
        ..fastMechanism = 'HT2-SHA-256-NONE'
        // Expiry far in the future.
        ..fastTokenExpiry = '2099-01-01T00:00:00Z';
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;

      final authElement = buildSasl2AuthElement(['HT2-SHA-256-NONE']);

      final feature = SaslAuthenticationFeature(connection, 'secret');
      feature.negotiate([authElement]);
      // The FastAuthHandler sends via a buffered write that is flushed
      // asynchronously, so we need to yield before checking.
      await Future<void>.delayed(Duration.zero);
      // The handler should have written the FAST authenticate stanza.
      expect(socket.writes, isNotEmpty,
          reason: 'FAST authenticate should have been sent');
      final doc = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(doc);
      expect(auth.getAttribute('mechanism')?.value, equals('HT2-SHA-256-NONE'));
    });

    test('expired token notifies the persistence callback', () {
      var cleared = false;
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true
        ..fastToken = base64.encode(List.filled(32, 1))
        ..fastMechanism = 'HT2-SHA-256-NONE'
        ..fastTokenExpiry = '2000-01-01T00:00:00Z'
        ..onFastCredentialsChanged = ((updated) {
          cleared = updated.fastToken == null;
        });
      final connection = Connection(account);
      connection.socket = _RecordingSocket();

      final authElement = buildSasl2AuthElement(['HT2-SHA-256-NONE']);
      final feature = SaslAuthenticationFeature(connection, 'secret');
      feature.negotiate([authElement]);

      expect(cleared, isTrue,
          reason: 'expired token must be dropped from persistent storage');
    });

    test('token no longer offered by the server is cleared and reported', () {
      var cleared = false;
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true
        ..fastToken = base64.encode(List.filled(32, 1))
        ..fastMechanism = 'HT2-SHA-512-NONE'
        ..onFastCredentialsChanged = ((updated) {
          cleared = updated.fastToken == null;
        });
      final connection = Connection(account);
      connection.socket = _RecordingSocket();

      // Server only offers HT2-SHA-256-NONE now.
      final authElement = buildSasl2AuthElement(['HT2-SHA-256-NONE']);
      final feature = SaslAuthenticationFeature(connection, 'secret');
      feature.negotiate([authElement]);

      // The stale credentials were reported as cleared; the subsequent SCRAM
      // authentication then requests a fresh token for the offered mechanism.
      expect(cleared, isTrue);
    });

    test('tryCreateFastHandler ignores missing fastMechanism', () {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..fastEnabled = true
        ..fastToken = base64.encode(List.filled(32, 1))
        // fastMechanism intentionally not set.
        ..fastTokenExpiry = '2099-01-01T00:00:00Z';
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;

      final authElement = buildSasl2AuthElement(['HT2-SHA-256-NONE']);
      final inlineFeatures =
          SaslAuthenticationFeature.parseInlineFeatures(authElement);
      connection.setSasl2InlineFeatures(inlineFeatures);

      final feature = SaslAuthenticationFeature(connection, 'secret');
      feature.negotiate([authElement]);
      // Without a mechanism stored, FAST should not be attempted.
      // The feature should fall back to SCRAM-SHA-256.
      if (socket.writes.isNotEmpty) {
        final doc = xml.XmlDocument.parse(socket.writes.first).rootElement;
        final auth = Nonza.parse(doc);
        final mechanism = auth.getAttribute('mechanism')?.value ?? '';
        expect(mechanism, isNot(startsWith('HT')),
            reason: 'should not use FAST without a stored mechanism name');
      }
    });
  });
}
