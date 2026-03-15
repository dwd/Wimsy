import 'dart:async';

import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/stanzas/AbstractStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';
import 'package:xmpp_stone/src/features/message_archive/MessageArchiveManager.dart';

void main() {
  test('queryById emits MAM form with before-id + with fields', () async {
    final connection = _buildConnection();
    final manager = MessageArchiveManager.getInstance(connection);
    final sent = _waitForOutgoingIq(connection);

    manager.queryById(
      beforeId: 'mam-before-1',
      jid: Jid.fromFullJid('peer@example.com/resource'),
      max: 25,
      before: 'rsm-before-1',
    );

    final iq = await sent;
    final xml = iq.buildXmlString();
    expect(xml, contains('urn:xmpp:mam:2'));
    expect(xml, contains('var="before-id"'));
    expect(xml, contains('<value>mam-before-1</value>'));
    expect(xml, contains('var="with"'));
    expect(xml, contains('<value>peer@example.com</value>'));
    expect(xml, contains('<max>25</max>'));
    expect(xml, contains('<before>rsm-before-1</before>'));
  });

  test('queryById emits MAM form with after-id and room target', () async {
    final connection = _buildConnection();
    final manager = MessageArchiveManager.getInstance(connection);
    final sent = _waitForOutgoingIq(connection);

    manager.queryById(
      afterId: 'mam-after-9',
      toJid: Jid.fromFullJid('room@example.com'),
      max: 50,
      after: 'rsm-after-9',
    );

    final iq = await sent;
    final xml = iq.buildXmlString();
    expect(xml, contains('to="room@example.com"'));
    expect(xml, contains('var="after-id"'));
    expect(xml, contains('<value>mam-after-9</value>'));
    expect(xml, contains('<max>50</max>'));
    expect(xml, contains('<after>rsm-after-9</after>'));
  });

  test('queryById without id filters falls back to queryAll XML shape',
      () async {
    final connection = _buildConnection();
    final manager = MessageArchiveManager.getInstance(connection);
    final sent = _waitForOutgoingIq(connection);

    manager.queryById(max: 10, before: '');

    final iq = await sent;
    final query = iq.getChild('query');
    expect(query, isNotNull);
    expect(query!.getAttribute('xmlns')?.value, equals('urn:xmpp:mam:2'));
    expect(query.getChild('x'), isNull,
        reason: 'queryAll path must not send data form');
    final set = query.getChild('set');
    expect(set, isNotNull);
    expect(set!.getAttribute('xmlns')?.value,
        equals('http://jabber.org/protocol/rsm'));
    expect(_childText(set, 'max'), equals('10'));
    expect(_childText(set, 'before'), equals(''));
  });
}

Connection _buildConnection() {
  final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
  final connection = Connection(account);
  connection.socket = _FakeSocket();
  return connection;
}

Future<IqStanza> _waitForOutgoingIq(Connection connection) {
  final completer = Completer<IqStanza>();
  late final StreamSubscription<AbstractStanza> subscription;
  subscription = connection.outStanzasStream.listen((stanza) {
    if (stanza is IqStanza) {
      subscription.cancel();
      completer.complete(stanza);
    }
  });
  return completer.future.timeout(const Duration(seconds: 1));
}

String? _childText(XmppElement parent, String name) {
  final child = parent.getChild(name);
  return child?.textValue;
}

class _FakeSocket extends Stream<String> implements XmppWebSocket {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

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

  @override
  Future<XmppWebSocket> connect<S>(
    String host,
    int port, {
    String Function(String event)? map,
    List<String>? wsProtocols,
    String? wsPath,
    Uri? wsUri,
    bool useWebSocket = false,
    bool directTls = false,
    String? tlsHost,
  }) async {
    return this;
  }

  @override
  void write(Object? message) {}

  @override
  void close() {}

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
    return '<stream:stream>';
  }
}
