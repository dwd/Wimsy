import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';
import 'package:xmpp_stone/src/extensions/ibb/IbbManager.dart';

void main() {
  test('IBB manager parses open/data/close IQs', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    final ibb = IbbManager.getInstance(connection);

    final openCompleter = Completer<IbbOpen>();
    final dataCompleter = Completer<IbbData>();
    final closeCompleter = Completer<IbbClose>();

    ibb.openStream.listen(openCompleter.complete);
    ibb.dataStream.listen(dataCompleter.complete);
    ibb.closeStream.listen(closeCompleter.complete);

    final openIq = '<iq type="set" id="o1" from="peer@example.com/res">'
        '<open xmlns="http://jabber.org/protocol/ibb" sid="sid1" block-size="4096" stanza="iq"/>'
        '</iq>';
    connection.handleResponse(connection.prepareStreamResponse(openIq));

    final payload = base64Encode('hi'.codeUnits);
    final dataIq = '<iq type="set" id="d1" from="peer@example.com/res">'
        '<data xmlns="http://jabber.org/protocol/ibb" sid="sid1" seq="0">$payload</data>'
        '</iq>';
    connection.handleResponse(connection.prepareStreamResponse(dataIq));

    final closeIq = '<iq type="set" id="c1" from="peer@example.com/res">'
        '<close xmlns="http://jabber.org/protocol/ibb" sid="sid1"/>'
        '</iq>';
    connection.handleResponse(connection.prepareStreamResponse(closeIq));

    final openEvent =
        await openCompleter.future.timeout(const Duration(seconds: 1));
    expect(openEvent.sid, 'sid1');
    expect(openEvent.blockSize, 4096);

    final dataEvent =
        await dataCompleter.future.timeout(const Duration(seconds: 1));
    expect(dataEvent.sid, 'sid1');
    expect(String.fromCharCodes(dataEvent.bytes), 'hi');

    final closeEvent =
        await closeCompleter.future.timeout(const Duration(seconds: 1));
    expect(closeEvent.sid, 'sid1');
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
