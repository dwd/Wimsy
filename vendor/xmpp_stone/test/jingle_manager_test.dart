import 'dart:async';

import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';
import 'package:xmpp_stone/src/connection/XmppWebsocketApi.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';
import 'package:xmpp_stone/src/extensions/jingle/JingleManager.dart';

void main() {
  test('Jingle session-initiate parses file offer + IBB transport', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    final manager = JingleManager.getInstance(connection);

    final completer = Completer<JingleSessionEvent>();
    manager.sessionStream.listen((event) {
      completer.complete(event);
    });

    final iq = '<iq type="set" id="j1" from="peer@example.com/res" to="user@example.com/res">'
        '<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate" sid="sid123">'
        '<content creator="initiator" name="file">'
        '<description xmlns="urn:xmpp:jingle:apps:file-transfer:5">'
        '<offer>'
        '<file xmlns="urn:xmpp:file:metadata:0">'
        '<name>photo.png</name>'
        '<size>12</size>'
        '<media-type>image/png</media-type>'
        '</file>'
        '</offer>'
        '</description>'
        '<transport xmlns="urn:xmpp:jingle:transports:ibb:1" sid="ibb1" block-size="4096" stanza="iq"/>'
        '</content>'
        '</jingle>'
        '</iq>';

    connection.handleResponse(connection.prepareStreamResponse(iq));

    final event = await completer.future.timeout(const Duration(seconds: 1));
    expect(event.action, JingleAction.sessionInitiate);
    expect(event.sid, 'sid123');
    expect(event.content, isNotNull);
    expect(event.content!.fileOffer, isNotNull);
    expect(event.content!.fileOffer!.fileName, 'photo.png');
    expect(event.content!.fileOffer!.fileSize, 12);
    expect(event.content!.fileOffer!.mediaType, 'image/png');
    expect(event.content!.ibbTransport, isNotNull);
    expect(event.content!.ibbTransport!.sid, 'ibb1');
  });

  test('Jingle manager replies to session-initiate with result', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    JingleManager.getInstance(connection);
    final responses = <IqStanza>[];
    connection.outStanzasStream.listen((stanza) {
      if (stanza is IqStanza) {
        responses.add(stanza);
      }
    });

    final iq = '<iq type="set" id="j2" from="peer@example.com/res">'
        '<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate" sid="sid124"/>'
        '</iq>';
    connection.handleResponse(connection.prepareStreamResponse(iq));

    await Future<void>.delayed(Duration.zero);
    expect(responses, isNotEmpty);
    expect(responses.first.type, IqStanzaType.RESULT);
  });

  test('Jingle session-initiate parses RTP description', () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    final manager = JingleManager.getInstance(connection);

    final completer = Completer<JingleSessionEvent>();
    manager.sessionStream.listen((event) {
      completer.complete(event);
    });

    final iq = '<iq type="set" id="j3" from="peer@example.com/res">'
        '<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate" sid="sid125">'
        '<content creator="initiator" name="audio">'
        '<description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">'
        '<payload-type id="111" name="opus" clockrate="48000" channels="2" />'
        '</description>'
        '</content>'
        '</jingle>'
        '</iq>';

    connection.handleResponse(connection.prepareStreamResponse(iq));

    final event = await completer.future.timeout(const Duration(seconds: 1));
    expect(event.content, isNotNull);
    expect(event.content!.rtpDescription, isNotNull);
    expect(event.content!.rtpDescription!.media, 'audio');
    expect(event.content!.rtpDescription!.payloadTypes, hasLength(1));
    expect(event.content!.rtpDescription!.payloadTypes.first.id, 111);
    expect(event.content!.rtpDescription!.payloadTypes.first.name, 'opus');
    expect(event.content!.rtpDescription!.payloadTypes.first.clockRate, 48000);
    expect(event.content!.rtpDescription!.payloadTypes.first.channels, 2);
  });

  test('Jingle manager builds RTP session-initiate', () {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    final manager = JingleManager.getInstance(connection);

    final stanza = manager.buildRtpSessionInitiate(
      to: account.fullJid,
      sid: 'sid126',
      contentName: 'audio',
      creator: 'initiator',
      description: const JingleRtpDescription(
        media: 'audio',
        payloadTypes: [
          JingleRtpPayloadType(id: 0, name: 'PCMU', clockRate: 8000),
        ],
      ),
      transport: const JingleIceTransport(
        ufrag: 'ufrag',
        password: 'pwd',
        fingerprint: JingleDtlsFingerprint(
          hash: 'sha-256',
          fingerprint: 'AB:CD',
          setup: 'actpass',
        ),
        candidates: [
          JingleIceCandidate(
            foundation: '1',
            component: 1,
            protocol: 'udp',
            priority: 123,
            ip: '10.0.0.1',
            port: 9999,
            type: 'host',
            generation: 0,
          ),
        ],
      ),
    );

    final jingle = stanza.getChild('jingle');
    expect(jingle, isNotNull);
    final content = jingle!.getChild('content');
    final description = content?.getChild('description');
    expect(description?.getAttribute('xmlns')?.value,
        JingleManager.rtpNamespace);
    expect(description?.getAttribute('media')?.value, 'audio');
    final transport = content?.getChild('transport');
    expect(transport?.getAttribute('xmlns')?.value,
        JingleManager.iceUdpNamespace);
    expect(transport?.getChild('fingerprint')?.textValue, 'AB:CD');
  });

  test('Jingle session-initiate parses ICE transport and DTLS fingerprint',
      () async {
    final account = XmppAccountSettings.fromJid('user@example.com/res', 'pass');
    final connection = Connection(account);
    connection.socket = _FakeSocket();
    final manager = JingleManager.getInstance(connection);

    final completer = Completer<JingleSessionEvent>();
    manager.sessionStream.listen((event) {
      completer.complete(event);
    });

    final iq = '<iq type="set" id="j4" from="peer@example.com/res">'
        '<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate" sid="sid127">'
        '<content creator="initiator" name="audio">'
        '<description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">'
        '<payload-type id="111" name="opus" clockrate="48000" channels="2" />'
        '</description>'
        '<transport xmlns="urn:xmpp:jingle:transports:ice-udp:1" ufrag="uf" pwd="pw">'
        '<fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0" hash="sha-256" setup="actpass">AA:BB</fingerprint>'
        '<candidate foundation="1" component="1" protocol="udp" priority="123" ip="10.0.0.2" port="9999" type="host" generation="0" />'
        '</transport>'
        '</content>'
        '</jingle>'
        '</iq>';

    connection.handleResponse(connection.prepareStreamResponse(iq));

    final event = await completer.future.timeout(const Duration(seconds: 1));
    expect(event.content?.iceTransport, isNotNull);
    expect(event.content!.iceTransport!.ufrag, 'uf');
    expect(event.content!.iceTransport!.password, 'pw');
    expect(event.content!.iceTransport!.candidates, hasLength(1));
    expect(event.content!.iceTransport!.fingerprint?.hash, 'sha-256');
    expect(event.content!.iceTransport!.fingerprint?.fingerprint, 'AA:BB');
  });
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
