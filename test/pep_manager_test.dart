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
}
