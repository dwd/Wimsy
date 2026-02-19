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
  static const _messagesKey = 'messages';
  static const _roomMessagesKey = 'room_messages';
  static const _avatarMetadataKey = 'avatar_metadata';
  static const _avatarBlobsKey = 'avatar_blobs';
  static const _vcardAvatarsKey = 'vcard_avatars';
  static const _vcardAvatarStateKey = 'vcard_avatar_state';
  static const _bookmarksKey = 'bookmarks';

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
    final data = box.get(_messagesKey, defaultValue: const <String, dynamic>{});
    if (data is Map) {
      final result = <String, List<ChatMessage>>{};
      for (final entry in data.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is List) {
          final messages = <ChatMessage>[];
          for (final raw in value) {
            if (raw is Map) {
              final message = ChatMessage.fromMap(Map<String, dynamic>.from(raw));
              if (message != null) {
                messages.add(message);
              }
            }
          }
          if (messages.isNotEmpty) {
            result[key] = messages;
          }
        }
      }
      return result;
    }
    return const {};
  }

  Map<String, List<ChatMessage>> loadRoomMessages() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(_roomMessagesKey, defaultValue: const <String, dynamic>{});
    if (data is Map) {
      final result = <String, List<ChatMessage>>{};
      for (final entry in data.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is List) {
          final messages = <ChatMessage>[];
          for (final raw in value) {
            if (raw is Map) {
              final message = ChatMessage.fromMap(Map<String, dynamic>.from(raw));
              if (message != null) {
                messages.add(message);
              }
            }
          }
          if (messages.isNotEmpty) {
            result[key] = messages;
          }
        }
      }
      return result;
    }
    return const {};
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
    final existing = box.get(_messagesKey, defaultValue: <String, dynamic>{});
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(existing.map((key, value) => MapEntry(key.toString(), value)));
    }
    next[bareJid] = messages.map((entry) => entry.toMap()).toList();
    await box.put(_messagesKey, next);
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
    final existing = box.get(_roomMessagesKey, defaultValue: <String, dynamic>{});
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(existing.map((key, value) => MapEntry(key.toString(), value)));
    }
    next[roomJid] = messages.map((entry) => entry.toMap()).toList();
    await box.put(_roomMessagesKey, next);
  }

  Future<void> clearRoster() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_rosterKey, const <dynamic>[]);
  }

  Future<void> clearBookmarks() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_bookmarksKey, const <dynamic>[]);
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
