import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/avatar_metadata.dart';
import '../models/chat_message.dart';
import '../models/contact_entry.dart';
import 'fast_token_record.dart';
import 'iap_cache_record.dart';
import 'secure_store.dart';

class StorageService {
  static const _secureBoxName = 'wimsy_secure';
  static const _saltKey = 'wimsy_salt';
  static const _accountKey = 'account';
  // XEP-0484 FAST tokens, keyed by bare JID, so that a token issued for one
  // account is never presented for another.
  static const _fastTokensKey = 'fast_tokens';
  static const _iapCachesKey = 'iap_caches';
  static const _rosterKey = 'roster';
  static const _rosterVersionKey = 'roster_version';
  static const _messagesKey = 'messages';
  static const _roomMessagesKey = 'room_messages';
  static const _avatarMetadataKey = 'avatar_metadata';
  static const _avatarBlobsKey = 'avatar_blobs';
  static const _vcardAvatarsKey = 'vcard_avatars';
  static const _vcardAvatarStateKey = 'vcard_avatar_state';
  static const _bookmarksKey = 'bookmarks';
  static const _displayedSyncKey = 'displayed_sync';
  // Timestamps (ISO-8601) for each chat's last-displayed marker, stored
  // alongside the stanzaId so we can fall back to timestamp comparison
  // when the message itself has been evicted from the cache.
  static const _displayedSyncTimestampsKey = 'displayed_sync_timestamps';
  // R1.3: pending (chatJid -> stanza-id) markers we received via MDS but
  // could not yet match against any local message. These are resolved
  // lazily as messages with the matching stanza-id arrive (live or via
  // MAM) and are removed from disk once resolved.
  static const _displayedSyncPendingKey = 'displayed_sync_pending';
  // R5: persisted Entity Capabilities (XEP-0115) cache, keyed by
  // `node#ver`. Values are the disco#info feature lists.
  static const _entityCapsKey = 'entity_caps';
  // R2.1: single global anchor for the newest MAM id we've ingested
  // across all chats. The intent is to enable a unified MAM catch-up
  // query (`<query><x type=submit><field var=after-id>...`) that
  // replaces the per-chat fan-out at connect time. We persist the
  // anchor today; the unified query is a follow-up.
  static const _lastMamIdSeenKey = 'last_mam_id_seen';
  static const int _maxCachedMessageBytes = 20 * 1024 * 1024;

  // ---------------------------------------------------------------------
  // Per-record key prefixes.
  //
  // Hive is an append-only log: every `put` appends the *whole* encoded
  // value and only reclaims the space on compaction. Storing a hot cache as
  // one aggregated map value therefore costs the size of the entire cache on
  // every single update (a 20 MB message cache re-written per received
  // message, a multi-megabyte avatar map re-written per fetched vCard). That
  // write amplification is what grew the box to hundreds of gigabytes, at
  // which point Hive could no longer open it at all because opening a box
  // reads the complete file into memory.
  //
  // The hot caches are therefore stored one record per item: a write now
  // costs the size of that single chat / avatar / caps entry.
  static const _messagePrefix = 'msg:';
  static const _roomMessagePrefix = 'rmsg:';
  static const _avatarBlobPrefix = 'ablob:';
  static const _vcardAvatarPrefix = 'vcav:';
  static const _entityCapsPrefix = 'caps:';

  /// Above this size the box is considered bloated and is compacted eagerly
  /// rather than waiting for Hive's own (60 overwrites) heuristic. Mutable
  /// so tests can exercise the guard without writing tens of megabytes.
  @visibleForTesting
  int compactThresholdBytes = 32 * 1024 * 1024;

  /// A box larger than this cannot be opened safely (Hive reads the whole
  /// file into memory), so it is salvaged into a fresh box instead.
  @visibleForTesting
  int salvageThresholdBytes = 256 * 1024 * 1024;

  /// Number of hot-path writes between box-size checks.
  static const int _writesBetweenSizeChecks = 32;

  /// Keys worth rescuing from a bloated box. Message/avatar/caps caches are
  /// deliberately *not* salvaged: they are re-fetchable and are exactly the
  /// data that made the file unmanageable.
  static const List<String> _essentialKeys = [
    _accountKey,
    _fastTokensKey,
    _iapCachesKey,
    _rosterKey,
    _rosterVersionKey,
    _bookmarksKey,
    _displayedSyncKey,
    _displayedSyncTimestampsKey,
    _displayedSyncPendingKey,
    _avatarMetadataKey,
    _vcardAvatarStateKey,
    _lastMamIdSeenKey,
  ];

  /// [secureStore] is only injected by tests; production code uses the
  /// platform keystore implementation.
  StorageService({SecureStore? secureStore})
    : _secureStorage = secureStore ?? createSecureStore();

  final SecureStore _secureStorage;
  Box<dynamic>? _box;
  String? _hivePath;
  int _writesSinceSizeCheck = 0;
  bool _compacting = false;

  /// In-memory mirror of the per-chat message records. Keeping it here means
  /// a message store only has to re-encode (and re-write) the affected chat
  /// instead of reading and re-writing every cached conversation.
  final Map<String, List<ChatMessage>> _messageCache = {};
  final Map<String, List<ChatMessage>> _roomMessageCache = {};

  /// Initializes Hive. [path] is only used by tests, which cannot rely on
  /// the platform's application-documents directory.
  Future<void> initialize({String? path}) async {
    if (path != null) {
      _hivePath = path;
      Hive.init(path);
      return;
    }
    await Hive.initFlutter();
    try {
      _hivePath = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      // Without a path we simply skip the size guard; everything else works.
      _hivePath = null;
    }
  }

  Future<bool> hasPin() async {
    final salt = await _secureStorage.read(key: _saltKey);
    return salt != null && salt.isNotEmpty;
  }

  bool get isUnlocked => _box != null;

  Future<void> setupPin(String pin) async {
    final salt = _randomBytes(16);
    await _secureStorage.write(key: _saltKey, value: base64Encode(salt));
    await _openBoxWithPin(pin, salt);
  }

  Future<void> unlock(String pin) async {
    final saltBase64 = await _secureStorage.read(key: _saltKey);
    if (saltBase64 == null || saltBase64.isEmpty) {
      throw StateError('PIN has not been set.');
    }
    final salt = base64Decode(saltBase64);
    await _openBoxWithPin(pin, salt);
  }

  Future<void> lock() async {
    await _box?.close();
    _box = null;
    _messageCache.clear();
    _roomMessageCache.clear();
  }

  Map<String, dynamic>? loadAccount() {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get(_accountKey);
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return null;
  }

  Future<void> storeAccount(Map<String, dynamic> account) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_accountKey, account);
  }

  /// Loads the persisted FAST (XEP-0484) credentials for [bareJid], or null
  /// when no usable token is stored. Expired tokens are treated as absent and
  /// removed from disk so we do not present them to the server.
  FastTokenRecord? loadFastToken(String bareJid) {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return null;
    }
    final data = box.get(_fastTokensKey);
    if (data is! Map) {
      return null;
    }
    final entry = data[bareJid];
    if (entry is! Map) {
      return null;
    }
    final record = FastTokenRecord.fromMap(Map<String, dynamic>.from(entry));
    if (record == null) {
      return null;
    }
    if (record.isExpired) {
      unawaited(clearFastToken(bareJid));
      return null;
    }
    return record;
  }

  /// Persists the FAST credentials issued for [bareJid], replacing any
  /// previously stored token for that account.
  Future<void> storeFastToken(String bareJid, FastTokenRecord record) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    final existing = box.get(_fastTokensKey);
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(
        existing.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    next[bareJid] = record.toMap();
    await box.put(_fastTokensKey, next);
  }

  /// Drops the stored FAST credentials for [bareJid], e.g. after the server
  /// rejected the token, so the next connection authenticates with SCRAM.
  Future<void> clearFastToken(String bareJid) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    final existing = box.get(_fastTokensKey);
    if (existing is! Map || !existing.containsKey(bareJid)) {
      return;
    }
    final next = <String, dynamic>{};
    next.addAll(existing.map((key, value) => MapEntry(key.toString(), value)));
    next.remove(bareJid);
    await box.put(_fastTokensKey, next);
  }

  /// Drops every stored FAST token (forget-account flows).
  Future<void> clearFastTokens() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_fastTokensKey, const <String, dynamic>{});
  }

  IapCacheRecord? loadIapCache(String bareJid) {
    final data = _box?.get(_iapCachesKey);
    if (bareJid.isEmpty || data is! Map || data[bareJid] is! Map) return null;
    return IapCacheRecord.fromMap(
      Map<String, dynamic>.from(data[bareJid] as Map),
    );
  }

  Future<void> storeIapCache(String bareJid, IapCacheRecord record) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) return;
    final existing = box.get(_iapCachesKey);
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(
        existing.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    next[bareJid] = record.toMap();
    await box.put(_iapCachesKey, next);
  }

  List<ContactEntry> loadRoster() {
    final box = _box;
    if (box == null) {
      return const [];
    }
    final data = box.get(_rosterKey, defaultValue: const <dynamic>[]);
    if (data is List) {
      final contacts = <ContactEntry>[];
      for (final entry in data) {
        if (entry is Map) {
          final contact = ContactEntry.fromMap(
            Map<String, dynamic>.from(entry),
          );
          if (contact != null) {
            contacts.add(contact);
          }
        } else {
          final jid = entry.toString();
          if (jid.isNotEmpty) {
            contacts.add(ContactEntry(jid: jid));
          }
        }
      }
      return contacts;
    }
    return const [];
  }

  String? loadRosterVersion() {
    final box = _box;
    if (box == null) {
      return null;
    }
    final value = box.get(_rosterVersionKey);
    final version = value?.toString();
    return (version == null || version.isEmpty) ? null : version;
  }

  Future<void> storeRosterVersion(String? version) async {
    final box = _box;
    if (box == null) {
      return;
    }
    if (version == null || version.isEmpty) {
      await box.delete(_rosterVersionKey);
      return;
    }
    await box.put(_rosterVersionKey, version);
  }

  Future<void> storeRoster(List<ContactEntry> roster) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_rosterKey, roster.map((entry) => entry.toMap()).toList());
  }

  List<ContactEntry> loadBookmarks() {
    final box = _box;
    if (box == null) {
      return const [];
    }
    final data = box.get(_bookmarksKey, defaultValue: const <dynamic>[]);
    if (data is List) {
      final bookmarks = <ContactEntry>[];
      for (final entry in data) {
        if (entry is Map) {
          final bookmark = ContactEntry.fromMap(
            Map<String, dynamic>.from(entry),
          );
          if (bookmark != null) {
            bookmarks.add(bookmark);
          }
        }
      }
      return bookmarks;
    }
    return const [];
  }

  Future<void> storeBookmarks(List<ContactEntry> bookmarks) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(
      _bookmarksKey,
      bookmarks.map((entry) => entry.toMap()).toList(),
    );
  }

  Map<String, List<ChatMessage>> loadMessages() {
    if (_box == null) {
      return const {};
    }
    return _copyMessageCache(_messageCache);
  }

  Map<String, List<ChatMessage>> loadRoomMessages() {
    if (_box == null) {
      return const {};
    }
    return _copyMessageCache(_roomMessageCache);
  }

  Future<void> storeMessagesForJid(
    String bareJid,
    List<ChatMessage> messages,
  ) async {
    await _storeMessagesForJid(bareJid, messages, isRoom: false);
  }

  Future<void> storeRoomMessagesForJid(
    String roomJid,
    List<ChatMessage> messages,
  ) async {
    await _storeMessagesForJid(roomJid, messages, isRoom: true);
  }

  /// Writes a single conversation. Only the record of [jid] (plus any chat
  /// whose messages the size limit evicted) is re-encoded and written, so the
  /// cost of caching a message no longer scales with the size of the whole
  /// cache.
  Future<void> _storeMessagesForJid(
    String jid,
    List<ChatMessage> messages, {
    required bool isRoom,
  }) async {
    final box = _box;
    if (box == null) {
      return;
    }
    if (jid.isEmpty) {
      if (isRoom) {
        await clearRoomMessages();
      } else {
        _messageCache.clear();
        await _deleteKeysWithPrefix(_messagePrefix);
      }
      return;
    }
    final cache = isRoom ? _roomMessageCache : _messageCache;
    cache[jid] = List<ChatMessage>.from(messages);
    final touched = <_MessageCacheKey>{_MessageCacheKey(jid, isRoom)};
    touched.addAll(_enforceMessageCacheLimit());
    await _writeMessageRecords(touched);
    _afterHotWrite();
  }

  Future<void> _writeMessageRecords(Set<_MessageCacheKey> keys) async {
    final box = _box;
    if (box == null || keys.isEmpty) {
      return;
    }
    final writes = <String, dynamic>{};
    final deletes = <String>[];
    for (final key in keys) {
      final cache = key.isRoom ? _roomMessageCache : _messageCache;
      final boxKey = _messageRecordKey(key);
      final list = cache[key.jid];
      if (list == null || list.isEmpty) {
        cache.remove(key.jid);
        if (box.containsKey(boxKey)) {
          deletes.add(boxKey);
        }
        continue;
      }
      writes[boxKey] = list
          .map((message) => message.toMap())
          .toList(growable: false);
    }
    if (deletes.isNotEmpty) {
      await box.deleteAll(deletes);
    }
    if (writes.isNotEmpty) {
      await box.putAll(writes);
    }
  }

  String _messageRecordKey(_MessageCacheKey key) {
    return '${key.isRoom ? _roomMessagePrefix : _messagePrefix}${key.jid}';
  }

  Map<String, List<ChatMessage>> _copyMessageCache(
    Map<String, List<ChatMessage>> cache,
  ) {
    return cache.map(
      (jid, messages) => MapEntry(jid, List<ChatMessage>.from(messages)),
    );
  }

  /// Reads the per-chat message records into memory. Called once when the
  /// box is opened.
  void _seedMessageCaches() {
    final box = _box;
    _messageCache.clear();
    _roomMessageCache.clear();
    if (box == null) {
      return;
    }
    var invalidCache = false;
    for (final key in box.keys) {
      final name = key.toString();
      final bool isRoom;
      final String jid;
      if (name.startsWith(_roomMessagePrefix)) {
        isRoom = true;
        jid = name.substring(_roomMessagePrefix.length);
      } else if (name.startsWith(_messagePrefix)) {
        isRoom = false;
        jid = name.substring(_messagePrefix.length);
      } else {
        continue;
      }
      if (jid.isEmpty) {
        continue;
      }
      final value = box.get(name);
      if (value is! List) {
        continue;
      }
      final messages = <ChatMessage>[];
      for (final raw in value) {
        if (raw is! Map) {
          continue;
        }
        final rawMap = Map<String, dynamic>.from(raw);
        final rawXml = rawMap['rawXml']?.toString() ?? '';
        if (rawXml.isEmpty) {
          invalidCache = true;
          continue;
        }
        final message = ChatMessage.fromMap(rawMap);
        if (message != null) {
          messages.add(message);
        }
      }
      if (messages.isEmpty) {
        continue;
      }
      (isRoom ? _roomMessageCache : _messageCache)[jid] = messages;
    }
    if (invalidCache) {
      // A record written by an older, incompatible format: drop the whole
      // message cache rather than showing half-decoded history.
      _clearMessageCaches();
    }
  }

  /// Trims the oldest messages until the in-memory cache is back below
  /// [_maxCachedMessageBytes]. Returns the chats whose records changed so the
  /// caller can persist exactly those.
  Set<_MessageCacheKey> _enforceMessageCacheLimit() {
    var totalBytes =
        _totalMessageBytes(_messageCache) +
        _totalMessageBytes(_roomMessageCache);
    if (totalBytes <= _maxCachedMessageBytes) {
      return const {};
    }
    final all = <_CachedMessageRef>[];
    for (final entry in _messageCache.entries) {
      for (final message in entry.value) {
        all.add(
          _CachedMessageRef(
            entry.value,
            message,
            _MessageCacheKey(entry.key, false),
          ),
        );
      }
    }
    for (final entry in _roomMessageCache.entries) {
      for (final message in entry.value) {
        all.add(
          _CachedMessageRef(
            entry.value,
            message,
            _MessageCacheKey(entry.key, true),
          ),
        );
      }
    }
    all.sort((a, b) => a.message.timestamp.compareTo(b.message.timestamp));
    final touched = <_MessageCacheKey>{};
    var index = 0;
    while (totalBytes > _maxCachedMessageBytes && index < all.length) {
      final ref = all[index];
      if (ref.list.remove(ref.message)) {
        totalBytes -= _messageBytes(ref.message);
        touched.add(ref.cacheKey);
      }
      index += 1;
    }
    _messageCache.removeWhere((_, list) => list.isEmpty);
    _roomMessageCache.removeWhere((_, list) => list.isEmpty);
    return touched;
  }

  int _totalMessageBytes(Map<String, List<ChatMessage>> messages) {
    var total = 0;
    for (final list in messages.values) {
      for (final message in list) {
        total += _messageBytes(message);
      }
    }
    return total;
  }

  int _messageBytes(ChatMessage message) {
    final raw = message.rawXml ?? '';
    return utf8.encode(raw).length;
  }

  void _clearMessageCaches() {
    _messageCache.clear();
    _roomMessageCache.clear();
    if (_box == null) {
      return;
    }
    unawaited(_deleteKeysWithPrefix(_messagePrefix));
    unawaited(_deleteKeysWithPrefix(_roomMessagePrefix));
  }

  Future<void> clearRoster() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_rosterKey, const <dynamic>[]);
    await box.delete(_rosterVersionKey);
  }

  Future<void> clearBookmarks() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_bookmarksKey, const <dynamic>[]);
  }

  Future<void> clearDisplayedSync() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_displayedSyncKey, const <String, dynamic>{});
    await box.put(_displayedSyncTimestampsKey, const <String, dynamic>{});
    // R1.3: also wipe the pending-resolution map so disconnect/forget
    // genuinely clears all MDS-related state.
    await box.put(_displayedSyncPendingKey, const <String, dynamic>{});
  }

  Future<void> clearRoomMessages() async {
    _roomMessageCache.clear();
    await _deleteKeysWithPrefix(_roomMessagePrefix);
  }

  Map<String, AvatarMetadata> loadAvatarMetadata() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(
      _avatarMetadataKey,
      defaultValue: const <String, dynamic>{},
    );
    if (data is Map) {
      final result = <String, AvatarMetadata>{};
      for (final entry in data.entries) {
        if (entry.value is Map) {
          final meta = AvatarMetadata.fromMap(
            Map<String, dynamic>.from(entry.value as Map),
          );
          if (meta != null) {
            result[entry.key.toString()] = meta;
          }
        }
      }
      return result;
    }
    return const {};
  }

  Map<String, String> loadDisplayedSync() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(
      _displayedSyncKey,
      defaultValue: const <String, dynamic>{},
    );
    if (data is Map) {
      final result = <String, String>{};
      for (final entry in data.entries) {
        final key = entry.key.toString();
        final value = entry.value?.toString() ?? '';
        if (key.isNotEmpty && value.isNotEmpty) {
          result[key] = value;
        }
      }
      return result;
    }
    return const {};
  }

  Map<String, DateTime> loadDisplayedSyncTimestamps() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(
      _displayedSyncTimestampsKey,
      defaultValue: const <String, dynamic>{},
    );
    if (data is! Map) {
      return const {};
    }
    final result = <String, DateTime>{};
    for (final entry in data.entries) {
      final ts = DateTime.tryParse(entry.value.toString());
      if (ts != null) {
        result[entry.key.toString()] = ts;
      }
    }
    return result;
  }

  Future<void> storeDisplayedSyncTimestamps(
    Map<String, DateTime> timestamps,
  ) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(
      _displayedSyncTimestampsKey,
      timestamps.map((k, v) => MapEntry(k, v.toIso8601String())),
    );
  }

  Future<void> storeDisplayedSync(Map<String, String> sync) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_displayedSyncKey, Map<String, String>.from(sync));
  }

  /// R1.3: load pending displayed-sync markers — i.e. (chatJid -> stanzaId)
  /// pairs we received from the MDS node but could not yet match against
  /// any locally cached message. The XmppService resolves these as
  /// matching messages arrive (live, via MAM, or via Carbons).
  Map<String, String> loadDisplayedSyncPending() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(
      _displayedSyncPendingKey,
      defaultValue: const <String, dynamic>{},
    );
    if (data is Map) {
      final result = <String, String>{};
      for (final entry in data.entries) {
        final key = entry.key.toString();
        final value = entry.value?.toString() ?? '';
        if (key.isNotEmpty && value.isNotEmpty) {
          result[key] = value;
        }
      }
      return result;
    }
    return const {};
  }

  /// R1.3: persist the pending-resolution map.
  Future<void> storeDisplayedSyncPending(Map<String, String> pending) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_displayedSyncPendingKey, Map<String, String>.from(pending));
  }

  /// R5: load the persisted Entity Capabilities (XEP-0115) cache. The
  /// returned map is keyed by `node#ver` and the values are the verified
  /// `disco#info` feature lists.
  ///
  /// We persist this cache to skip the per-`node#ver` `disco#info` IQ
  /// fan-out at connect time when MUC presence broadcasts caps for many
  /// occupants. If the cache returns nothing for a given `node#ver` the
  /// existing online query path still runs.
  Map<String, Set<String>> loadEntityCaps() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final result = <String, Set<String>>{};
    for (final key in _keysWithPrefix(box, _entityCapsPrefix)) {
      final capsKey = key.substring(_entityCapsPrefix.length);
      if (capsKey.isEmpty) {
        continue;
      }
      final value = box.get(key);
      if (value is! List) {
        continue;
      }
      final features = <String>{
        for (final feature in value)
          if (feature is String && feature.isNotEmpty) feature,
      };
      if (features.isNotEmpty) {
        result[capsKey] = features;
      }
    }
    return result;
  }

  /// R5: persist a single `node#ver` -> features mapping. Existing entries
  /// for other `node#ver` keys are preserved. We never overwrite an
  /// existing entry — Entity Capabilities are content-addressed by hash so
  /// a stable key always corresponds to the same feature set.
  Future<void> storeEntityCaps(String capsKey, Set<String> features) async {
    final box = _box;
    if (box == null) {
      return;
    }
    if (capsKey.isEmpty || features.isEmpty) {
      return;
    }
    final recordKey = '$_entityCapsPrefix$capsKey';
    if (box.containsKey(recordKey)) {
      return;
    }
    await box.put(recordKey, features.toList(growable: false));
    _afterHotWrite();
  }

  /// R5: clear the entire caps cache (e.g. for "forget account" flows).
  Future<void> clearEntityCaps() async {
    await _deleteKeysWithPrefix(_entityCapsPrefix);
  }

  /// R2.1: load the persisted "newest MAM id we've seen" anchor across
  /// all chats. Returns null when there is no recorded anchor.
  String? loadLastMamIdSeen() {
    final box = _box;
    if (box == null) {
      return null;
    }
    final value = box.get(_lastMamIdSeenKey)?.toString();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  /// R2.1: persist the global anchor. Callers should only call this with
  /// an id that is genuinely newer than the previous anchor; the helper
  /// performs no ordering check (MAM ids are server-assigned and only
  /// totally ordered within a single MAM archive, so the value passed
  /// here must come from the caller's append path).
  Future<void> storeLastMamIdSeen(String mamId) async {
    final box = _box;
    if (box == null) {
      return;
    }
    if (mamId.isEmpty) {
      return;
    }
    await box.put(_lastMamIdSeenKey, mamId);
  }

  /// R2.1: clear the anchor (forget-account flows).
  Future<void> clearLastMamIdSeen() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.delete(_lastMamIdSeenKey);
  }

  Future<void> storeAvatarMetadata(
    String bareJid,
    AvatarMetadata metadata,
  ) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final existing = box.get(
      _avatarMetadataKey,
      defaultValue: <String, dynamic>{},
    );
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(
        existing.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    next[bareJid] = metadata.toMap();
    await box.put(_avatarMetadataKey, next);
  }

  Map<String, String> loadAvatarBlobs() {
    return _loadPrefixedStrings(_avatarBlobPrefix);
  }

  Future<void> storeAvatarBlob(String hash, String base64Data) async {
    final box = _box;
    if (box == null || hash.isEmpty) {
      return;
    }
    await box.put('$_avatarBlobPrefix$hash', base64Data);
    _afterHotWrite();
  }

  /// R3.1: replace the entire avatar-blobs map with [blobs]. Used by the
  /// PEP avatar GC pass that keeps only blobs referenced by a current
  /// metadata entry.
  Future<void> replaceAvatarBlobs(Map<String, String> blobs) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final keep = <String, dynamic>{
      for (final entry in blobs.entries)
        if (entry.key.isNotEmpty) '$_avatarBlobPrefix${entry.key}': entry.value,
    };
    final stale = _keysWithPrefix(
      box,
      _avatarBlobPrefix,
    ).where((key) => !keep.containsKey(key)).toList(growable: false);
    if (stale.isNotEmpty) {
      await box.deleteAll(stale);
    }
    if (keep.isNotEmpty) {
      await box.putAll(keep);
    }
  }

  Future<void> clearAvatars() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_avatarMetadataKey, <String, dynamic>{});
    await _deleteKeysWithPrefix(_avatarBlobPrefix);
  }

  Map<String, String> loadVcardAvatars() {
    return _loadPrefixedStrings(_vcardAvatarPrefix);
  }

  /// Reads every record whose key starts with [prefix] into a map keyed by
  /// the remainder of the key.
  Map<String, String> _loadPrefixedStrings(String prefix) {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final result = <String, String>{};
    for (final key in _keysWithPrefix(box, prefix)) {
      final value = box.get(key);
      if (value == null) {
        continue;
      }
      final id = key.substring(prefix.length);
      if (id.isEmpty) {
        continue;
      }
      result[id] = value.toString();
    }
    return result;
  }

  Map<String, String> loadVcardAvatarState() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(
      _vcardAvatarStateKey,
      defaultValue: const <String, dynamic>{},
    );
    if (data is Map) {
      final result = <String, String>{};
      for (final entry in data.entries) {
        result[entry.key.toString()] = entry.value.toString();
      }
      return result;
    }
    return const {};
  }

  Future<void> storeVcardAvatar(String bareJid, String base64Data) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_vcardAvatarPrefix$bareJid', base64Data);
    _afterHotWrite();
  }

  Future<void> removeVcardAvatar(String bareJid) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.delete('$_vcardAvatarPrefix$bareJid');
  }

  Future<void> storeVcardAvatarState(String bareJid, String state) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final existing = box.get(
      _vcardAvatarStateKey,
      defaultValue: <String, dynamic>{},
    );
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(
        existing.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    next[bareJid] = state;
    await box.put(_vcardAvatarStateKey, next);
  }

  Future<void> clearVcardAvatars() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await _deleteKeysWithPrefix(_vcardAvatarPrefix);
    await box.put(_vcardAvatarStateKey, <String, dynamic>{});
  }

  Future<void> _openBoxWithPin(String pin, List<int> salt) async {
    final key = await _deriveKey(pin, salt);
    final cipher = HiveAesCipher(key);
    await _salvageBoxIfOversized(cipher);
    _box = await Hive.openBox<dynamic>(
      _secureBoxName,
      encryptionCipher: cipher,
    );
    await _migrateAggregatedCaches();
    _seedMessageCaches();
    await _compactIfOversized();
  }

  /// Absolute path of the encrypted box file, or null when Hive was
  /// initialized without a known directory (e.g. web).
  String? get _boxFile {
    final dir = _hivePath;
    if (dir == null || dir.isEmpty) {
      return null;
    }
    return '$dir${Platform.pathSeparator}$_secureBoxName.hive';
  }

  int _boxFileSize() {
    final path = _boxFile;
    if (path == null) {
      return 0;
    }
    try {
      final file = File(path);
      return file.existsSync() ? file.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Recovers from a box that has grown beyond [salvageThresholdBytes].
  ///
  /// Opening a regular box reads the whole file into memory, so a bloated box
  /// makes the app die with an out-of-memory error before it can do anything
  /// about it. A *lazy* box only streams the keys, which lets us copy the
  /// handful of records that are not re-fetchable ([_essentialKeys]) into a
  /// brand new, compact box and drop everything else.
  Future<void> _salvageBoxIfOversized(HiveAesCipher cipher) async {
    final size = _boxFileSize();
    if (size <= salvageThresholdBytes) {
      return;
    }
    debugPrint(
      'StorageService: box is ${size ~/ (1024 * 1024)} MiB, salvaging '
      'essential records into a fresh box',
    );
    final salvaged = <String, dynamic>{};
    try {
      final lazyBox = await Hive.openLazyBox<dynamic>(
        _secureBoxName,
        encryptionCipher: cipher,
      );
      for (final key in _essentialKeys) {
        if (!lazyBox.containsKey(key)) {
          continue;
        }
        try {
          final value = await lazyBox.get(key);
          if (value != null) {
            salvaged[key] = value;
          }
        } catch (error) {
          debugPrint('StorageService: could not salvage "$key": $error');
        }
      }
      await lazyBox.close();
    } catch (error) {
      debugPrint('StorageService: salvage pass failed: $error');
    }
    try {
      await Hive.deleteBoxFromDisk(_secureBoxName);
    } catch (error) {
      debugPrint('StorageService: could not delete bloated box: $error');
    }
    if (salvaged.isEmpty) {
      return;
    }
    final box = await Hive.openBox<dynamic>(
      _secureBoxName,
      encryptionCipher: cipher,
    );
    await box.putAll(salvaged);
    await box.close();
    debugPrint(
      'StorageService: salvaged ${salvaged.length} records; caches will be '
      'rebuilt from the server',
    );
  }

  /// Rewrites the legacy aggregated caches (one giant map per cache) into
  /// the per-record layout and drops the old keys. Runs once per box.
  Future<void> _migrateAggregatedCaches() async {
    final box = _box;
    if (box == null) {
      return;
    }
    var migrated = false;
    migrated |= await _migrateMapKey(box, _messagesKey, _messagePrefix);
    migrated |= await _migrateMapKey(box, _roomMessagesKey, _roomMessagePrefix);
    migrated |= await _migrateMapKey(box, _avatarBlobsKey, _avatarBlobPrefix);
    migrated |= await _migrateMapKey(box, _vcardAvatarsKey, _vcardAvatarPrefix);
    migrated |= await _migrateMapKey(box, _entityCapsKey, _entityCapsPrefix);
    if (migrated) {
      // The legacy values are still in the append-only log; reclaim them now
      // rather than after another 60 writes.
      await _compact();
    }
  }

  Future<bool> _migrateMapKey(
    Box<dynamic> box,
    String legacyKey,
    String prefix,
  ) async {
    final data = box.get(legacyKey);
    if (data is! Map) {
      if (box.containsKey(legacyKey)) {
        await box.delete(legacyKey);
        return true;
      }
      return false;
    }
    final entries = <String, dynamic>{};
    for (final entry in data.entries) {
      final key = entry.key.toString();
      if (key.isEmpty || entry.value == null) {
        continue;
      }
      entries['$prefix$key'] = entry.value;
    }
    if (entries.isNotEmpty) {
      await box.putAll(entries);
    }
    await box.delete(legacyKey);
    return true;
  }

  Iterable<String> _keysWithPrefix(Box<dynamic> box, String prefix) {
    return box.keys
        .map((key) => key.toString())
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
  }

  Future<void> _deleteKeysWithPrefix(String prefix) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final keys = _keysWithPrefix(box, prefix);
    if (keys.isEmpty) {
      return;
    }
    await box.deleteAll(keys);
  }

  /// Compacts the box when it has grown past [compactThresholdBytes]. Hive
  /// compacts on its own every 60 overwrites, but it also silently gives up
  /// forever if a single compaction throws, so we check the actual file size
  /// periodically as a backstop.
  Future<void> _compactIfOversized() async {
    if (_boxFileSize() <= compactThresholdBytes) {
      return;
    }
    await _compact();
  }

  Future<void> _compact() async {
    final box = _box;
    if (box == null || _compacting) {
      return;
    }
    _compacting = true;
    try {
      await box.compact();
    } catch (error) {
      debugPrint('StorageService: compaction failed: $error');
    } finally {
      _compacting = false;
    }
  }

  /// Called after every hot-path write. Checks the on-disk size once every
  /// [_writesBetweenSizeChecks] writes so a runaway cache can never grow the
  /// file without bound again.
  void _afterHotWrite() {
    _writesSinceSizeCheck += 1;
    if (_writesSinceSizeCheck < _writesBetweenSizeChecks) {
      return;
    }
    _writesSinceSizeCheck = 0;
    unawaited(_compactIfOversized());
  }

  Future<List<int>> _deriveKey(String pin, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(pin.codeUnits),
      nonce: salt,
    );
    final keyBytes = await secretKey.extractBytes();
    return keyBytes;
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}

class _CachedMessageRef {
  _CachedMessageRef(this.list, this.message, this.cacheKey);

  final List<ChatMessage> list;
  final ChatMessage message;
  final _MessageCacheKey cacheKey;
}

/// Identifies a single cached conversation: its JID plus whether it lives in
/// the one-to-one or the groupchat cache.
class _MessageCacheKey {
  const _MessageCacheKey(this.jid, this.isRoom);

  final String jid;
  final bool isRoom;

  @override
  bool operator ==(Object other) =>
      other is _MessageCacheKey && other.jid == jid && other.isRoom == isRoom;

  @override
  int get hashCode => Object.hash(jid, isRoom);
}
