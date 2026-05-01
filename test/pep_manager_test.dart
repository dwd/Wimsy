import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/models/avatar_metadata.dart';
import 'package:wimsy/pep/pep_manager.dart';
import 'package:wimsy/storage/storage_service.dart';

class FakeStorageService extends StorageService {
  final Map<String, AvatarMetadata> metadata = {};
  final Map<String, String> blobs = {};

  @override
  Map<String, AvatarMetadata> loadAvatarMetadata() => Map.from(metadata);

  @override
  Map<String, String> loadAvatarBlobs() => Map.from(blobs);

  @override
  Future<void> storeAvatarMetadata(String bareJid, AvatarMetadata metadata) async {
    this.metadata[bareJid] = metadata;
  }

  @override
  Future<void> storeAvatarBlob(String hash, String base64Data) async {
    blobs[hash] = base64Data;
  }
}

class TestConnection extends Connection {
  TestConnection(super.account);

  AbstractStanza? lastWrittenStanza;

  @override
  void writeStanza(AbstractStanza stanza) {
    lastWrittenStanza = stanza;
  }

  @override
  void writeNonza(Nonza nonza) {}

  @override
  void write(Object? message) {}
}

MessageStanza _buildMetadataEvent({required String fromJid, required String hash}) {
  final stanza = MessageStanza('msg1', MessageStanzaType.CHAT);
  stanza.fromJid = Jid.fromFullJid(fromJid);
  final event = XmppElement()..name = 'event';
  event.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub#event'));
  final items = XmppElement()..name = 'items';
  items.addAttribute(XmppAttribute('node', 'urn:xmpp:avatar:metadata'));
  final item = XmppElement()..name = 'item';
  item.addAttribute(XmppAttribute('id', hash));
  final metadata = XmppElement()..name = 'metadata';
  metadata.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:avatar:metadata'));
  final info = XmppElement()..name = 'info';
  info.addAttribute(XmppAttribute('id', hash));
  info.addAttribute(XmppAttribute('type', 'image/png'));
  info.addAttribute(XmppAttribute('bytes', '1234'));
  metadata.addChild(info);
  item.addChild(metadata);
  items.addChild(item);
  event.addChild(items);
  stanza.addChild(event);
  return stanza;
}

IqStanza _buildAvatarDataResult({required String id, required String hash, required String base64Data}) {
  final stanza = IqStanza(id, IqStanzaType.RESULT);
  final pubsub = XmppElement()..name = 'pubsub';
  pubsub.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
  final items = XmppElement()..name = 'items';
  items.addAttribute(XmppAttribute('node', 'urn:xmpp:avatar:data'));
  final item = XmppElement()..name = 'item';
  item.addAttribute(XmppAttribute('id', hash));
  final data = XmppElement()..name = 'data';
  data.textValue = base64Data;
  item.addChild(data);
  items.addChild(item);
  pubsub.addChild(items);
  stanza.addChild(pubsub);
  return stanza;
}

void main() {
  test('PEP avatar metadata event stores metadata and requests data', () {
    final storage = FakeStorageService();
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    var updates = 0;
    final pep = PepManager(
      connection: connection,
      storage: storage,
      selfBareJid: 'user@example.com',
      onUpdate: () => updates++,
    );

    final event = _buildMetadataEvent(fromJid: 'alice@example.com', hash: 'abc123');
    pep.handleStanza(event);

    expect(storage.metadata.containsKey('alice@example.com'), true);
    expect(storage.metadata['alice@example.com']?.hash, 'abc123');
    expect(updates, 1);
    expect(connection.lastWrittenStanza, isA<IqStanza>());
  });

  test('PEP avatar data result stores blob and exposes bytes', () {
    final storage = FakeStorageService()
      ..metadata['alice@example.com'] = AvatarMetadata(
        hash: 'abc123',
        mimeType: 'image/png',
        bytes: 4,
        updatedAt: DateTime.utc(2024, 1, 1),
      );
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    final pep = PepManager(
      connection: connection,
      storage: storage,
      selfBareJid: 'user@example.com',
      onUpdate: () {},
    );

    final data = base64Encode([1, 2, 3, 4]);
    final requestId = pep.requestAvatarData('alice@example.com', 'abc123');
    final stanza = _buildAvatarDataResult(id: requestId!, hash: 'abc123', base64Data: data);
    pep.handleStanza(stanza);

    final bytes = pep.avatarBytesFor('alice@example.com');
    expect(bytes, isNotNull);
    expect(bytes, [1, 2, 3, 4]);
  });

  test('PEP exposes avatar hash for known metadata', () {
    final storage = FakeStorageService();
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    final pep = PepManager(
      connection: connection,
      storage: storage,
      selfBareJid: 'user@example.com',
      onUpdate: () {},
    );

    final event = _buildMetadataEvent(fromJid: 'alice@example.com', hash: 'hash123');
    pep.handleStanza(event);

    expect(pep.avatarHashFor('alice@example.com'), 'hash123');
  });

  group('R3.3 negative cache for "no PEP avatar"', () {
    test('error response to metadata IQ persists noPepAvatar sentinel', () {
      final storage = FakeStorageService();
      final account = XmppAccountSettings(
        'test',
        'user',
        'example.com',
        'pass',
        5222,
      );
      final connection = TestConnection(account);
      var updates = 0;
      final pep = PepManager(
        connection: connection,
        storage: storage,
        selfBareJid: 'user@example.com',
        onUpdate: () => updates++,
      );

      pep.requestMetadataIfMissing('test1@example.com');
      // The IQ went out; capture its id from the wire so we can build a
      // matching error response.
      final outgoing = connection.lastWrittenStanza;
      expect(outgoing, isA<IqStanza>());
      final outgoingId = (outgoing as IqStanza).id!;

      final errorReply = IqStanza(outgoingId, IqStanzaType.ERROR);
      pep.handleStanza(errorReply);

      // We now know this JID has no PEP avatar.
      expect(pep.isKnownToHaveNoPepAvatar('test1@example.com'), isTrue);
      // Persisted to disk so the next session won't retry.
      expect(
        storage.metadata['test1@example.com']?.isNoPepAvatar ?? false,
        isTrue,
      );
      // No-op for callers who only care about avatar bytes / hash.
      expect(pep.avatarBytesFor('test1@example.com'), isNull);
      expect(pep.avatarHashFor('test1@example.com'), isNull);
      // Listener was notified once for the negative cache write.
      expect(updates, 1);
    });

    test(
      'requestMetadataIfMissing skips IQ when sentinel is already cached',
      () {
        final storage = FakeStorageService();
        // Pre-seed the sentinel (e.g. from a previous session that cached it
        // to disk).
        storage.metadata['test1@example.com'] = AvatarMetadata.noPepAvatar();
        final account = XmppAccountSettings(
          'test',
          'user',
          'example.com',
          'pass',
          5222,
        );
        final connection = TestConnection(account);
        final pep = PepManager(
          connection: connection,
          storage: storage,
          selfBareJid: 'user@example.com',
          onUpdate: () {},
        );

        pep.requestMetadataIfMissing('test1@example.com');
        // No IQ should have been written: the in-memory cache already
        // contains the sentinel, so requestMetadataIfMissing short-circuits.
        expect(connection.lastWrittenStanza, isNull);
      },
    );

    test(
      'real metadata event clears the sentinel on next pubsub update',
      () {
        final storage = FakeStorageService();
        // Pre-seed the sentinel.
        storage.metadata['test1@example.com'] = AvatarMetadata.noPepAvatar();
        final account = XmppAccountSettings(
          'test',
          'user',
          'example.com',
          'pass',
          5222,
        );
        final connection = TestConnection(account);
        final pep = PepManager(
          connection: connection,
          storage: storage,
          selfBareJid: 'user@example.com',
          onUpdate: () {},
        );

        // Now an event arrives advertising a real avatar.
        final event = _buildMetadataEvent(
          fromJid: 'test1@example.com',
          hash: 'real-hash',
        );
        pep.handleStanza(event);

        expect(pep.isKnownToHaveNoPepAvatar('test1@example.com'), isFalse);
        expect(pep.avatarHashFor('test1@example.com'), 'real-hash');
      },
    );

    test('AvatarMetadata.noPepAvatar round-trips through fromMap', () {
      final original = AvatarMetadata.noPepAvatar(
        updatedAt: DateTime.utc(2026, 5, 1, 12, 30),
      );
      final restored = AvatarMetadata.fromMap(original.toMap());
      expect(restored, isNotNull);
      expect(restored!.isNoPepAvatar, isTrue);
      expect(restored.hash, AvatarMetadata.noPepAvatarHash);
      expect(restored.updatedAt, DateTime.utc(2026, 5, 1, 12, 30));
    });

    test(
      'AvatarMetadata.fromMap still rejects malformed legitimate entries',
      () {
        // empty hash
        expect(
          AvatarMetadata.fromMap({
            'hash': '',
            'mimeType': 'image/png',
            'bytes': 4,
            'updatedAt': DateTime.utc(2026).toIso8601String(),
          }),
          isNull,
        );
        // empty mime
        expect(
          AvatarMetadata.fromMap({
            'hash': 'abc',
            'mimeType': '',
            'bytes': 4,
            'updatedAt': DateTime.utc(2026).toIso8601String(),
          }),
          isNull,
        );
        // zero bytes
        expect(
          AvatarMetadata.fromMap({
            'hash': 'abc',
            'mimeType': 'image/png',
            'bytes': 0,
            'updatedAt': DateTime.utc(2026).toIso8601String(),
          }),
          isNull,
        );
      },
    );
  });
}
