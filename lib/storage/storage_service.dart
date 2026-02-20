import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/avatar_metadata.dart';
import '../models/chat_message.dart';
import '../models/contact_entry.dart';
import 'secure_store.dart';

class StorageService {
  static const _secureBoxName = 'wimsy_secure';
  static const _saltKey = 'wimsy_salt';
  static const _accountKey = 'account';
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

  Future<void> storeDisplayedSync(Map<String, String> sync) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_displayedSyncKey, Map<String, String>.from(sync));
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
