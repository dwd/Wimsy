import 'package:xmpp_stone/xmpp_stone.dart';

// XEP-0491: WebXDC. Lets peers share a WebXDC mini-app widget (a `.xdc`
// zip, media-type [webxdcMediaType]) attached to a message that carries a
// unique `<thread/>` id, and later send state updates in messages reusing
// that same `<thread/>`, carrying an `<x xmlns='urn:xmpp:webxdc:0'>` child.
const webxdcNamespace = 'urn:xmpp:webxdc:0';

// XEP-0335: JSON containers. Used by XEP-0491 to embed the arbitrary JSON
// payload of a widget update inside its `<x/>` element.
const webxdcJsonNamespace = 'urn:xmpp:json:0';

// XEP-0491: the media type of the `.xdc` file itself.
const webxdcMediaType = 'application/webxdc+zip';

// XEP-0491: the contents of an incoming `<x xmlns='urn:xmpp:webxdc:0'>`
// update element. All fields are optional - an entirely empty `<x/>` is
// valid and simply signals "this message is a widget update" without
// carrying any new state.
class WebxdcUpdatePayload {
  const WebxdcUpdatePayload({this.document, this.summary, this.json});

  // The widget's title, from `<document/>`.
  final String? document;

  // A short human-readable status text, from `<summary/>`.
  final String? summary;

  // The raw (unparsed) JSON text carried in
  // `<json xmlns='urn:xmpp:json:0'>`.
  final String? json;
}

// XEP-0491: builds the `<x xmlns='urn:xmpp:webxdc:0'>` element for a
// widget update. Always returns an element, even when every parameter is
// null/empty, since the spec requires an empty `<x/>` for info-only
// updates (where only the message `<body/>` carries new information).
XmppElement buildWebxdcUpdateElement({
  String? document,
  String? summary,
  String? json,
}) {
  final x = XmppElement()..name = 'x';
  x.addAttribute(XmppAttribute('xmlns', webxdcNamespace));
  final trimmedDocument = document?.trim();
  if (trimmedDocument != null && trimmedDocument.isNotEmpty) {
    final documentElement = XmppElement()..name = 'document';
    documentElement.textValue = trimmedDocument;
    x.addChild(documentElement);
  }
  final trimmedSummary = summary?.trim();
  if (trimmedSummary != null && trimmedSummary.isNotEmpty) {
    final summaryElement = XmppElement()..name = 'summary';
    summaryElement.textValue = trimmedSummary;
    x.addChild(summaryElement);
  }
  if (json != null && json.isNotEmpty) {
    final jsonElement = XmppElement()..name = 'json';
    jsonElement.addAttribute(XmppAttribute('xmlns', webxdcJsonNamespace));
    jsonElement.textValue = json;
    x.addChild(jsonElement);
  }
  return x;
}

// XEP-0491: the `selfAddr` property injected into the hosted widget. For
// occupant-id-capable (XEP-0421) group chats, this is the bare occupant-id
// itself (no URI scheme); otherwise it's an `xmpp:<bare jid>` URI.
String webxdcSelfAddr({required String bareJid, String? occupantId}) {
  if (occupantId != null && occupantId.isNotEmpty) {
    return occupantId;
  }
  return 'xmpp:$bareJid';
}

// XEP-0491: the `selfName` property injected into the hosted widget - a
// human-readable display name/nickname, or null if none is available.
String? webxdcSelfName({String? nickname}) {
  final trimmed = nickname?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}
