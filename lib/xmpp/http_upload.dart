import 'package:xmpp_stone/xmpp_stone.dart';

const String httpUploadNamespace = 'urn:xmpp:http:upload:0';

XmppElement buildHttpUploadRequest({
  required String fileName,
  required int size,
  String? contentType,
}) {
  final request = XmppElement()..name = 'request';
  request.addAttribute(XmppAttribute('xmlns', httpUploadNamespace));
  request.addAttribute(XmppAttribute('filename', fileName));
  request.addAttribute(XmppAttribute('size', size.toString()));
  if (contentType != null && contentType.isNotEmpty) {
    request.addAttribute(XmppAttribute('content-type', contentType));
  }
  return request;
}

class HttpUploadSlot {
  HttpUploadSlot({
    required this.putUrl,
    required this.getUrl,
    required this.putHeaders,
  });

  final Uri putUrl;
  final Uri getUrl;
  final Map<String, String> putHeaders;

  static HttpUploadSlot? fromIq(IqStanza stanza) {
    if (stanza.type != IqStanzaType.RESULT) {
      return null;
    }
    final slot = stanza.children.firstWhere(
      (child) => child.name == 'slot' && child.getAttribute('xmlns')?.value == httpUploadNamespace,
      orElse: () => XmppElement(),
    );
    if (slot.name != 'slot') {
      return null;
    }
    final put = slot.getChild('put');
    final get = slot.getChild('get');
    final putUrl = _parseUrl(put);
    final getUrl = _parseUrl(get);
    if (putUrl == null || getUrl == null) {
      return null;
    }
    final headers = <String, String>{};
    if (put != null) {
      for (final header in put.children.where((child) => child.name == 'header')) {
        final name = header.getAttribute('name')?.value?.trim() ?? '';
        final value = header.textValue?.trim() ?? '';
        if (name.isEmpty || value.isEmpty) {
          continue;
        }
        headers[name] = value;
      }
    }
    return HttpUploadSlot(
      putUrl: putUrl,
      getUrl: getUrl,
      putHeaders: headers,
    );
  }

  static Uri? _parseUrl(XmppElement? element) {
    if (element == null) {
      return null;
    }
    final attrUrl = element.getAttribute('url')?.value?.trim();
    if (attrUrl != null && attrUrl.isNotEmpty) {
      return Uri.tryParse(attrUrl);
    }
    final childUrl = element.getChild('url')?.textValue?.trim();
    if (childUrl != null && childUrl.isNotEmpty) {
      return Uri.tryParse(childUrl);
    }
    return null;
  }
}

bool discoInfoSupportsHttpUpload(IqStanza stanza) {
  if (stanza.type != IqStanzaType.RESULT) {
    return false;
  }
  final query = stanza.getChild('query');
  if (query == null || query.getAttribute('xmlns')?.value != 'http://jabber.org/protocol/disco#info') {
    return false;
  }
  for (final child in query.children) {
    if (child.name == 'feature' &&
        child.getAttribute('var')?.value == httpUploadNamespace) {
      return true;
    }
  }
  return false;
}
