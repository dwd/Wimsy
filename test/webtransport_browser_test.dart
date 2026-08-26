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

    final outboundReader =
        outbound.readable.getReader() as web.ReadableStreamDefaultReader;
    socket.write('<open to="dave.cridland.net"/>');
    socket.write('<message>Jabberwocky \u0394</message>');

    final first = await outboundReader.read().toDart;
    final second = await outboundReader.read().toDart;
    expect(_decode(first.value), '<open to="dave.cridland.net"/>');
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
}

String _decode(JSAny? value) {
  final bytes = value?.dartify();
  if (bytes is Uint8List) return utf8.decode(bytes);
  if (bytes is List<int>) return utf8.decode(bytes);
  throw StateError('Expected a byte chunk, got ${bytes.runtimeType}');
}
