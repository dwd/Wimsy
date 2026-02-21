import 'dart:async';

import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';
import 'package:xmpp_stone/src/elements/stanzas/AbstractStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';
import 'package:xmpp_stone/src/extensions/iq_router/IqRouter.dart';
import 'package:xmpp_stone/src/features/servicediscovery/ServiceDiscoveryNegotiator.dart';
import 'package:xmpp_stone/src/features/privacy_lists/privacy_lists_manager.dart';
import 'package:xmpp_stone/src/roster/Buddy.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/roster/RosterManager.dart';

void main() {
  test('IQ router sends service-unavailable when no handler', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    final responses = <IqStanza>[];
    connection.outStanzasStream.listen((stanza) {
      if (stanza is IqStanza) {
        responses.add(stanza);
      }
    });

    final iq = '<iq type="get" id="test1" from="peer@example.com/res">'
        '<query xmlns="urn:example:unknown"/></iq>';
    connection.handleResponse(connection.prepareStreamResponse(iq));

    await Future<void>.delayed(Duration.zero);
    expect(responses, isNotEmpty);
    final response = responses.first;
    expect(response.type, IqStanzaType.ERROR);
    final error = response.getChild('error');
    expect(error, isNotNull);
    final condition = error!.getChild('service-unavailable');
    expect(condition, isNotNull);
  });

  test('IQ router uses handler response when registered', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    final responses = <IqStanza>[];
    connection.outStanzasStream.listen((stanza) {
      if (stanza is IqStanza) {
        responses.add(stanza);
      }
    });

    final router = IqRouter.getInstance(connection);
    router.registerNamespaceHandler('urn:example:ping', (request) {
      return IqStanza(request.id, IqStanzaType.RESULT);
    });

    final iq = '<iq type="get" id="test2" from="peer@example.com/res">'
        '<ping xmlns="urn:example:ping"/></iq>';
    connection.handleResponse(connection.prepareStreamResponse(iq));

    await Future<void>.delayed(Duration.zero);
    expect(responses, isNotEmpty);
    expect(responses.first.type, IqStanzaType.RESULT);
  });

  test('IQ router returns internal-server-error on handler exception and reports', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    final responses = <IqStanza>[];
    connection.outStanzasStream.listen((stanza) {
      if (stanza is IqStanza) {
        responses.add(stanza);
      }
    });

    Object? reportedError;
    StackTrace? reportedStack;
    Connection.errorReporter = (error, stackTrace) {
      reportedError = error;
      reportedStack = stackTrace;
    };

    final router = IqRouter.getInstance(connection);
    router.registerNamespaceHandler('urn:example:boom', (request) {
      throw StateError('boom');
    });

    final iq = '<iq type="get" id="test3" from="peer@example.com/res">'
        '<boom xmlns="urn:example:boom"/></iq>';
    connection.handleResponse(connection.prepareStreamResponse(iq));

    await Future<void>.delayed(Duration.zero);
    expect(responses, isNotEmpty);
    final response = responses.first;
    expect(response.type, IqStanzaType.ERROR);
    final error = response.getChild('error');
    expect(error, isNotNull);
    final condition = error!.getChild('internal-server-error');
    expect(condition, isNotNull);
    expect(reportedError, isA<StateError>());
    expect(reportedStack, isNotNull);
    Connection.errorReporter = null;
  });

  test('IQ router invokes response handler for matching id', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    final router = IqRouter.getInstance(connection);
    final completer = Completer<IqStanza>();
    router.registerResponseHandler('resp1', (response) {
      completer.complete(response);
    });

    final iq = '<iq type="result" id="resp1" from="peer@example.com/res">'
        '<query xmlns="urn:example:resp"/></iq>';
    connection.handleResponse(connection.prepareStreamResponse(iq));

    final result = await completer.future.timeout(const Duration(seconds: 1));
    expect(result.type, IqStanzaType.RESULT);
  });

  test('PingManager responds to ping IQ via router', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();

    final responseFuture = _waitForIqResponse(connection, 'ping1');
    final iq = '<iq type="get" id="ping1" from="peer@example.com/res">'
        '<ping xmlns="urn:xmpp:ping"/></iq>';
    connection.handleResponse(connection.prepareStreamResponse(iq));

    final response = await responseFuture;
    expect(response.type, IqStanzaType.RESULT);
    expect(response.toJid?.fullJid, equals('peer@example.com/res'));
  });

  test('Service discovery responds to disco#info IQ via router', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    ServiceDiscoveryNegotiator.getInstance(connection);

    final responseFuture = _waitForIqResponse(connection, 'disco1');
    final iq = '<iq type="get" id="disco1" from="peer@example.com/res">'
        '<query xmlns="http://jabber.org/protocol/disco#info"/></iq>';
    connection.handleResponse(connection.prepareStreamResponse(iq));

    final response = await responseFuture;
    expect(response.type, IqStanzaType.RESULT);
    final query = response.getChild('query');
    expect(query, isNotNull);
    expect(query!.getAttribute('xmlns')?.value,
        equals('http://jabber.org/protocol/disco#info'));
  });

  test('Roster manager responds to roster push IQ via router', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();

    final responseFuture = _waitForIqResponse(connection, 'roster1');
    final iq = '<iq type="set" id="roster1" from="peer@example.com/res">'
        '<query xmlns="jabber:iq:roster">'
        '<item jid="alice@example.com" name="Alice"/>'
        '</query></iq>';
    connection.handleResponse(connection.prepareStreamResponse(iq));

    final response = await responseFuture;
    expect(response.type, IqStanzaType.RESULT);
    expect(response.toJid?.fullJid, equals('peer@example.com/res'));
  });

  test('Privacy list push responds via router', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    PrivacyListsManager.getInstance(connection);

    final responseFuture = _waitForIqResponse(connection, 'privacy1');
    final iq = '<iq type="set" id="privacy1" from="peer@example.com/res">'
        '<query xmlns="jabber:iq:privacy">'
        '<list name="blocked"/>'
        '</query></iq>';
    connection.handleResponse(connection.prepareStreamResponse(iq));

    final response = await responseFuture;
    expect(response.type, IqStanzaType.RESULT);
    expect(response.toJid?.fullJid, equals('peer@example.com/res'));
  });

  test('Roster manager completes addRosterItem on result', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    final manager = RosterManager.getInstance(connection);

    final requestIdFuture = _waitForRosterRequestId(connection);
    final future = manager.addRosterItem(Buddy(Jid.fromFullJid('alice@example.com')));
    final requestId = await requestIdFuture;

    final response = '<iq type="result" id="$requestId" from="peer@example.com/res">'
        '<query xmlns="jabber:iq:roster"/></iq>';
    connection.handleResponse(connection.prepareStreamResponse(response));

    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.type, IqStanzaType.SET);
  });

  test('Invalid roster push yields service-unavailable', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    RosterManager.getInstance(connection);

    final responseFuture = _waitForIqResponse(connection, 'rosterBad');
    final iq = '<iq type="set" id="rosterBad" from="peer@example.com/res">'
        '<query xmlns="jabber:iq:roster"/>'
        '</iq>';
    connection.handleResponse(connection.prepareStreamResponse(iq));

    final response = await responseFuture;
    expect(response.type, IqStanzaType.ERROR);
    final error = response.getChild('error');
    expect(error, isNotNull);
    final condition = error!.getChild('service-unavailable');
    expect(condition, isNotNull);
  });

  test('Invalid privacy list push yields service-unavailable', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    PrivacyListsManager.getInstance(connection);

    final responseFuture = _waitForIqResponse(connection, 'privacyBad');
    final iq = '<iq type="set" id="privacyBad" from="peer@example.com/res">'
        '<query xmlns="jabber:iq:privacy"/>'
        '</iq>';
    connection.handleResponse(connection.prepareStreamResponse(iq));

    final response = await responseFuture;
    expect(response.type, IqStanzaType.ERROR);
    final error = response.getChild('error');
    expect(error, isNotNull);
    final condition = error!.getChild('service-unavailable');
    expect(condition, isNotNull);
  });
}

Future<IqStanza> _waitForIqResponse(Connection connection, String id) {
  final completer = Completer<IqStanza>();
  late final StreamSubscription<AbstractStanza> subscription;
  subscription = connection.outStanzasStream.listen((stanza) {
    if (stanza is IqStanza && stanza.id == id) {
      subscription.cancel();
      completer.complete(stanza);
    }
  });
  return completer.future.timeout(const Duration(seconds: 1));
}

Future<String> _waitForRosterRequestId(Connection connection) {
  final completer = Completer<String>();
  late final StreamSubscription<AbstractStanza> subscription;
  subscription = connection.outStanzasStream.listen((stanza) {
    if (stanza is IqStanza &&
        stanza.type == IqStanzaType.SET &&
        stanza.getChild('query')?.getAttribute('xmlns')?.value ==
            'jabber:iq:roster') {
      subscription.cancel();
      completer.complete(stanza.id!);
    }
  });
  return completer.future.timeout(const Duration(seconds: 1));
}

class _FakeSocket extends Stream<String> implements XmppWebSocket {
  final StreamController<String> _controller = StreamController<String>.broadcast();

  @override
  StreamSubscription<String> listen(void Function(String event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return _controller.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Future<XmppWebSocket> connect<S>(String host, int port,
      {String Function(String event)? map,
      List<String>? wsProtocols,
      String? wsPath,
      Uri? wsUri,
      bool useWebSocket = false,
      bool directTls = false,
      String? tlsHost}) async {
    return this;
  }

  @override
  void write(Object? message) {}

  @override
  void close() {}

  @override
  Future<SecureSocket?> secure(
      {host,
      SecurityContext? context,
      bool Function(X509Certificate certificate)? onBadCertificate,
      List<String>? supportedProtocols}) async {
    return null;
  }

  @override
  String getStreamOpeningElement(String domain) {
    return '<stream:stream>';
  }
}
