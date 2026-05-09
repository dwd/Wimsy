import 'dart:async';
import 'package:universal_io/io.dart';

import 'package:test/test.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';

void main() {
  test('Unknown IQ GET yields service-unavailable error', () async {
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
}

class _FakeSocket extends Stream<String> implements XmppWebSocket {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

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
      bool useQuic = false,
      bool directTls = false,
      String? tlsHost}) async {
    return this;
  }

  @override
  void write(Object? message) {}

  @override
  void close() {}
  @override
  Future<dynamic> getQuicStats() => Future.value(null);
  @override
  bool get isQuic => false;

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
