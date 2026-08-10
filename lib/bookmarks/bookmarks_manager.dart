import 'package:xmpp_stone/xmpp_stone.dart';

import '../models/contact_entry.dart';
import '../models/muc_notify_settings.dart';
import '../xmpp/pep_publish.dart';

typedef BookmarkUpdateCallback = void Function(List<ContactEntry> bookmarks);

class BookmarksManager {
  BookmarksManager({
    required this.connection,
    required this.selfBareJid,
    required BookmarkUpdateCallback onUpdate,
  }) : _onUpdate = onUpdate;

  static const _bookmarksNode = 'urn:xmpp:bookmarks:1';
  static const _pubsubNs = 'http://jabber.org/protocol/pubsub';
  static const _pubsubEventNs = 'http://jabber.org/protocol/pubsub#event';

  final Connection connection;
  final String selfBareJid;
  final BookmarkUpdateCallback _onUpdate;

  final Map<String, ContactEntry> _bookmarksByJid = {};
  final Map<String, XmppElement> _bookmarkExtensionsByJid = {};
  String? _bookmarks2RequestId;
  String? _legacyRequestId;

  List<ContactEntry> get bookmarks => List.unmodifiable(_bookmarksByJid.values);

  void seedBookmarks(List<ContactEntry> bookmarks) {
    var updated = false;
    for (final entry in bookmarks) {
      final bookmark = entry.isBookmark ? entry : entry.copyWith(isBookmark: true);
      if (_bookmarksByJid[bookmark.jid] != bookmark) {
        _bookmarksByJid[bookmark.jid] = bookmark;
        updated = true;
      }
    }
    if (updated) {
      _onUpdate(this.bookmarks);
    }
  }

  void requestBookmarks() {
    final id = AbstractStanza.getRandomId();
    _bookmarks2RequestId = id;
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(selfBareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(XmppAttribute('xmlns', _pubsubNs));
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', _bookmarksNode));
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
  }

  void subscribeToBookmarks() {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    iqStanza.toJid = Jid.fromFullJid(selfBareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(XmppAttribute('xmlns', _pubsubNs));
    final subscribe = XmppElement()..name = 'subscribe';
    subscribe.addAttribute(XmppAttribute('node', _bookmarksNode));
    subscribe.addAttribute(XmppAttribute('jid', selfBareJid));
    pubsub.addChild(subscribe);
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

  void clearCache() {
    _bookmarksByJid.clear();
    _bookmarkExtensionsByJid.clear();
    _onUpdate(bookmarks);
  }

  Future<void> upsertBookmark(ContactEntry bookmark) async {
    final entry = bookmark.copyWith(isBookmark: true);
    _bookmarksByJid[entry.jid] = entry;
    _setNotifyExtension(entry.jid, entry.effectiveMucNotifySettings);
    _onUpdate(bookmarks);
    await _publishBookmark(entry);
    await _storeLegacyBookmarks();
  }

  Future<void> removeBookmark(String roomJid) async {
    if (_bookmarksByJid.remove(roomJid) != null) {
      _onUpdate(bookmarks);
    }
    _bookmarkExtensionsByJid.remove(roomJid);
    await _retractBookmark(roomJid);
    await _storeLegacyBookmarks();
  }

  /// Updates the MUC notification settings for [roomJid] and republishes the
  /// bookmark (preserving any other vendor extensions already present).
  Future<void> setMucNotifySettings(
    String roomJid,
    MucNotifySettings settings,
  ) async {
    final existing = _bookmarksByJid[roomJid];
    if (existing == null) {
      return;
    }
    final updated = existing.copyWith(mucNotifySettings: settings);
    _bookmarksByJid[roomJid] = updated;
    _setNotifyExtension(roomJid, settings);
    _onUpdate(bookmarks);
    await _publishBookmark(updated);
    await _storeLegacyBookmarks();
  }

  void _setNotifyExtension(String roomJid, MucNotifySettings settings) {
    final existing = _bookmarkExtensionsByJid[roomJid];
    final extensions = existing != null
        ? _cloneElement(existing)
        : (XmppElement()..name = 'extensions');
    extensions.children.removeWhere(
      (child) =>
          child.name == MucNotifySettings.elementName &&
          child.getAttribute('xmlns')?.value == MucNotifySettings.namespace,
    );
    if (settings != MucNotifySettings.defaultSettings) {
      extensions.addChild(settings.toXml());
    }
    if (extensions.children.isEmpty) {
      _bookmarkExtensionsByJid.remove(roomJid);
    } else {
      _bookmarkExtensionsByJid[roomJid] = extensions;
    }
  }

  void _handleEventMessage(MessageStanza stanza) {
    final event = stanza.children.firstWhere(
      (child) => child.name == 'event' && child.getAttribute('xmlns')?.value == _pubsubEventNs,
      orElse: () => XmppElement(),
    );
    if (event.name != 'event') {
      return;
    }
    final items = event.getChild('items');
    if (items == null || items.getAttribute('node')?.value != _bookmarksNode) {
      return;
    }

    final newBookmarks = _parseBookmarks(items);
    var updated = false;
    for (final bookmark in newBookmarks) {
      _bookmarksByJid[bookmark.jid] = bookmark;
      updated = true;
    }

    final retracts = items.children.where((child) => child.name == 'retract');
    for (final retract in retracts) {
      final id = retract.getAttribute('id')?.value;
      if (id != null && id.isNotEmpty) {
        if (_bookmarksByJid.remove(id) != null) {
          updated = true;
        }
      }
    }

    if (updated) {
      _onUpdate(bookmarks);
    }
  }

  void _handleIqResult(IqStanza stanza) {
    if (stanza.type == IqStanzaType.ERROR) {
      _handleIqError(stanza);
      return;
    }
    if (stanza.type != IqStanzaType.RESULT) {
      return;
    }
    if (_legacyRequestId != null && stanza.id == _legacyRequestId) {
      _handleLegacyResult(stanza);
      return;
    }
    final pubsub = stanza.getChild('pubsub');
    if (pubsub == null || pubsub.getAttribute('xmlns')?.value != _pubsubNs) {
      return;
    }
    final items = pubsub.getChild('items');
    if (items == null || items.getAttribute('node')?.value != _bookmarksNode) {
      return;
    }

    final parsed = _parseBookmarks(items);
    if (parsed.isEmpty) {
      return;
    }
    for (final entry in parsed) {
      _bookmarksByJid[entry.jid] = entry;
    }
    _onUpdate(bookmarks);
  }

  void _handleIqError(IqStanza stanza) {
    if (_bookmarks2RequestId == null || stanza.id != _bookmarks2RequestId) {
      return;
    }
    final error = stanza.getChild('error');
    final isMissing = error?.children.any((child) =>
            child.name == 'item-not-found' ||
            child.name == 'remote-server-not-found' ||
            child.name == 'server-not-found') ??
        false;
    if (isMissing) {
      _requestLegacyBookmarks();
    }
  }

  void _requestLegacyBookmarks() {
    final id = AbstractStanza.getRandomId();
    _legacyRequestId = id;
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    final query = XmppElement()..name = 'query';
    query.addAttribute(XmppAttribute('xmlns', 'jabber:iq:private'));
    final storage = XmppElement()..name = 'storage';
    storage.addAttribute(XmppAttribute('xmlns', 'storage:bookmarks'));
    query.addChild(storage);
    iqStanza.addChild(query);
    connection.writeStanza(iqStanza);
  }

  void _handleLegacyResult(IqStanza stanza) {
    final query = stanza.getChild('query');
    if (query == null || query.getAttribute('xmlns')?.value != 'jabber:iq:private') {
      return;
    }
    final storage = query.getChild('storage');
    if (storage == null || storage.getAttribute('xmlns')?.value != 'storage:bookmarks') {
      return;
    }
    final parsed = _parseLegacyBookmarks(storage);
    if (parsed.isEmpty) {
      return;
    }
    for (final entry in parsed) {
      _bookmarksByJid[entry.jid] = entry;
    }
    _onUpdate(bookmarks);
  }

  List<ContactEntry> _parseBookmarks(XmppElement items) {
    final result = <ContactEntry>[];
    final itemElements = items.children.where((child) => child.name == 'item');
    for (final item in itemElements) {
      result.addAll(_parseBookmarkPayload(item));
    }
    return result;
  }

  List<ContactEntry> _parseBookmarkPayload(XmppElement item) {
    final result = <ContactEntry>[];
    for (final child in item.children) {
      if (child.name == 'conference' &&
          (child.getAttribute('xmlns')?.value == null ||
              child.getAttribute('xmlns')?.value == _bookmarksNode)) {
        final bookmark = _conferenceToBookmark(child);
        if (bookmark != null) {
          _captureExtensions(bookmark.jid, child);
          result.add(bookmark);
        }
      } else if (child.name == 'storage' && child.getAttribute('xmlns')?.value == _bookmarksNode) {
        for (final conference in child.children.where((element) => element.name == 'conference')) {
          final bookmark = _conferenceToBookmark(conference);
          if (bookmark != null) {
            _captureExtensions(bookmark.jid, conference);
            result.add(bookmark);
          }
        }
      }
    }
    return result;
  }

  ContactEntry? _conferenceToBookmark(XmppElement conference) {
    final jid = conference.getAttribute('jid')?.value?.trim() ?? '';
    if (jid.isEmpty) {
      return null;
    }
    final name = conference.getAttribute('name')?.value?.trim();
    final autoJoinAttr = conference.getAttribute('autojoin')?.value?.trim() ?? '';
    final autoJoin = autoJoinAttr == 'true' || autoJoinAttr == '1';
    final nick = conference.getChild('nick')?.textValue?.trim();
    final password = conference.getChild('password')?.textValue?.trim();
    final mucNotifySettings = MucNotifySettings.fromExtensions(
      conference.getChild('extensions'),
    );
    return ContactEntry(
      jid: jid,
      name: name?.isNotEmpty == true ? name : null,
      groups: const [],
      isBookmark: true,
      bookmarkNick: nick?.isNotEmpty == true ? nick : null,
      bookmarkPassword: password?.isNotEmpty == true ? password : null,
      bookmarkAutoJoin: autoJoin,
      mucNotifySettings: mucNotifySettings,
    );
  }

  List<ContactEntry> _parseLegacyBookmarks(XmppElement storage) {
    final result = <ContactEntry>[];
    for (final conference in storage.children.where((child) => child.name == 'conference')) {
      final jid = conference.getAttribute('jid')?.value?.trim() ?? '';
      if (jid.isEmpty) {
        continue;
      }
      final name = conference.getAttribute('name')?.value?.trim();
      final autoJoinAttr = conference.getAttribute('autojoin')?.value?.trim() ?? '';
      var autoJoin = autoJoinAttr == 'true' || autoJoinAttr == '1';
      final autoJoinChild = conference.getChild('autojoin')?.textValue?.trim();
      if (autoJoinChild != null && autoJoinChild.isNotEmpty) {
        autoJoin = autoJoinChild == 'true' || autoJoinChild == '1';
      }
      final nick = conference.getChild('nick')?.textValue?.trim();
      final password = conference.getChild('password')?.textValue?.trim();
      result.add(ContactEntry(
        jid: jid,
        name: name?.isNotEmpty == true ? name : null,
        groups: const [],
        isBookmark: true,
        bookmarkNick: nick?.isNotEmpty == true ? nick : null,
        bookmarkPassword: password?.isNotEmpty == true ? password : null,
        bookmarkAutoJoin: autoJoin,
      ));
    }
    return result;
  }

  Future<void> _publishBookmark(ContactEntry bookmark) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    iqStanza.toJid = Jid.fromFullJid(selfBareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(XmppAttribute('xmlns', _pubsubNs));
    final publish = XmppElement()..name = 'publish';
    publish.addAttribute(XmppAttribute('node', _bookmarksNode));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', bookmark.jid));
    item.addChild(_buildConference(bookmark));
    publish.addChild(item);
    pubsub.addChild(publish);
    pubsub.addChild(buildPrivatePepPublishOptions());
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
  }

  Future<void> _retractBookmark(String roomJid) async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    iqStanza.toJid = Jid.fromFullJid(selfBareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(XmppAttribute('xmlns', _pubsubNs));
    final retract = XmppElement()..name = 'retract';
    retract.addAttribute(XmppAttribute('node', _bookmarksNode));
    retract.addAttribute(XmppAttribute('notify', 'true'));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', roomJid));
    retract.addChild(item);
    pubsub.addChild(retract);
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
  }

  Future<void> _storeLegacyBookmarks() async {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    final query = XmppElement()..name = 'query';
    query.addAttribute(XmppAttribute('xmlns', 'jabber:iq:private'));
    final storage = XmppElement()..name = 'storage';
    storage.addAttribute(XmppAttribute('xmlns', 'storage:bookmarks'));
    for (final entry in _bookmarksByJid.values) {
      storage.addChild(_buildConference(entry, includeXmlns: false));
    }
    query.addChild(storage);
    iqStanza.addChild(query);
    connection.writeStanza(iqStanza);
  }

  XmppElement _buildConference(ContactEntry bookmark, {bool includeXmlns = true}) {
    final conference = XmppElement()..name = 'conference';
    if (includeXmlns) {
      conference.addAttribute(XmppAttribute('xmlns', _bookmarksNode));
    }
    conference.addAttribute(XmppAttribute('jid', bookmark.jid));
    if (bookmark.name != null && bookmark.name!.trim().isNotEmpty) {
      conference.addAttribute(XmppAttribute('name', bookmark.name!.trim()));
    }
    conference.addAttribute(
      XmppAttribute('autojoin', bookmark.bookmarkAutoJoin ? 'true' : 'false'),
    );
    if (bookmark.bookmarkNick != null && bookmark.bookmarkNick!.trim().isNotEmpty) {
      final nick = XmppElement()..name = 'nick';
      nick.textValue = bookmark.bookmarkNick!.trim();
      conference.addChild(nick);
    }
    if (bookmark.bookmarkPassword != null &&
        bookmark.bookmarkPassword!.trim().isNotEmpty) {
      final password = XmppElement()..name = 'password';
      password.textValue = bookmark.bookmarkPassword!.trim();
      conference.addChild(password);
    }
    final extensions = _bookmarkExtensionsByJid[bookmark.jid];
    if (extensions != null && extensions.children.isNotEmpty) {
      conference.addChild(_cloneElement(extensions));
    }
    return conference;
  }

  void _captureExtensions(String jid, XmppElement conference) {
    final extensions = conference.getChild('extensions');
    if (extensions == null || extensions.children.isEmpty) {
      _bookmarkExtensionsByJid.remove(jid);
      return;
    }
    final cloned = _cloneElement(extensions);
    _bookmarkExtensionsByJid[jid] = cloned;
  }

  XmppElement _cloneElement(XmppElement element) {
    final clone = XmppElement()
      ..name = element.name
      ..textValue = element.textValue;
    for (final attr in element.attributes) {
      clone.addAttribute(XmppAttribute(attr.name, attr.value));
    }
    for (final child in element.children) {
      clone.addChild(_cloneElement(child));
    }
    return clone;
  }
}
