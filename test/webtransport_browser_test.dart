@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:xmpp_stone/src/connection/XmppWebTransportHtml.dart';

void main() {
  test('decodes a base64 WebTransport server certificate hash', () {
    expect(
      decodeWebTransportCertificateHash(
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      ),
      List<int>.filled(32, 0),
    );
  });

  test('rejects a certificate hash that is not a SHA-256 digest', () {
    expect(
      () => decodeWebTransportCertificateHash('AAECAwQ='),
      throwsFormatException,
    );
  });

  test('WebTransport adapter exchanges ordered UTF-8 bytes', () async {
    final inbound = web.TransformStream();
    final outbound = web.TransformStream();
    var closed = false;
    final socket = XmppWebTransportHtml(
      streamFactory: (url) async {
        expect(url, 'https://xmpp.example.test/xmpp');
        return WebTransportStreams(
          readable: inbound.readable,
          writable: outbound.writable,
          close: () => closed = true,
        );
      },
    );

    await socket.connect(
      'xmpp.example.test',
      443,
      wsUri: Uri.parse('https://xmpp.example.test:443/xmpp'),
      useWebTransport: true,
    );

    final streamOpening = socket.getStreamOpeningElement('dave.cridland.net');
    expect(
      streamOpening,
      "<?xml version='1.0'?><stream:stream xmlns='jabber:client' "
      "version='1.0' xmlns:stream='http://etherx.jabber.org/streams' "
      "to='dave.cridland.net' xml:lang='en'>",
    );

    final outboundReader =
        outbound.readable.getReader() as web.ReadableStreamDefaultReader;
    socket.write(streamOpening);
    socket.write('<message>Jabberwocky \u0394</message>');

    final first = await outboundReader.read().toDart;
    final second = await outboundReader.read().toDart;
    expect(_decode(first.value), streamOpening);
    expect(_decode(second.value), '<message>Jabberwocky \u0394</message>');

    final received = Completer<String>();
    final receivedBuffer = StringBuffer();
    socket.listen((chunk) {
      receivedBuffer.write(chunk);
      if (receivedBuffer.toString().endsWith('</features>')) {
        received.complete(receivedBuffer.toString());
      }
    });
    final inboundWriter = inbound.writable.getWriter();
    final inboundBytes = utf8.encode('<features>\u0394</features>');
    final splitInsideDelta = inboundBytes.indexOf(0xce) + 1;
    await inboundWriter
        .write(
          Uint8List.fromList(inboundBytes.take(splitInsideDelta).toList()).toJS,
        )
        .toDart;
    await inboundWriter
        .write(
          Uint8List.fromList(inboundBytes.skip(splitInsideDelta).toList()).toJS,
        )
        .toDart;
    expect(await received.future, '<features>\u0394</features>');
    inboundWriter.releaseLock();

    socket.close();
    expect(closed, isTrue);
  });

  test(
    'routes post-bind stanzas onto client-initiated auxiliary streams',
    () async {
      final controlInbound = web.TransformStream();
      final controlOutbound = web.TransformStream();
      final auxiliaryInbound = web.TransformStream();
      final auxiliaryOutbound = web.TransformStream();
      var auxiliaryOpenCount = 0;
      final socket = XmppWebTransportHtml(
        streamFactory: (_) async => WebTransportStreams(
          readable: controlInbound.readable,
          writable: controlOutbound.writable,
          close: () {},
          openBidirectionalStream: () async {
            auxiliaryOpenCount++;
            return WebTransportStreamChannel(
              readable: auxiliaryInbound.readable,
              writable: auxiliaryOutbound.writable,
            );
          },
        ),
      );
      await socket.connect('example.test', 443, useWebTransport: true);

      final bindReceived = Completer<void>();
      socket.listen((chunk) {
        if (chunk.contains('<bound')) bindReceived.complete();
      });
      final controlWriter = controlInbound.writable.getWriter();
      await controlWriter
          .write(
            Uint8List.fromList(
              utf8.encode(
                "<bound xmlns='urn:xmpp:bind:0'>"
                '<jid>test1@example.test/browser</jid></bound>',
              ),
            ).toJS,
          )
          .toDart;
      await bindReceived.future;

      const stanza = '<message to="contact@example.test/phone" id="m1"/>';
      socket.write(stanza);
      final auxiliaryReader =
          auxiliaryOutbound.readable.getReader()
              as web.ReadableStreamDefaultReader;
      final written = await auxiliaryReader.read().toDart;
      expect(_decode(written.value), stanza);
      expect(auxiliaryOpenCount, 1);

      controlWriter.releaseLock();
      socket.close();
    },
  );

  test('accepts and reuses server-initiated bidirectional streams', () async {
    final controlInbound = web.TransformStream();
    final controlOutbound = web.TransformStream();
    final incomingStreams = web.TransformStream();
    final serverInbound = web.TransformStream();
    final serverOutbound = web.TransformStream();
    var clientOpenCount = 0;
    final socket = XmppWebTransportHtml(
      streamFactory: (_) async => WebTransportStreams(
        readable: controlInbound.readable,
        writable: controlOutbound.writable,
        close: () {},
        incomingBidirectionalStreams: incomingStreams.readable,
        openBidirectionalStream: () async {
          clientOpenCount++;
          throw StateError('server stream should be reused');
        },
      ),
    );
    await socket.connect('example.test', 443, useWebTransport: true);

    final receivedServerStanza = Completer<String>();
    final bindReceived = Completer<void>();
    socket.listen((chunk) {
      if (chunk.contains('<bind')) bindReceived.complete();
      if (chunk.contains('server-message')) {
        receivedServerStanza.complete(chunk);
      }
    });

    final incomingWriter = incomingStreams.writable.getWriter();
    final serverPair = web.ReadableWritablePair(
      readable: serverInbound.readable,
      writable: serverOutbound.writable,
    );
    await incomingWriter.write(serverPair).toDart;
    final serverWriter = serverInbound.writable.getWriter();
    await serverWriter
        .write(
          Uint8List.fromList(
            utf8.encode('<message id="server-message"/>'),
          ).toJS,
        )
        .toDart;
    expect(await receivedServerStanza.future, '<message id="server-message"/>');

    final controlWriter = controlInbound.writable.getWriter();
    await controlWriter
        .write(
          Uint8List.fromList(
            utf8.encode(
              "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
              '<jid>test1@example.test/browser</jid></bind>',
            ),
          ).toJS,
        )
        .toDart;
    await bindReceived.future;

    const outbound = '<message to="contact@example.test" id="client-message"/>';
    socket.write(outbound);
    final serverOutboundReader =
        serverOutbound.readable.getReader() as web.ReadableStreamDefaultReader;
    final reusedWrite = await serverOutboundReader.read().toDart;
    expect(_decode(reusedWrite.value), outbound);
    expect(clientOpenCount, 0);

    incomingWriter.releaseLock();
    serverWriter.releaseLock();
    controlWriter.releaseLock();
    socket.close();
  });
}

String _decode(JSAny? value) {
  final bytes = value?.dartify();
  if (bytes is Uint8List) return utf8.decode(bytes);
  if (bytes is List<int>) return utf8.decode(bytes);
  throw StateError('Expected a byte chunk, got ${bytes.runtimeType}');
}
