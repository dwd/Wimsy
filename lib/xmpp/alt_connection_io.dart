import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'alt_connection_parser.dart';

Future<Uri?> discoverWebSocketEndpoint(String domain) async {
  final https = Uri.parse('https://$domain/.well-known/host-meta.json');
  final jsonResult = await _fetch(https);
  if (jsonResult != null) {
    final parsed = parseHostMetaJson(jsonResult);
    if (parsed != null) {
      return parsed;
    }
  }
  final xmlUri = Uri.parse('https://$domain/.well-known/host-meta');
  final xmlResult = await _fetch(xmlUri);
  if (xmlResult != null) {
    return parseHostMetaXml(xmlResult);
  }
  return null;
}

Future<Uri?> discoverWebTransportEndpoint(String domain) async {
  final https = Uri.parse('https://$domain/.well-known/host-meta.json');
  final jsonResult = await _fetch(https);
  if (jsonResult != null) {
    final parsed = parseHostMetaWebTransportJson(jsonResult);
    if (parsed != null) {
      return parsed;
    }
  }
  final xmlUri = Uri.parse('https://$domain/.well-known/host-meta');
  final xmlResult = await _fetch(xmlUri);
  if (xmlResult != null) {
    return parseHostMetaWebTransportXml(xmlResult);
  }
  return null;
}

Future<String?> _fetch(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.followRedirects = true;
    request.headers.set('Accept', 'application/xrd+xml, application/json');
    final response = await request.close();
    if (response.statusCode != 200) {
      return null;
    }
    return await response.transform(const Utf8Decoder()).join();
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}
