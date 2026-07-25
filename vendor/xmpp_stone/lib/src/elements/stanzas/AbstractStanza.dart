import 'dart:math';
import 'dart:convert';

import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';

abstract class AbstractStanza extends XmppElement {
  String? _id;
  Jid? _fromJid;
  Jid? _toJid;

  Jid? get fromJid => _fromJid;

  set fromJid(Jid? value) {
    _fromJid = value;
    addAttribute(XmppAttribute('from', _fromJid!.fullJid));
  }

  Jid? get toJid => _toJid;

  set toJid(Jid? value) {
    _toJid = value;
    final jidValue = _toJid!.fullJid ?? _toJid!.userAtDomain;
    addAttribute(XmppAttribute('to', jidValue));
  }

  String? get id => _id;

  set id(String? value) {
    _id = value;
    addAttribute(XmppAttribute('id', _id));
  }

  static String getRandomId({int entropyBits = 96}) {
    final byteCount = (entropyBits / 8).ceil();
    final random = Random.secure();
    final bytes = List<int>.generate(byteCount, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }
}
