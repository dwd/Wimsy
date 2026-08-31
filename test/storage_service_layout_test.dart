import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:wimsy/models/chat_message.dart';
import 'package:wimsy/models/avatar_metadata.dart';
import 'package:wimsy/storage/secure_store.dart';
import 'package:wimsy/storage/storage_service.dart';

/// In-memory replacement for the platform keystore so the tests can open a
/// real (encrypted) Hive box without any plugin channels.
class _MemorySecureStore implements SecureStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    _values.remove(key);
  }
}

ChatMessage _message(String id, {String body = 'hello'}) {
  return ChatMessage(
    from: 'alice@example.com',
    to: 'bob@example.com',
    body: body,
    timestamp: DateTime.utc(
      2024,
      1,
      1,
    ).add(Duration(seconds: id.hashCode % 60)),
    outgoing: false,
    messageId: id,
    rawXml: "<message id='$id'><body>$body</body></message>",
  );
}

void main() {
  late Directory dir;
  late StorageService storage;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wimsy_storage_test');
    storage = StorageService(secureStore: _MemorySecureStore());
    await storage.initialize(path: dir.path);
    await storage.setupPin('1234');
  });

  tearDown(() async {
    await storage.lock();
    await Hive.deleteFromDisk();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  File boxFile() =>
      File('${dir.path}${Platform.pathSeparator}wimsy_secure.hive');

  group('per-record storage layout', () {
    test('messages round-trip through one record per chat', () async {
      await storage.storeMessagesForJid('bob@example.com', [_message('m1')]);
      await storage.storeRoomMessagesForJid('room@conf.example.com', [
        _message('m2', body: 'in a room'),
      ]);

      final chats = storage.loadMessages();
      final rooms = storage.loadRoomMessages();
      expect(chats.keys, ['bob@example.com']);
      expect(chats['bob@example.com']!.single.messageId, 'm1');
      expect(rooms['room@conf.example.com']!.single.body, 'in a room');
    });

    test('storing one chat does not rewrite the other chats', () async {
      // Seed a sizeable second conversation, then measure how much the file
      // grows when an unrelated, tiny chat is updated. With the old
      // aggregated layout the whole cache was re-appended every time.
      final bulk = [
        for (var i = 0; i < 200; i++) _message('bulk$i', body: 'x' * 2000),
      ];
      await storage.storeRoomMessagesForJid('room@conf.example.com', bulk);

      final before = boxFile().lengthSync();
      await storage.storeMessagesForJid('bob@example.com', [_message('tiny')]);
      final delta = boxFile().lengthSync() - before;

      expect(
        delta,
        lessThan(4096),
        reason: 'a small write must not re-append the whole cache',
      );
    });

    test('avatars and caps are stored individually', () async {
      await storage.storeVcardAvatar('alice@example.com', 'AAAA');
      await storage.storeVcardAvatar('bob@example.com', 'BBBB');
      await storage.storeAvatarBlob('hash1', 'CCCC');
      await storage.storeEntityCaps('node#ver', {'urn:xmpp:ping'});

      expect(storage.loadVcardAvatars(), {
        'alice@example.com': 'AAAA',
        'bob@example.com': 'BBBB',
      });
      expect(storage.loadAvatarBlobs(), {'hash1': 'CCCC'});
      expect(storage.loadEntityCaps(), {
        'node#ver': {'urn:xmpp:ping'},
      });

      await storage.removeVcardAvatar('alice@example.com');
      expect(storage.loadVcardAvatars(), {'bob@example.com': 'BBBB'});

      await storage.replaceAvatarBlobs({'hash2': 'DDDD'});
      expect(storage.loadAvatarBlobs(), {'hash2': 'DDDD'});

      await storage.clearEntityCaps();
      expect(storage.loadEntityCaps(), isEmpty);
    });

    test('removing contact avatars only removes that contact', () async {
      await storage.storeVcardAvatar('alice@example.com', 'AAAA');
      await storage.storeVcardAvatar('bob@example.com', 'BBBB');
      await storage.storeVcardAvatarState('alice@example.com', 'hash-a');
      await storage.storeVcardAvatarState('bob@example.com', 'hash-b');
      await storage.storeAvatarMetadata(
        'alice@example.com',
        AvatarMetadata.noPepAvatar(),
      );
      await storage.storeAvatarMetadata(
        'bob@example.com',
        AvatarMetadata.noPepAvatar(),
      );

      await storage.removeVcardAvatar('alice@example.com');
      await storage.removeVcardAvatarState('alice@example.com');
      await storage.removeAvatarMetadata('alice@example.com');

      expect(storage.loadVcardAvatars(), {'bob@example.com': 'BBBB'});
      expect(storage.loadVcardAvatarState(), {'bob@example.com': 'hash-b'});
      expect(storage.loadAvatarMetadata().keys, ['bob@example.com']);
    });

    test('clearing a cache removes its records', () async {
      await storage.storeRoomMessagesForJid('room@conf.example.com', [
        _message('m1'),
      ]);
      await storage.clearRoomMessages();
      expect(storage.loadRoomMessages(), isEmpty);

      await storage.storeVcardAvatar('alice@example.com', 'AAAA');
      await storage.clearVcardAvatars();
      expect(storage.loadVcardAvatars(), isEmpty);
    });
  });

  group('migration from the legacy aggregated layout', () {
    test('old maps are split into per-record entries on unlock', () async {
      // Write the pre-migration layout straight into the open box.
      final box = Hive.box<dynamic>('wimsy_secure');
      await box.put('messages', {
        'bob@example.com': [_message('m1').toMap()],
      });
      await box.put('room_messages', {
        'room@conf.example.com': [_message('m2').toMap()],
      });
      await box.put('vcard_avatars', {'alice@example.com': 'AAAA'});
      await box.put('avatar_blobs', {'hash1': 'BBBB'});
      await box.put('entity_caps', {
        'node#ver': ['urn:xmpp:ping'],
      });

      await storage.lock();
      await storage.unlock('1234');

      expect(storage.loadMessages()['bob@example.com']!.single.messageId, 'm1');
      expect(
        storage.loadRoomMessages()['room@conf.example.com']!.single.messageId,
        'm2',
      );
      expect(storage.loadVcardAvatars(), {'alice@example.com': 'AAAA'});
      expect(storage.loadAvatarBlobs(), {'hash1': 'BBBB'});
      expect(storage.loadEntityCaps(), {
        'node#ver': {'urn:xmpp:ping'},
      });

      final migrated = Hive.box<dynamic>('wimsy_secure');
      expect(migrated.containsKey('messages'), isFalse);
      expect(migrated.containsKey('vcard_avatars'), isFalse);
      expect(migrated.containsKey('entity_caps'), isFalse);
    });
  });

  group('recovery from an oversized box', () {
    test('essential records are salvaged and caches dropped', () async {
      await storage.storeAccount({'jid': 'alice@example.com'});
      await storage.storeRoster(const []);
      await storage.storeMessagesForJid('bob@example.com', [_message('m1')]);
      await storage.storeVcardAvatar('alice@example.com', 'AAAA');

      // Simulate a box that has grown past the point where it can be opened
      // by lowering the threshold below the current file size.
      await storage.lock();
      storage.salvageThresholdBytes = 1;
      await storage.unlock('1234');

      expect(storage.loadAccount(), {
        'jid': 'alice@example.com',
      }, reason: 'the account must survive so the user stays logged in');
      expect(
        storage.loadMessages(),
        isEmpty,
        reason: 're-fetchable caches are dropped during salvage',
      );
      expect(storage.loadVcardAvatars(), isEmpty);

      // The rebuilt box must be usable straight away.
      await storage.storeMessagesForJid('bob@example.com', [_message('m2')]);
      expect(storage.loadMessages()['bob@example.com']!.single.messageId, 'm2');
    });
  });

  group('persistence across unlock', () {
    test('account and messages survive a lock/unlock cycle', () async {
      await storage.storeAccount({'jid': 'alice@example.com'});
      await storage.storeMessagesForJid('bob@example.com', [_message('m1')]);

      await storage.lock();
      expect(storage.loadMessages(), isEmpty);

      await storage.unlock('1234');
      expect(storage.loadAccount(), {'jid': 'alice@example.com'});
      expect(storage.loadMessages()['bob@example.com']!.single.messageId, 'm1');
    });

    test('control-message outbox survives a lock/unlock cycle', () async {
      await storage.storeControlMessageOutbox([
        {
          'kind': 'receipt',
          'toJid': 'bob@example.com',
          'referencedId': 'message-1',
        },
      ]);

      await storage.lock();
      await storage.unlock('1234');

      expect(storage.loadControlMessageOutbox(), [
        {
          'kind': 'receipt',
          'toJid': 'bob@example.com',
          'referencedId': 'message-1',
        },
      ]);
    });
  });
}
