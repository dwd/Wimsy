/// Shared XMPP multi-stream routing helpers for QUIC and WebTransport.

/// Returns true when [payload] begins with a top-level XMPP stanza element.
bool isStanzaPayload(String payload) {
  var index = 0;
  while (index < payload.length) {
    final character = payload.codeUnitAt(index);
    if (character == 0x20 ||
        character == 0x09 ||
        character == 0x0a ||
        character == 0x0d) {
      index++;
      continue;
    }
    if (character != 0x3c) return false;
    if (index + 1 < payload.length && payload.codeUnitAt(index + 1) == 0x3f) {
      final prologEnd = payload.indexOf('?>', index + 2);
      if (prologEnd < 0) return false;
      index = prologEnd + 2;
      continue;
    }
    final nameStart = index + 1;
    var nameEnd = nameStart;
    while (nameEnd < payload.length) {
      final current = payload.codeUnitAt(nameEnd);
      if (current == 0x20 ||
          current == 0x09 ||
          current == 0x0a ||
          current == 0x0d ||
          current == 0x2f ||
          current == 0x3e) {
        break;
      }
      nameEnd++;
    }
    final name = payload.substring(nameStart, nameEnd);
    return name == 'message' || name == 'presence' || name == 'iq';
  }
  return false;
}

String? extractToBareJidForRouting(String payload) {
  final match = RegExp('\\bto=(["\\\'])([^"\\\']+)\\1').firstMatch(payload);
  return match == null ? null : bareJidForRouting(match.group(2));
}

String? bareJidForRouting(String? jid) {
  final trimmed = jid?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final slash = trimmed.indexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(0, slash);
}

int xmppAuxSlotForBareJid(String bareJid, int slotCount) {
  if (slotCount <= 0) {
    throw ArgumentError.value(slotCount, 'slotCount', 'must be > 0');
  }
  var hash = 0x811c9dc5;
  for (final unit in bareJid.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash % slotCount;
}

/// Extracts the account bare JID from legacy bind or Bind 2 success XML.
String? extractBoundBareJid(String xml) {
  final legacy = RegExp(
    '<bind\\b[^>]*xmlns=(["\\\'])urn:ietf:params:xml:ns:xmpp-bind\\1[^>]*>.*?<jid>([^<]+)</jid>',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(xml);
  final bind2 = RegExp(
    '<bound\\b[^>]*xmlns=(["\\\'])urn:xmpp:bind:0\\1[^>]*>.*?<jid>([^<]+)</jid>',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(xml);
  return bareJidForRouting((legacy ?? bind2)?.group(2));
}
