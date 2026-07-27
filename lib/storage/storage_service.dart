import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/avatar_metadata.dart';
import '../models/chat_message.dart';
import '../models/contact_entry.dart';
import 'fast_token_record.dart';
import 'secure_store.dart';

class StorageService {
  static const _secureBoxName = 'wimsy_secure';
  static const _saltKey = 'wimsy_salt';
  static const _accountKey = 'account';
  // XEP-0484 FAST tokens, keyed by bare JID, so that a token issued for one
  // account is never presented for another.
  static const _fastTokensKey = 'fast_tokens';
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

  final SecureStore _secureStorage = createSecureStore();
  Box<dynamic>? _box;

  Future<void> initialize() async {
    await Hive.initFlutter();
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
      next.addAll(existing.map((key, value) => MapEntry(key.toString(), value)));
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
          final contact = ContactEntry.fromMap(Map<String, dynamic>.from(entry));
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
          final bookmark = ContactEntry.fromMap(Map<String, dynamic>.from(entry));
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
    await box.put(_bookmarksKey, bookmarks.map((entry) => entry.toMap()).toList());
  }

  Map<String, List<ChatMessage>> loadMessages() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    return _readMessageMap(_messagesKey);
  }

  Map<String, List<ChatMessage>> loadRoomMessages() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    return _readMessageMap(_roomMessagesKey);
  }

  Future<void> storeMessagesForJid(String bareJid, List<ChatMessage> messages) async {
    final box = _box;
    if (box == null) {
      return;
    }
    if (bareJid.isEmpty) {
      await box.put(_messagesKey, <String, dynamic>{});
      return;
    }
    final nextMessages = _readMessageMap(_messagesKey);
    final nextRoomMessages = _readMessageMap(_roomMessagesKey);
    nextMessages[bareJid] = List<ChatMessage>.from(messages);
    _enforceMessageCacheLimit(nextMessages, nextRoomMessages);
    await box.put(_messagesKey, _encodeMessageMap(nextMessages));
    await box.put(_roomMessagesKey, _encodeMessageMap(nextRoomMessages));
  }

  Future<void> storeRoomMessagesForJid(String roomJid, List<ChatMessage> messages) async {
    final box = _box;
    if (box == null) {
      return;
    }
    if (roomJid.isEmpty) {
      await box.put(_roomMessagesKey, <String, dynamic>{});
      return;
    }
    final nextMessages = _readMessageMap(_messagesKey);
    final nextRoomMessages = _readMessageMap(_roomMessagesKey);
    nextRoomMessages[roomJid] = List<ChatMessage>.from(messages);
    _enforceMessageCacheLimit(nextMessages, nextRoomMessages);
    await box.put(_messagesKey, _encodeMessageMap(nextMessages));
    await box.put(_roomMessagesKey, _encodeMessageMap(nextRoomMessages));
  }

  Map<String, List<ChatMessage>> _readMessageMap(String key) {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(key, defaultValue: const <String, dynamic>{});
    if (data is! Map) {
      return const {};
    }
    final result = <String, List<ChatMessage>>{};
    var invalidCache = false;
    for (final entry in data.entries) {
      final mapKey = entry.key.toString();
      final value = entry.value;
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
      if (messages.isNotEmpty) {
        result[mapKey] = messages;
      }
    }
    if (invalidCache) {
      _clearMessageCaches();
      return const {};
    }
    return result;
  }

  Map<String, dynamic> _encodeMessageMap(Map<String, List<ChatMessage>> messages) {
    final result = <String, dynamic>{};
    for (final entry in messages.entries) {
      result[entry.key] = entry.value.map((message) => message.toMap()).toList();
    }
    return result;
  }

  void _enforceMessageCacheLimit(
    Map<String, List<ChatMessage>> messages,
    Map<String, List<ChatMessage>> roomMessages,
  ) {
    var totalBytes = _totalMessageBytes(messages) + _totalMessageBytes(roomMessages);
    if (totalBytes <= _maxCachedMessageBytes) {
      return;
    }
    final all = <_CachedMessageRef>[];
    for (final entry in messages.entries) {
      for (final message in entry.value) {
        all.add(_CachedMessageRef(entry.value, message));
      }
    }
    for (final entry in roomMessages.entries) {
      for (final message in entry.value) {
        all.add(_CachedMessageRef(entry.value, message));
      }
    }
    all.sort((a, b) => a.message.timestamp.compareTo(b.message.timestamp));
    var index = 0;
    while (totalBytes > _maxCachedMessageBytes && index < all.length) {
      final ref = all[index];
      if (ref.list.remove(ref.message)) {
        totalBytes -= _messageBytes(ref.message);
      }
      index += 1;
    }
    messages.removeWhere((_, list) => list.isEmpty);
    roomMessages.removeWhere((_, list) => list.isEmpty);
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
    final box = _box;
    if (box == null) {
      return;
    }
    unawaited(box.put(_messagesKey, <String, dynamic>{}));
    unawaited(box.put(_roomMessagesKey, <String, dynamic>{}));
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
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_roomMessagesKey, <String, dynamic>{});
  }

  Map<String, AvatarMetadata> loadAvatarMetadata() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(_avatarMetadataKey, defaultValue: const <String, dynamic>{});
    if (data is Map) {
      final result = <String, AvatarMetadata>{};
      for (final entry in data.entries) {
        if (entry.value is Map) {
          final meta = AvatarMetadata.fromMap(Map<String, dynamic>.from(entry.value as Map));
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
    final data = box.get(_displayedSyncKey, defaultValue: const <String, dynamic>{});
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
    final data = box.get(_displayedSyncTimestampsKey,
        defaultValue: const <String, dynamic>{});
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
      Map<String, DateTime> timestamps) async {
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
    await box.put(
      _displayedSyncPendingKey,
      Map<String, String>.from(pending),
    );
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
    final data = box.get(
      _entityCapsKey,
      defaultValue: const <String, dynamic>{},
    );
    if (data is Map) {
      final result = <String, Set<String>>{};
      for (final entry in data.entries) {
        final key = entry.key.toString();
        if (key.isEmpty) {
          continue;
        }
        final value = entry.value;
        if (value is List) {
          final features = <String>{
            for (final feature in value)
              if (feature is String && feature.isNotEmpty) feature,
          };
          if (features.isNotEmpty) {
            result[key] = features;
          }
        }
      }
      return result;
    }
    return const {};
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
    final existing = box.get(_entityCapsKey, defaultValue: <String, dynamic>{});
    final next = <String, dynamic>{};
    if (existing is Map) {
      for (final entry in existing.entries) {
        next[entry.key.toString()] = entry.value;
      }
    }
    if (next.containsKey(capsKey)) {
      return;
    }
    next[capsKey] = features.toList(growable: false);
    await box.put(_entityCapsKey, next);
  }

  /// R5: clear the entire caps cache (e.g. for "forget account" flows).
  Future<void> clearEntityCaps() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_entityCapsKey, const <String, dynamic>{});
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

  Future<void> storeAvatarMetadata(String bareJid, AvatarMetadata metadata) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final existing = box.get(_avatarMetadataKey, defaultValue: <String, dynamic>{});
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(existing.map((key, value) => MapEntry(key.toString(), value)));
    }
    next[bareJid] = metadata.toMap();
    await box.put(_avatarMetadataKey, next);
  }

  Map<String, String> loadAvatarBlobs() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(_avatarBlobsKey, defaultValue: const <String, dynamic>{});
    if (data is Map) {
      final result = <String, String>{};
      for (final entry in data.entries) {
        result[entry.key.toString()] = entry.value.toString();
      }
      return result;
    }
    return const {};
  }

  Future<void> storeAvatarBlob(String hash, String base64Data) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final existing = box.get(_avatarBlobsKey, defaultValue: <String, dynamic>{});
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(existing.map((key, value) => MapEntry(key.toString(), value)));
    }
    next[hash] = base64Data;
    await box.put(_avatarBlobsKey, next);
  }

  /// R3.1: replace the entire avatar-blobs map with [blobs]. Used by the
  /// PEP avatar GC pass that keeps only blobs referenced by a current
  /// metadata entry.
  Future<void> replaceAvatarBlobs(Map<String, String> blobs) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_avatarBlobsKey, Map<String, String>.from(blobs));
  }

  Future<void> clearAvatars() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_avatarMetadataKey, <String, dynamic>{});
    await box.put(_avatarBlobsKey, <String, dynamic>{});
  }

  Map<String, String> loadVcardAvatars() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(_vcardAvatarsKey, defaultValue: const <String, dynamic>{});
    if (data is Map) {
      final result = <String, String>{};
      for (final entry in data.entries) {
        result[entry.key.toString()] = entry.value.toString();
      }
      return result;
    }
    return const {};
  }

  Map<String, String> loadVcardAvatarState() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(_vcardAvatarStateKey, defaultValue: const <String, dynamic>{});
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
    if (box == null) {
      return;
    }
    final existing = box.get(_vcardAvatarsKey, defaultValue: <String, dynamic>{});
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(existing.map((key, value) => MapEntry(key.toString(), value)));
    }
    next[bareJid] = base64Data;
    await box.put(_vcardAvatarsKey, next);
  }

  Future<void> removeVcardAvatar(String bareJid) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final existing = box.get(_vcardAvatarsKey, defaultValue: <String, dynamic>{});
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(existing.map((key, value) => MapEntry(key.toString(), value)));
    }
    next.remove(bareJid);
    await box.put(_vcardAvatarsKey, next);
  }

  Future<void> storeVcardAvatarState(String bareJid, String state) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final existing = box.get(_vcardAvatarStateKey, defaultValue: <String, dynamic>{});
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(existing.map((key, value) => MapEntry(key.toString(), value)));
    }
    next[bareJid] = state;
    await box.put(_vcardAvatarStateKey, next);
  }

  Future<void> clearVcardAvatars() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_vcardAvatarsKey, <String, dynamic>{});
    await box.put(_vcardAvatarStateKey, <String, dynamic>{});
  }

  Future<void> _openBoxWithPin(String pin, List<int> salt) async {
    final key = await _deriveKey(pin, salt);
    final cipher = HiveAesCipher(key);
    _box = await Hive.openBox<dynamic>(_secureBoxName, encryptionCipher: cipher);
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
  _CachedMessageRef(this.list, this.message);

  final List<ChatMessage> list;
  final ChatMessage message;
}
