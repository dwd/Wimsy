import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/models/avatar_metadata.dart';
import 'package:wimsy/pep/pep_caps_manager.dart';
import 'package:wimsy/pep/pep_manager.dart';
import 'package:wimsy/storage/storage_service.dart';

class TestConnection extends Connection {
  TestConnection(super.account);

  final List<AbstractStanza> written = [];

  @override
  void writeStanza(AbstractStanza stanza) {
    written.add(stanza);
  }

  @override
  void writeNonza(Nonza nonza) {}

  @override
  void write(Object? message) {}
}

class FakePepManager extends PepManager {
  FakePepManager({
    required super.connection,
    required super.storage,
    required super.selfBareJid,
    required super.onUpdate,
  });

  final List<String> requested = [];

  @override
  void requestMetadataIfMissing(String bareJid) {
    requested.add(bareJid);
  }
}

class FakeStorageService extends StorageService {
  @override
  Map<String, AvatarMetadata> loadAvatarMetadata() => {};

  @override
  Map<String, String> loadAvatarBlobs() => {};
}

PresenceStanza _presenceWithCaps({required String fromFullJid, required String node, required String ver}) {
  final stanza = PresenceStanza();
  stanza.fromJid = Jid.fromFullJid(fromFullJid);
  final caps = XmppElement()..name = 'c';
  caps.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/caps'));
  caps.addAttribute(XmppAttribute('node', node));
  caps.addAttribute(XmppAttribute('ver', ver));
  caps.addAttribute(XmppAttribute('hash', 'sha-1'));
  stanza.addChild(caps);
  return stanza;
}

IqStanza _discoInfoResult({required String id, required String capsKey, required String feature}) {
  final stanza = IqStanza(id, IqStanzaType.RESULT);
  final query = XmppElement()..name = 'query';
  query.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
  query.addAttribute(XmppAttribute('node', capsKey));
  final featureElement = XmppElement()..name = 'feature';
  featureElement.addAttribute(XmppAttribute('var', feature));
  query.addChild(featureElement);
  stanza.addChild(query);
  return stanza;
}

void main() {
  test('Caps +notify triggers disco#info request without subscribing', () {
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    final storage = FakeStorageService();
    final pep = FakePepManager(
      connection: connection,
      storage: storage,
      selfBareJid: 'user@example.com',
      onUpdate: () {},
    );
    final caps = PepCapsManager(connection: connection, pepManager: pep);

    final presence = _presenceWithCaps(
      fromFullJid: 'alice@example.com/resource',
      node: 'https://example.com/caps',
      ver: 'ABC123',
    );
    caps.handleStanza(presence);

    expect(connection.written, isNotEmpty);
    final iq = connection.written.last as IqStanza;
    final query = iq.getChild('query');
    expect(query?.getAttribute('node')?.value, 'https://example.com/caps#ABC123');

    final result = _discoInfoResult(
      id: iq.id!,
      capsKey: 'https://example.com/caps#ABC123',
      feature: 'urn:xmpp:avatar:metadata+notify',
    );
    caps.handleStanza(result);

    expect(pep.requested, isEmpty);
  });

  test('Caps features are tracked per bare JID', () {
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    final storage = FakeStorageService();
    final pep = FakePepManager(
      connection: connection,
      storage: storage,
      selfBareJid: 'user@example.com',
      onUpdate: () {},
    );
    final caps = PepCapsManager(connection: connection, pepManager: pep);

    final presence = _presenceWithCaps(
      fromFullJid: 'alice@example.com/resource',
      node: 'https://example.com/caps',
      ver: 'XYZ999',
    );
    caps.handleStanza(presence);

    final iq = connection.written.last as IqStanza;
    final result = _discoInfoResult(
      id: iq.id!,
      capsKey: 'https://example.com/caps#XYZ999',
      feature: 'urn:xmpp:jingle:1',
    );
    caps.handleStanza(result);

    final features = caps.featuresForBareJid('alice@example.com');
    expect(features, isNotNull);
    expect(features!.contains('urn:xmpp:jingle:1'), isTrue);
  });

  test('Caps features are tracked per full JID', () {
    final account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
    final connection = TestConnection(account);
    final storage = FakeStorageService();
    final pep = FakePepManager(
      connection: connection,
      storage: storage,
      selfBareJid: 'user@example.com',
      onUpdate: () {},
    );
    final caps = PepCapsManager(connection: connection, pepManager: pep);

    final presence = _presenceWithCaps(
      fromFullJid: 'bob@example.com/phone',
      node: 'https://example.com/caps',
      ver: 'FULL1',
    );
    caps.handleStanza(presence);

    final iq = connection.written.last as IqStanza;
    final result = _discoInfoResult(
      id: iq.id!,
      capsKey: 'https://example.com/caps#FULL1',
      feature: 'urn:xmpp:jingle:1',
    );
    caps.handleStanza(result);

    final features = caps.featuresForFullJid('bob@example.com/phone');
    expect(features, isNotNull);
    expect(features!.contains('urn:xmpp:jingle:1'), isTrue);
  });
}
