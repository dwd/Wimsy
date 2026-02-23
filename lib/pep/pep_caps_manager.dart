import 'package:xmpp_stone/xmpp_stone.dart';

import 'pep_manager.dart';

class PepCapsManager {
  PepCapsManager({
    required this.connection,
    required this.pepManager,
  });

  final Connection connection;
  final PepManager pepManager;

  final Map<String, Set<String>> _capsFeatures = {};
  final Map<String, Set<String>> _capsKeyBareJids = {};
  final Map<String, Set<String>> _bareJidFeatures = {};
  final Map<String, _PendingCapsQuery> _pendingQueries = {};

  void handleStanza(AbstractStanza stanza) {
    if (stanza is PresenceStanza) {
      _handlePresence(stanza);
    } else if (stanza is IqStanza) {
      _handleDiscoInfoResult(stanza);
    }
  }

  void _handlePresence(PresenceStanza stanza) {
    if (stanza.type == PresenceType.UNAVAILABLE) {
      return;
    }
    final caps = stanza.getChild('c');
    if (caps == null) {
      return;
    }
    final xmlns = caps.getAttribute('xmlns')?.value;
    if (xmlns != 'http://jabber.org/protocol/caps') {
      return;
    }
    final node = caps.getAttribute('node')?.value;
    final ver = caps.getAttribute('ver')?.value;
    if (node == null || ver == null) {
      return;
    }
    final capsKey = '$node#$ver';
    final fromJid = stanza.fromJid;
    if (fromJid == null) {
      return;
    }
    final bareJid = fromJid.userAtDomain;
    final features = _capsFeatures[capsKey];
    final bareKey = bareJid.toLowerCase();
    _capsKeyBareJids.putIfAbsent(capsKey, () => <String>{}).add(bareKey);
    if (features != null) {
      _recordFeaturesForBareJid(bareKey, features);
      if (!_supportsPepNotify(features)) {
        pepManager.requestMetadataIfMissing(bareJid);
      }
      return;
    }
    if (_pendingQueries.values.any((entry) => entry.capsKey == capsKey)) {
      return;
    }
    _sendDiscoInfoQuery(fromJid.fullJid ?? bareJid, capsKey, bareJid);
  }

  void _sendDiscoInfoQuery(String toFullJid, String capsKey, String bareJid) {
    final id = AbstractStanza.getRandomId();
    final iq = IqStanza(id, IqStanzaType.GET);
    iq.toJid = Jid.fromFullJid(toFullJid);
    final query = XmppElement()..name = 'query';
    query.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
    query.addAttribute(XmppAttribute('node', capsKey));
    iq.addChild(query);
    _pendingQueries[id] =
        _PendingCapsQuery(capsKey: capsKey, bareJid: bareJid.toLowerCase());
    connection.writeStanza(iq);
  }

  void _handleDiscoInfoResult(IqStanza stanza) {
    final pending = _pendingQueries.remove(stanza.id);
    if (pending == null) {
      return;
    }
    if (stanza.type != IqStanzaType.RESULT) {
      return;
    }
    final query = stanza.getChild('query');
    if (query == null || query.getAttribute('xmlns')?.value != 'http://jabber.org/protocol/disco#info') {
      return;
    }
    final features = <String>{};
    for (final child in query.children) {
      if (child.name == 'feature') {
        final value = child.getAttribute('var')?.value;
        if (value != null && value.isNotEmpty) {
          features.add(value);
        }
      }
    }
    _capsFeatures[pending.capsKey] = features;
    _recordFeaturesForBareJid(pending.bareJid, features);
    final linkedBareJids = _capsKeyBareJids[pending.capsKey];
    if (linkedBareJids != null) {
      for (final bareJid in linkedBareJids) {
        _recordFeaturesForBareJid(bareJid, features);
      }
    }
    if (!_supportsPepNotify(features)) {
      pepManager.requestMetadataIfMissing(pending.bareJid);
    }
  }

  Set<String>? featuresForBareJid(String bareJid) {
    final features = _bareJidFeatures[bareJid.toLowerCase()];
    if (features == null) {
      return null;
    }
    return Set.unmodifiable(features);
  }

  void _recordFeaturesForBareJid(String bareJid, Set<String> features) {
    final existing = _bareJidFeatures.putIfAbsent(bareJid, () => <String>{});
    existing.addAll(features);
  }

  bool _supportsPepNotify(Set<String> features) {
    return features.contains('urn:xmpp:avatar:metadata+notify');
  }
}

class _PendingCapsQuery {
  _PendingCapsQuery({required this.capsKey, required this.bareJid});

  final String capsKey;
  final String bareJid;
}
