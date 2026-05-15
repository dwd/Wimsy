// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html';
import 'alt_connection_parser.dart';

Future<Uri?> discoverWebSocketEndpoint(String domain) async {
  final jsonUri = 'https://$domain/.well-known/host-meta.json';
  final jsonResult = await _fetch(jsonUri);
  if (jsonResult != null) {
    final parsed = parseHostMetaJson(jsonResult);
    if (parsed != null) {
      return parsed;
    }
  }
  final xmlUri = 'https://$domain/.well-known/host-meta';
  final xmlResult = await _fetch(xmlUri);
  if (xmlResult != null) {
    return parseHostMetaXml(xmlResult);
  }
  return null;
}

Future<Uri?> discoverWebTransportEndpoint(String domain) async {
  final jsonUri = 'https://$domain/.well-known/host-meta.json';
  final jsonResult = await _fetch(jsonUri);
  if (jsonResult != null) {
    final parsed = parseHostMetaWebTransportJson(jsonResult);
    if (parsed != null) {
      return parsed;
    }
  }
  final xmlUri = 'https://$domain/.well-known/host-meta';
  final xmlResult = await _fetch(xmlUri);
  if (xmlResult != null) {
    return parseHostMetaWebTransportXml(xmlResult);
  }
  return null;
}

Future<String?> _fetch(String uri) async {
  try {
    final request = await HttpRequest.request(
      uri,
      method: 'GET',
      requestHeaders: {
        'Accept': 'application/xrd+xml, application/json',
      },
    );
    if (request.status != 200) {
      return null;
    }
    return request.responseText;
  } catch (_) {
    return null;
  }
}
