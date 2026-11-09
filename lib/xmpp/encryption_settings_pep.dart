/// Syncs the global encryption-policy settings and the per-contact
/// encryption-protocol choices (see `lib/encryption/encryption_manager.dart`)
/// across a user's devices via two private PEP (Personal Eventing Protocol)
/// nodes, mirroring the pattern used by `BookmarksManager`
/// (`lib/bookmarks/bookmarks_manager.dart`):
///
///   - [globalSettingsNode] (`urn:wimsy:encryption:settings:0`): one item
///     per global setting (the default policy, plus one enable/disable flag
///     per cryptosystem), each item's `id` being the setting's key and its
///     payload a `<value/>` element.
///   - [contactSettingsNode] (`urn:wimsy:encryption:contacts:0`): one item
///     per contact with an explicit protocol choice, the item's `id` being
///     the contact's bare JID and its payload a `<protocol/>` element
///     naming the chosen protocol id (or `'none'`).
library;

import 'package:xmpp_stone/xmpp_stone.dart';

import 'pep_publish.dart';

/// Callback invoked whenever a global setting or a per-contact protocol
/// choice changes as a result of a PEP event/fetch from another device.
typedef EncryptionSettingsUpdateCallback = void Function();

class EncryptionSettingsPep {
  EncryptionSettingsPep({
    required this.connection,
    required this.selfBareJid,
    required EncryptionSettingsUpdateCallback onRemoteUpdate,
  }) : _onRemoteUpdate = onRemoteUpdate;

  static const globalSettingsNode = 'urn:wimsy:encryption:settings:0';
  static const contactSettingsNode = 'urn:wimsy:encryption:contacts:0';
  static const _pubsubNs = 'http://jabber.org/protocol/pubsub';
  static const _pubsubEventNs = 'http://jabber.org/protocol/pubsub#event';

  final Connection connection;
  final String selfBareJid;
  final EncryptionSettingsUpdateCallback _onRemoteUpdate;

  /// Setting id (e.g. `'defaultPolicy'`, `'omemo2Enabled'`) -> value.
  final Map<String, String> _globalItems = {};

  /// Bare JID -> chosen protocol id (or `'none'`).
  final Map<String, String> _contactItems = {};

  Set<String>? _globalSupportedConfigFields;
  Set<String>? _contactSupportedConfigFields;

  Map<String, String> get globalItems => Map.unmodifiable(_globalItems);
  Map<String, String> get contactItems => Map.unmodifiable(_contactItems);

  void requestGlobalSettings() => _requestItems(globalSettingsNode);

  void requestContactSettings() => _requestItems(contactSettingsNode);

  void _requestItems(String node) {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(selfBareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(XmppAttribute('xmlns', _pubsubNs));
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', node));
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
  }

  void handleStanza(AbstractStanza stanza) {
    if (stanza is MessageStanza) {
      _handleEventMessage(stanza);
    } else if (stanza is IqStanza) {
      _handleIqResult(stanza);
    }
  }

  void _handleEventMessage(MessageStanza stanza) {
    final globalFields = extractConfigFieldsFromConfigurationEvent(
      stanza,
      globalSettingsNode,
    );
    if (globalFields != null) {
      _globalSupportedConfigFields = globalFields;
    }
    final contactFields = extractConfigFieldsFromConfigurationEvent(
      stanza,
      contactSettingsNode,
    );
    if (contactFields != null) {
      _contactSupportedConfigFields = contactFields;
    }

    final event = stanza.children.firstWhere(
      (child) =>
          child.name == 'event' &&
          child.getAttribute('xmlns')?.value == _pubsubEventNs,
      orElse: () => XmppElement(),
    );
    if (event.name != 'event') {
      return;
    }
    final items = event.getChild('items');
    final node = items?.getAttribute('node')?.value;
    if (items == null || node == null) {
      return;
    }
    if (node == globalSettingsNode) {
      if (_applyGlobalItems(items)) {
        _onRemoteUpdate();
      }
    } else if (node == contactSettingsNode) {
      if (_applyContactItems(items)) {
        _onRemoteUpdate();
      }
    }
  }

  void _handleIqResult(IqStanza stanza) {
    if (stanza.type != IqStanzaType.RESULT) {
      return;
    }
    final pubsub = stanza.getChild('pubsub');
    if (pubsub == null || pubsub.getAttribute('xmlns')?.value != _pubsubNs) {
      return;
    }
    final items = pubsub.getChild('items');
    final node = items?.getAttribute('node')?.value;
    if (items == null || node == null) {
      return;
    }
    var updated = false;
    if (node == globalSettingsNode) {
      updated = _applyGlobalItems(items);
    } else if (node == contactSettingsNode) {
      updated = _applyContactItems(items);
    }
    if (updated) {
      _onRemoteUpdate();
    }
  }

  bool _applyGlobalItems(XmppElement items) {
    var updated = false;
    for (final item in items.children.where((c) => c.name == 'item')) {
      final id = item.getAttribute('id')?.value;
      final value = item.getChild('value')?.textValue;
      if (id == null || id.isEmpty || value == null) {
        continue;
      }
      if (_globalItems[id] != value) {
        _globalItems[id] = value;
        updated = true;
      }
    }
    for (final retract in items.children.where((c) => c.name == 'retract')) {
      final id = retract.getAttribute('id')?.value;
      if (id != null && _globalItems.remove(id) != null) {
        updated = true;
      }
    }
    return updated;
  }

  bool _applyContactItems(XmppElement items) {
    var updated = false;
    for (final item in items.children.where((c) => c.name == 'item')) {
      final bareJid = item.getAttribute('id')?.value;
      final protocol = item.getChild('protocol')?.textValue;
      if (bareJid == null || bareJid.isEmpty || protocol == null) {
        continue;
      }
      if (_contactItems[bareJid] != protocol) {
        _contactItems[bareJid] = protocol;
        updated = true;
      }
    }
    for (final retract in items.children.where((c) => c.name == 'retract')) {
      final bareJid = retract.getAttribute('id')?.value;
      if (bareJid != null && _contactItems.remove(bareJid) != null) {
        updated = true;
      }
    }
    return updated;
  }

  /// Publishes [value] for global setting [id] (e.g. the default policy, or
  /// a cryptosystem's enable flag) to [globalSettingsNode].
  Future<bool> publishGlobalSetting(String id, String value) async {
    _globalItems[id] = value;
    final valueElement = XmppElement()..name = 'value';
    valueElement.textValue = value;
    return publishToPrivatePepNodeWithRetry(
      connection: connection,
      publishIqBuilder: () => buildPrivatePepPublishIq(
        node: globalSettingsNode,
        itemId: id,
        payload: valueElement,
        selfBareJid: selfBareJid,
        serverSupportsConfigNodeMax: _serverSupportsConfigNodeMax(),
        supportedConfigFields: _globalSupportedConfigFields,
      ),
      node: globalSettingsNode,
      selfBareJid: selfBareJid,
      serverSupportsConfigNodeMax: _serverSupportsConfigNodeMax(),
      supportedConfigFields: _globalSupportedConfigFields,
      onWarning: (message) =>
          Log.w('EncryptionSettingsPep', 'Global setting $id: $message'),
    );
  }

  /// Publishes [protocolId] (or `'none'`) as [bareJid]'s chosen encryption
  /// protocol to [contactSettingsNode].
  Future<bool> publishContactProtocol(String bareJid, String protocolId) async {
    _contactItems[bareJid] = protocolId;
    final protocolElement = XmppElement()..name = 'protocol';
    protocolElement.textValue = protocolId;
    return publishToPrivatePepNodeWithRetry(
      connection: connection,
      publishIqBuilder: () => buildPrivatePepPublishIq(
        node: contactSettingsNode,
        itemId: bareJid,
        payload: protocolElement,
        selfBareJid: selfBareJid,
        serverSupportsConfigNodeMax: _serverSupportsConfigNodeMax(),
        supportedConfigFields: _contactSupportedConfigFields,
      ),
      node: contactSettingsNode,
      selfBareJid: selfBareJid,
      serverSupportsConfigNodeMax: _serverSupportsConfigNodeMax(),
      supportedConfigFields: _contactSupportedConfigFields,
      onWarning: (message) => Log.w(
        'EncryptionSettingsPep',
        'Contact protocol for $bareJid: $message',
      ),
    );
  }

  bool _serverSupportsConfigNodeMax() {
    return connection
        .getSupportedFeatures()
        .any((feature) => feature.xmppVar == pubsubConfigNodeMaxFeature);
  }

  void clearCache() {
    _globalItems.clear();
    _contactItems.clear();
  }
}
