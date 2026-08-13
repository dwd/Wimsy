import 'dart:async';

import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xml/xml.dart' as xml;
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/sasl/Sasl2AuthHandler.dart';
import 'package:xmpp_stone/src/features/sasl/SaslAuthenticationFeature.dart';
import 'package:xmpp_stone/src/features/sasl/SaslMechanism.dart';

void main() {
  group('SASL2 parsing', () {
    test('parses mechanisms and inline feature offers', () {
      final authentication = Nonza()
        ..name = 'authentication'
        ..addAttribute(
          XmppAttribute('xmlns', SaslAuthenticationFeature.sasl2Namespace),
        );
      authentication.addChild(XmppElement()
        ..name = 'mechanism'
        ..textValue = 'SCRAM-SHA-256');
      authentication.addChild(XmppElement()
        ..name = 'mechanism'
        ..textValue = 'PLAIN');

      final inline = XmppElement()..name = 'inline';
      inline.addChild(XmppElement()
        ..name = 'bind'
        ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bind2:0')));
      authentication.addChild(inline);

      final mechanisms =
          SaslAuthenticationFeature.parseMechanisms(authentication);
      final inlineFeatures =
          SaslAuthenticationFeature.parseInlineFeatures(authentication);

      expect(mechanisms, contains(SaslMechanism.SCRAM_SHA_256));
      expect(mechanisms, contains(SaslMechanism.PLAIN));
      expect(inlineFeatures.containsKey('urn:xmpp:bind2:0'), isTrue);
    });

    test('applies IAP config-version offer to connection', () {
      final connection = Connection(
        XmppAccountSettings.fromJid('alice@example.com', 'secret'),
      );
      final configVersion = Nonza()
        ..name = 'config-version'
        ..addAttribute(
          XmppAttribute('xmlns', SaslAuthenticationFeature.iapNamespace),
        )
        ..addAttribute(XmppAttribute('scheme', 'sha-256'))
        ..addAttribute(XmppAttribute('value', 'abc123'));

      SaslAuthenticationFeature.applyIapConfigVersion(
          connection, configVersion);

      expect(connection.iapAdvertisedInCurrentStream, isTrue);
      expect(connection.iapConfigVersion, isNotNull);
      expect(
        connection.iapConfigVersion?.getAttribute('scheme')?.value,
        equals('sha-256'),
      );
      expect(
        connection.iapConfigVersion?.getAttribute('value')?.value,
        equals('abc123'),
      );
    });
  });

  group('SASL2 handler', () {
    test('sends authenticate with user-agent and accepts success payload',
        () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account
        ..sasl2UserAgentId = '123e4567-e89b-42d3-a456-426614174000'
        ..sasl2Software = 'Wimsy'
        ..sasl2Device = 'desktop';
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();

      await Future<void>.delayed(Duration.zero);
      final authXml = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(authXml);
      expect(auth.name, equals('authenticate'));
      expect(auth.getNameSpace(), equals(Sasl2AuthHandler.sasl2Namespace));
      expect(auth.getAttribute('mechanism')?.value, equals('PLAIN'));
      expect(auth.getChild('initial-response'), isNotNull);
      final userAgent = auth.getChild('user-agent');
      expect(userAgent, isNotNull);
      expect(
        userAgent?.getAttribute('id')?.value,
        equals('123e4567-e89b-42d3-a456-426614174000'),
      );
      expect(auth.getChild('config-version'), isNull);

      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>authz@example.com</authorization-identifier>'
        '<additional-data>dGVzdA==</additional-data>'
        "<bind xmlns='urn:xmpp:bind2:0'/></success></xmpp_stone>",
      );

      final result = await resultFuture;
      expect(result.successful, isTrue);
      expect(connection.authorizationIdentifier, equals('authz@example.com'));
      expect(connection.fullJid.userAtDomain, equals('authz@example.com'));
      expect(connection.sasl2SuccessElements, hasLength(1));
      expect(
        connection.sasl2SuccessElements.first.getNameSpace(),
        equals('urn:xmpp:bind2:0'),
      );
    });

    test('fails explicitly on unsupported continue task flow', () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      final connection = Connection(account);
      connection.socket = _RecordingSocket();

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      connection.handleResponse(
        "<xmpp_stone><continue xmlns='urn:xmpp:sasl:2'/></xmpp_stone>",
      );

      final result = await resultFuture;
      expect(result.successful, isFalse);
      expect(result.message, contains('not yet supported'));
    });

    test('includes IAP config-version in authenticate when advertised',
        () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..iapEnabled = true
        ..iapIncludeConfigVersion = true
        ..sasl2SendUserAgent = false;
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;
      connection.setIapConfigVersion(scheme: 'sha-256', value: 'cfg-v1');
      connection.setState(XmppConnectionState.SocketOpened);

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();

      await Future<void>.delayed(Duration.zero);
      final authXml = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(authXml);
      final configVersion = auth.getChild('config-version');
      expect(configVersion, isNotNull);
      expect(configVersion?.getAttribute('scheme')?.value, equals('sha-256'));
      expect(configVersion?.getAttribute('value')?.value, equals('cfg-v1'));

      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'/></xmpp_stone>",
      );
      final result = await resultFuture;
      expect(result.successful, isTrue);
    });

    test('requests retry with fresh features on IAP mismatch failure',
        () async {
      final account = XmppAccountSettings.fromJid('alice@example.com', 'secret')
        ..iapEnabled = true
        ..iapIncludeConfigVersion = true
        ..sasl2SendUserAgent = false;
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;
      connection.setIapConfigVersion(scheme: 'sha-256', value: 'cfg-v1');
      connection.setState(XmppConnectionState.SocketOpened);

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      connection.handleResponse(
        "<xmpp_stone><failure xmlns='urn:xmpp:sasl:2'>"
        "<config-version-mismatch xmlns='urn:xmpp:iap:0'/>"
        "</failure></xmpp_stone>",
      );

      final result = await resultFuture;
      expect(result.successful, isFalse);
      expect(result.message, equals('IAP config-version mismatch'));
      expect(result.retryWithFreshFeatures, isTrue);
      expect(connection.iapConfigVersion, isNotNull);
      expect(
        connection.iapConfigVersion?.getAttribute('value')?.value,
        equals('cfg-v1'),
      );
    });
  });

  group('SASL2 feature negotiation timing', () {
    test(
        'authenticated is set synchronously when success arrives bundled '
        'with stream features', () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      // A SASL2 <success/> can arrive bundled with a sibling
      // <stream:features/> in the very same server response. Feature
      // negotiation (which gates disco-based negotiators, e.g. Service
      // Discovery -> MAM, on `authenticated`) runs synchronously inside
      // handleResponse, while the SASL handler only flips `authenticated`
      // once its own Future resolves asynchronously. Without the fix,
      // `authenticated` would still be false at this point, causing MAM
      // (and any other disco-gated feature) to never be negotiated.
      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>alice@example.com</authorization-identifier>'
        "</success><stream:features xmlns:stream='http://etherx.jabber.org/streams'/>"
        '</xmpp_stone>',
      );

      // Must already be true here, synchronously, before awaiting the
      // handler's Future.
      expect(connection.authenticated, isTrue);

      final result = await resultFuture;
      expect(result.successful, isTrue);
    });
  });

  group('Bind 2 (XEP-0386)', () {
    test('includes bind element in authenticate when server advertises Bind 2',
        () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account
        ..resource = 'wimsy'
        ..sasl2SendUserAgent = false
        ..useBind2 = true;
      final connection = Connection(account);
      // Simulate server advertising Bind 2 as an inline feature.
      connection.setSasl2InlineFeatures({
        'urn:xmpp:bind:0': XmppElement()
          ..name = 'bind'
          ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bind:0')),
      });
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      final authXml = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(authXml);
      final bind = auth.getChild('bind');
      expect(bind, isNotNull);
      expect(bind?.getNameSpace(), equals('urn:xmpp:bind:0'));
      expect(bind?.getChild('tag')?.textValue, equals('wimsy'));

      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>alice@example.com</authorization-identifier>'
        "</success></xmpp_stone>",
      );
      final result = await resultFuture;
      expect(result.successful, isTrue);
    });

    test('does not include bind element when useBind2 is false', () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account
        ..resource = 'wimsy'
        ..sasl2SendUserAgent = false
        ..useBind2 = false;
      final connection = Connection(account);
      connection.setSasl2InlineFeatures({
        'urn:xmpp:bind:0': XmppElement()
          ..name = 'bind'
          ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bind:0')),
      });
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      final authXml = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(authXml);
      expect(auth.getChild('bind'), isNull);

      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>alice@example.com</authorization-identifier>'
        "</success></xmpp_stone>",
      );
      await resultFuture;
    });

    test('does not include bind element when server does not advertise Bind 2',
        () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account
        ..resource = 'wimsy'
        ..sasl2SendUserAgent = false
        ..useBind2 = true;
      final connection = Connection(account);
      // No Bind 2 in inline features.
      connection.setSasl2InlineFeatures({});
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      final authXml = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(authXml);
      expect(auth.getChild('bind'), isNull);

      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>alice@example.com</authorization-identifier>'
        "</success></xmpp_stone>",
      );
      await resultFuture;
    });

    test('parses bound JID from Bind 2 success element', () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account
        ..resource = 'wimsy'
        ..sasl2SendUserAgent = false
        ..useBind2 = true;
      final connection = Connection(account);
      connection.setSasl2InlineFeatures({
        'urn:xmpp:bind:0': XmppElement()
          ..name = 'bind'
          ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bind:0')),
      });
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      // Server responds with a <bound> element containing the assigned JID.
      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>alice@example.com</authorization-identifier>'
        "<bound xmlns='urn:xmpp:bind:0'>"
        '<jid>alice@example.com/wimsy-server-assigned</jid>'
        '</bound>'
        "</success></xmpp_stone>",
      );
      final result = await resultFuture;
      expect(result.successful, isTrue);
      expect(connection.bind2Completed, isTrue);
      expect(connection.fullJid.resource, equals('wimsy-server-assigned'));
    });

    test('bind2Completed is false when no Bind 2 element in success', () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account.sasl2SendUserAgent = false;
      final connection = Connection(account);
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>alice@example.com</authorization-identifier>'
        "</success></xmpp_stone>",
      );
      await resultFuture;
      expect(connection.bind2Completed, isFalse);
    });

    test('bind element has no tag child when resource is empty', () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account
        ..resource = ''
        ..sasl2SendUserAgent = false
        ..useBind2 = true;
      final connection = Connection(account);
      connection.setSasl2InlineFeatures({
        'urn:xmpp:bind:0': XmppElement()
          ..name = 'bind'
          ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bind:0')),
      });
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      final authXml = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(authXml);
      final bind = auth.getChild('bind');
      expect(bind, isNotNull);
      expect(bind?.getChild('tag'), isNull);

      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>alice@example.com</authorization-identifier>'
        "</success></xmpp_stone>",
      );
      await resultFuture;
    });

    test('includes carbons enable in bind element when server offers it inline',
        () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account
        ..resource = 'wimsy'
        ..sasl2SendUserAgent = false
        ..useBind2 = true;
      final connection = Connection(account);
      // Server advertises carbons nested inside <inline> within <bind>:
      // <bind xmlns='urn:xmpp:bind:0'><inline><feature var='urn:xmpp:carbons:2'/></inline></bind>
      final bind2Feature = XmppElement()
        ..name = 'bind'
        ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bind:0'));
      final inlineEl = XmppElement()..name = 'inline';
      inlineEl.addChild(XmppElement()
        ..name = 'feature'
        ..addAttribute(XmppAttribute('var', 'urn:xmpp:carbons:2')));
      bind2Feature.addChild(inlineEl);
      connection.setSasl2InlineFeatures({'urn:xmpp:bind:0': bind2Feature});
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      final authXml = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(authXml);
      final bind = auth.getChild('bind');
      expect(bind, isNotNull);
      final enable = bind?.getChild('enable');
      expect(enable, isNotNull);
      expect(enable?.getNameSpace(), equals('urn:xmpp:carbons:2'));

      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>alice@example.com</authorization-identifier>'
        "</success></xmpp_stone>",
      );
      await resultFuture;
    });

    test('does not include carbons enable when server does not offer it inline',
        () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account
        ..resource = 'wimsy'
        ..sasl2SendUserAgent = false
        ..useBind2 = true;
      final connection = Connection(account);
      // Bind 2 advertised but no carbons child.
      connection.setSasl2InlineFeatures({
        'urn:xmpp:bind:0': XmppElement()
          ..name = 'bind'
          ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bind:0')),
      });
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      final authXml = xml.XmlDocument.parse(socket.writes.first).rootElement;
      final auth = Nonza.parse(authXml);
      final bind = auth.getChild('bind');
      expect(bind, isNotNull);
      expect(bind?.getChild('enable'), isNull);

      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>alice@example.com</authorization-identifier>'
        "</success></xmpp_stone>",
      );
      await resultFuture;
    });

    test('carbons2EnabledInline is true when bound element contains enabled',
        () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account
        ..resource = 'wimsy'
        ..sasl2SendUserAgent = false
        ..useBind2 = true;
      final connection = Connection(account);
      connection.setSasl2InlineFeatures({
        'urn:xmpp:bind:0': XmppElement()
          ..name = 'bind'
          ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bind:0')),
      });
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>alice@example.com</authorization-identifier>'
        "<bound xmlns='urn:xmpp:bind:0'>"
        "<enabled xmlns='urn:xmpp:carbons:2'/>"
        '</bound>'
        "</success></xmpp_stone>",
      );
      await resultFuture;
      expect(connection.bind2Completed, isTrue);
      expect(connection.carbons2EnabledInline, isTrue);
    });

    test('carbons2EnabledInline is false when bound element has no enabled',
        () async {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      account
        ..resource = 'wimsy'
        ..sasl2SendUserAgent = false
        ..useBind2 = true;
      final connection = Connection(account);
      connection.setSasl2InlineFeatures({
        'urn:xmpp:bind:0': XmppElement()
          ..name = 'bind'
          ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:bind:0')),
      });
      final socket = _RecordingSocket();
      connection.socket = socket;

      final handler =
          Sasl2AuthHandler(connection, 'secret', SaslMechanism.PLAIN);
      final resultFuture = handler.start();
      await Future<void>.delayed(Duration.zero);

      connection.handleResponse(
        "<xmpp_stone><success xmlns='urn:xmpp:sasl:2'>"
        '<authorization-identifier>alice@example.com</authorization-identifier>'
        "<bound xmlns='urn:xmpp:bind:0'/>"
        "</success></xmpp_stone>",
      );
      await resultFuture;
      expect(connection.bind2Completed, isTrue);
      expect(connection.carbons2EnabledInline, isFalse);
    });
  });

  group('SASL2 state', () {
    test('authenticated SASL2 state does not require stream restart', () {
      final account =
          XmppAccountSettings.fromJid('alice@example.com', 'secret');
      final connection = Connection(account);

      expect(
        () => connection.setState(
          XmppConnectionState.AuthenticatedSasl2AwaitingFeatures,
        ),
        returnsNormally,
      );
      expect(connection.authenticated, isTrue);
    });
  });
}

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
  void write(Object? message) {
    writes.add(message?.toString() ?? '');
  }

  @override
  void close() {
    _controller.close();
  }
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
  }) async {
    return null;
  }

  @override
  String getStreamOpeningElement(String domain) {
    return "<stream:stream to='$domain'/>";
  }

  @override
  StreamSubscription<String> listen(
    void Function(String event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
