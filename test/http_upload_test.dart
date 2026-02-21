import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/http_upload.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('buildHttpUploadRequest sets required attributes', () {
    final request = buildHttpUploadRequest(
      fileName: 'photo.png',
      size: 1234,
      contentType: 'image/png',
    );

    expect(request.name, 'request');
    expect(request.getAttribute('xmlns')?.value, httpUploadNamespace);
    expect(request.getAttribute('filename')?.value, 'photo.png');
    expect(request.getAttribute('size')?.value, '1234');
    expect(request.getAttribute('content-type')?.value, 'image/png');
  });

  test('HttpUploadSlot parses slot URLs and headers', () {
    final stanza = IqStanza('slot-1', IqStanzaType.RESULT);
    final slot = XmppElement()..name = 'slot';
    slot.addAttribute(XmppAttribute('xmlns', httpUploadNamespace));
    final put = XmppElement()..name = 'put';
    put.addAttribute(XmppAttribute('url', 'https://upload.example/put'));
    final header = XmppElement()..name = 'header';
    header.addAttribute(XmppAttribute('name', 'Authorization'));
    header.textValue = 'Bearer 123';
    put.addChild(header);
    final get = XmppElement()..name = 'get';
    get.addAttribute(XmppAttribute('url', 'https://cdn.example/get'));
    slot.addChild(put);
    slot.addChild(get);
    stanza.addChild(slot);

    final parsed = HttpUploadSlot.fromIq(stanza);
    expect(parsed, isNotNull);
    expect(parsed!.putUrl.toString(), 'https://upload.example/put');
    expect(parsed.getUrl.toString(), 'https://cdn.example/get');
    expect(parsed.putHeaders, {'Authorization': 'Bearer 123'});
  });

  test('HttpUploadSlot returns null for missing slot', () {
    final stanza = IqStanza('slot-2', IqStanzaType.RESULT);
    final parsed = HttpUploadSlot.fromIq(stanza);
    expect(parsed, isNull);
  });
}
