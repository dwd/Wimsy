import 'dart:convert';
import 'dart:typed_data';

import 'package:xmpp_stone/xmpp_stone.dart';

import '../models/avatar_metadata.dart';
import '../storage/storage_service.dart';

typedef PepUpdateCallback = void Function();

class PepManager {
  PepManager({
    required this.connection,
    required this.storage,
    required this.selfBareJid,
    required PepUpdateCallback onUpdate,
    this.allowAvatarFetch = _alwaysAllowAvatarFetch,
  }) : _onUpdate = onUpdate {
    _metadataByJid.addAll(storage.loadAvatarMetadata());
    _avatarBlobs.addAll(storage.loadAvatarBlobs());
    // R3.1: drop any cached blobs whose hash isn't referenced by any
    // current metadata entry. This keeps the on-disk avatar store from
    // growing unbounded over the lifetime of the app as contacts rotate
    // their avatars.
    gcUnreferencedAvatarBlobs();
  }

  final Connection connection;
  final StorageService storage;
  final String selfBareJid;
  final PepUpdateCallback _onUpdate;
  final bool Function() allowAvatarFetch;

  static bool _alwaysAllowAvatarFetch() => true;

  final Map<String, AvatarMetadata> _metadataByJid = {};
  final Map<String, String> _avatarBlobs = {};
  final Map<String, _PendingAvatarData> _pendingDataRequests = {};
  // R3.3: track outstanding `urn:xmpp:avatar:metadata` GET IQs so we can
  // observe `<error/>` responses (e.g. `item-not-found`) and persist a
  // negative-cache sentinel for that JID.
  final Map<String, String> _pendingMetadataRequests = {};

  Uint8List? avatarBytesFor(String bareJid) {
    final meta = _metadataByJid[bareJid];
    if (meta == null) {
      return null;
    }
    if (meta.isNoPepAvatar) {
      return null;
    }
    final base64Data = _avatarBlobs[meta.hash];
    if (base64Data == null) {
      return null;
    }
    try {
      return base64Decode(base64Data);
    } catch (_) {
      return null;
    }
  }

  bool hasAvatarMetadata(String bareJid) {
    return _metadataByJid.containsKey(bareJid);
  }

  String? avatarHashFor(String bareJid) {
    final meta = _metadataByJid[bareJid];
    if (meta == null || meta.isNoPepAvatar) {
      return null;
    }
    return meta.hash;
  }

  /// True iff we have a persisted negative-cache marker for this JID. R3.3.
  bool isKnownToHaveNoPepAvatar(String bareJid) {
    return _metadataByJid[bareJid]?.isNoPepAvatar ?? false;
  }

  void subscribeToAvatarMetadata(String bareJid) {
    _sendSubscribe(bareJid);
  }

  void requestMetadataIfMissing(String bareJid) {
    if (!allowAvatarFetch()) return;
    final metadata = _metadataByJid[bareJid];
    if (metadata != null) {
      if (!metadata.isNoPepAvatar) {
        requestAvatarData(bareJid, metadata.hash);
      }
      return;
    }
    _requestMetadata(bareJid);
  }

  String? requestAvatarData(String bareJid, String hash) {
    if (!allowAvatarFetch()) return null;
    if (_avatarBlobs.containsKey(hash)) {
      return null;
    }
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(bareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', 'urn:xmpp:avatar:data'));
    final item = XmppElement()..name = 'item';
    item.addAttribute(XmppAttribute('id', hash));
    items.addChild(item);
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    _pendingDataRequests[id] = _PendingAvatarData(bareJid: bareJid, hash: hash);
    connection.writeStanza(iqStanza);
    return id;
  }

  void handleStanza(AbstractStanza stanza) {
    if (stanza is MessageStanza) {
      _handleEventMessage(stanza);
    } else if (stanza is IqStanza) {
      _handleIqResult(stanza);
    }
  }

  void clearCache() {
    _metadataByJid.clear();
    _avatarBlobs.clear();
    _pendingDataRequests.clear();
    _pendingMetadataRequests.clear();
    _onUpdate();
  }

  /// Removes PEP avatar state belonging to a contact that was forgotten.
  void removeContact(String bareJid) {
    _metadataByJid.remove(bareJid);
    _pendingMetadataRequests.removeWhere((_, jid) => jid == bareJid);
    _pendingDataRequests.removeWhere(
      (_, pending) => pending.bareJid == bareJid,
    );
    storage.removeAvatarMetadata(bareJid);
    gcUnreferencedAvatarBlobs();
    _onUpdate();
  }

  /// R3.1: drop any cached avatar blob whose hash is not referenced by a
  /// current (non-sentinel) `_metadataByJid` entry. Keeps `_avatarBlobs`
  /// and the persisted blob store from leaking when contacts rotate
  /// avatars over the lifetime of the install.
  ///
  /// Returns the number of blobs evicted (helpful for tests and a future
  /// telemetry hook). Calling this is safe at any time; in particular it
  /// is invoked once from the constructor right after the on-disk seeds
  /// are loaded.
  int gcUnreferencedAvatarBlobs() {
    if (_avatarBlobs.isEmpty) {
      return 0;
    }
    final referenced = <String>{
      for (final meta in _metadataByJid.values)
        if (!meta.isNoPepAvatar && meta.hash.isNotEmpty) meta.hash,
    };
    final toRemove = <String>[
      for (final hash in _avatarBlobs.keys)
        if (!referenced.contains(hash)) hash,
    ];
    if (toRemove.isEmpty) {
      return 0;
    }
    for (final hash in toRemove) {
      _avatarBlobs.remove(hash);
    }
    storage.replaceAvatarBlobs(_avatarBlobs);
    return toRemove.length;
  }

  void _sendSubscribe(String bareJid) {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.SET);
    iqStanza.toJid = Jid.fromFullJid(bareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final subscribe = XmppElement()..name = 'subscribe';
    subscribe.addAttribute(XmppAttribute('node', 'urn:xmpp:avatar:metadata'));
    subscribe.addAttribute(XmppAttribute('jid', selfBareJid));
    pubsub.addChild(subscribe);
    iqStanza.addChild(pubsub);
    connection.writeStanza(iqStanza);
  }

  void _requestMetadata(String bareJid) {
    final id = AbstractStanza.getRandomId();
    final iqStanza = IqStanza(id, IqStanzaType.GET);
    iqStanza.toJid = Jid.fromFullJid(bareJid);
    final pubsub = XmppElement()..name = 'pubsub';
    pubsub.addAttribute(
      XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
    );
    final items = XmppElement()..name = 'items';
    items.addAttribute(XmppAttribute('node', 'urn:xmpp:avatar:metadata'));
    items.addAttribute(XmppAttribute('max_items', '1'));
    pubsub.addChild(items);
    iqStanza.addChild(pubsub);
    // R3.3: remember which JID this IQ asked about so we can persist a
    // negative-cache sentinel if the response is an error.
    _pendingMetadataRequests[id] = bareJid;
    connection.writeStanza(iqStanza);
  }

  void _handleEventMessage(MessageStanza stanza) {
    final event = stanza.children.firstWhere(
      (child) =>
          child.name == 'event' &&
          child.getAttribute('xmlns')?.value ==
              'http://jabber.org/protocol/pubsub#event',
      orElse: () => XmppElement(),
    );
    if (event.name != 'event') {
      return;
    }
    final items = event.getChild('items');
    if (items == null) {
      return;
    }
    final node = items.getAttribute('node')?.value;
    if (node != 'urn:xmpp:avatar:metadata') {
      return;
    }
    final item = items.getChild('item');
    if (item == null) {
      return;
    }
    final hash = item.getAttribute('id')?.value;
    final metadata = item.children.firstWhere(
      (child) =>
          child.name == 'metadata' &&
          child.getAttribute('xmlns')?.value == 'urn:xmpp:avatar:metadata',
      orElse: () => XmppElement(),
    );
    if (metadata.name != 'metadata') {
      return;
    }
    final info = metadata.getChild('info');
    final mimeType = info?.getAttribute('type')?.value ?? '';
    final bytesRaw = info?.getAttribute('bytes')?.value ?? '';
    final hashValue = info?.getAttribute('id')?.value ?? hash ?? '';
    final bytes = int.tryParse(bytesRaw) ?? 0;
    if (hashValue.isEmpty || mimeType.isEmpty || bytes == 0) {
      return;
    }
    final from = stanza.fromJid?.userAtDomain ?? '';
    if (from.isEmpty) {
      return;
    }
    final metadataEntry = AvatarMetadata(
      hash: hashValue,
      mimeType: mimeType,
      bytes: bytes,
      updatedAt: DateTime.now(),
    );
    _metadataByJid[from] = metadataEntry;
    storage.storeAvatarMetadata(from, metadataEntry);
    if (!_avatarBlobs.containsKey(hashValue)) {
      requestAvatarData(from, hashValue);
    }
    _onUpdate();
  }

  void _handleIqResult(IqStanza stanza) {
    // R3.3: handle metadata-IQ responses first. A non-result (typically
    // `<error type="cancel"><item-not-found/>`) means the JID has no PEP
    // avatar; record a negative-cache sentinel that survives restarts.
    final pendingMetadata = _pendingMetadataRequests.remove(stanza.id);
    if (pendingMetadata != null) {
      if (stanza.type != IqStanzaType.RESULT) {
        // Don't overwrite a real metadata entry that may have arrived via a
        // PubSub event in between. Only stamp the sentinel when we have no
        // entry yet for this JID.
        if (!_metadataByJid.containsKey(pendingMetadata)) {
          final sentinel = AvatarMetadata.noPepAvatar();
          _metadataByJid[pendingMetadata] = sentinel;
          storage.storeAvatarMetadata(pendingMetadata, sentinel);
          _onUpdate();
        }
      }
      // The actual metadata payload (when it arrives via IQ result) is
      // delivered as a PubSub items result and processed through the same
      // path as event messages. We treat the IQ-result case as a no-op
      // because xmpp_stone surfaces the items separately as a PubSub event
      // when retrieving via `<items/>`.
      return;
    }
    final pending = _pendingDataRequests.remove(stanza.id);
    if (pending == null) {
      return;
    }
    if (stanza.type != IqStanzaType.RESULT) {
      return;
    }
    final pubsub = stanza.getChild('pubsub');
    if (pubsub == null ||
        pubsub.getAttribute('xmlns')?.value !=
            'http://jabber.org/protocol/pubsub') {
      return;
    }
    final items = pubsub.getChild('items');
    if (items == null ||
        items.getAttribute('node')?.value != 'urn:xmpp:avatar:data') {
      return;
    }
    final item = items.getChild('item');
    final data = item?.getChild('data');
    final base64Data = data?.textValue?.trim();
    if (base64Data == null || base64Data.isEmpty) {
      return;
    }
    _avatarBlobs[pending.hash] = base64Data;
    storage.storeAvatarBlob(pending.hash, base64Data);
    _onUpdate();
  }
}

class _PendingAvatarData {
  _PendingAvatarData({required this.bareJid, required this.hash});

  final String bareJid;
  final String hash;
}
