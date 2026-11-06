import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omemo_dart/omemo_dart.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/xmpp/omemo_pep.dart';

/// Mirrors the `TestConnection` pattern used by `bookmarks_manager_test.dart`:
/// every GET/SET IQ written via [writeStanza] is captured and, unless
/// [respond] overrides it, immediately echoed back with a bare `RESULT`
/// carrying the same id, simulating the server round-trip that
/// `OmemoPep._sendIqAndWait` waits on.
class TestConnection extends Connection {
  TestConnection(super.account);

  final List<AbstractStanza> written = [];

  IqStanza Function(IqStanza request)? respond;

  @override
  void writeStanza(AbstractStanza stanza) {
    written.add(stanza);
    if (stanza is IqStanza &&
        (stanza.type == IqStanzaType.SET || stanza.type == IqStanzaType.GET) &&
        stanza.id != null) {
      final response =
          respond?.call(stanza) ?? IqStanza(stanza.id, IqStanzaType.RESULT);
      fireNewStanzaEvent(response);
    }
  }

  @override
  void writeNonza(Nonza nonza) {}

  @override
  void write(Object? message) {}
}

void main() {
  group('legacy OMEMO bundle libsignal DJB-type-byte handling', () {
    late XmppAccountSettings account;
    late TestConnection connection;
    late OmemoPep pep;

    setUp(() {
      account = XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
      connection = TestConnection(account);
      pep = OmemoPep(connection);
    });

    tearDown(() {
      pep.dispose();
    });

    OmemoBundle rawBundleFixture() {
      // 32-byte "raw" (un-prefixed) keys, as `omemo_dart` itself produces.
      final ik = base64Encode(List<int>.generate(32, (i) => i));
      final spk = base64Encode(List<int>.generate(32, (i) => 32 + i));
      final opk = base64Encode(List<int>.generate(32, (i) => 64 + i));
      return OmemoBundle(
        'user@example.com',
        1,
        spk,
        42,
        base64Encode([9, 9, 9]),
        ik,
        {7: opk},
      );
    }

    test('publishing our own bundle prepends the DJB type byte (0x05)', () async {
      await pep.publishLegacyBundle(rawBundleFixture());

      final iq = connection.written.last as IqStanza;
      final bundleElement = iq
          .getChild('pubsub')
          ?.getChild('publish')
          ?.getChild('item')
          ?.getChild('bundle');
      expect(bundleElement, isNotNull);

      final ikBytes = base64Decode(
        bundleElement!.getChild('identityKey')!.textValue!.trim(),
      );
      final spkBytes = base64Decode(
        bundleElement.getChild('signedPreKeyPublic')!.textValue!.trim(),
      );
      final opkBytes = base64Decode(
        bundleElement
            .getChild('prekeys')!
            .getChild('preKeyPublic')!
            .textValue!
            .trim(),
      );

      expect(ikBytes.length, 33);
      expect(ikBytes.first, 0x05);
      expect(ikBytes.sublist(1), base64Decode(rawBundleFixture().ikEncoded));

      expect(spkBytes.length, 33);
      expect(spkBytes.first, 0x05);

      expect(opkBytes.length, 33);
      expect(opkBytes.first, 0x05);
    });

    test(
      'fetching a bundle from a real client strips the leading 0x05 type byte',
      () async {
        // Simulate Conversations/Gajim/Dino publishing a bundle whose keys
        // are libsignal-style 33-byte (0x05 + 32 raw bytes) encoded.
        final rawIk = List<int>.generate(32, (i) => i);
        final rawSpk = List<int>.generate(32, (i) => 32 + i);
        final rawOpk = List<int>.generate(32, (i) => 64 + i);

        connection.respond = (request) {
          final result = IqStanza(request.id, IqStanzaType.RESULT);
          final pubsub = XmppElement()..name = 'pubsub';
          pubsub.addAttribute(
            XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
          );
          final items = XmppElement()..name = 'items';
          final item = XmppElement()..name = 'item';
          final bundle = XmppElement()..name = 'bundle';
          bundle.addAttribute(
            XmppAttribute('xmlns', legacyOmemoNamespace),
          );

          final spk = XmppElement()..name = 'signedPreKeyPublic';
          spk.addAttribute(XmppAttribute('signedPreKeyId', '42'));
          spk.textValue = base64Encode([0x05, ...rawSpk]);
          bundle.addChild(spk);

          final spks = XmppElement()..name = 'signedPreKeySignature';
          spks.textValue = base64Encode([9, 9, 9]);
          bundle.addChild(spks);

          final ik = XmppElement()..name = 'identityKey';
          ik.textValue = base64Encode([0x05, ...rawIk]);
          bundle.addChild(ik);

          final prekeys = XmppElement()..name = 'prekeys';
          final pk = XmppElement()..name = 'preKeyPublic';
          pk.addAttribute(XmppAttribute('preKeyId', '7'));
          pk.textValue = base64Encode([0x05, ...rawOpk]);
          prekeys.addChild(pk);
          bundle.addChild(prekeys);

          item.addChild(bundle);
          items.addChild(item);
          pubsub.addChild(items);
          result.addChild(pubsub);
          return result;
        };

        final bundle = await pep.fetchLegacyBundle('test2@dave.cridland.net', 1);
        expect(bundle, isNotNull);

        expect(base64Decode(bundle!.ikEncoded), rawIk);
        expect(base64Decode(bundle.spkEncoded), rawSpk);
        expect(base64Decode(bundle.opksEncoded[7]!), rawOpk);

        // Crucially, the resulting raw 32-byte key must be directly usable
        // by `omemo_dart`'s key-parsing path (this used to throw "expects
        // a public key with 32 bytes, but got: 33 bytes").
        expect(() => bundle.ik, returnsNormally);
        expect(() => bundle.spk, returnsNormally);
      },
    );

    test(
      'fetching a bundle with already-raw (32-byte) keys leaves them unchanged',
      () async {
        final rawBundle = rawBundleFixture();
        connection.respond = (request) {
          final result = IqStanza(request.id, IqStanzaType.RESULT);
          final pubsub = XmppElement()..name = 'pubsub';
          pubsub.addAttribute(
            XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
          );
          final items = XmppElement()..name = 'items';
          final item = XmppElement()..name = 'item';
          final bundle = XmppElement()..name = 'bundle';
          bundle.addAttribute(XmppAttribute('xmlns', legacyOmemoNamespace));

          final spk = XmppElement()..name = 'signedPreKeyPublic';
          spk.addAttribute(
            XmppAttribute('signedPreKeyId', rawBundle.spkId.toString()),
          );
          spk.textValue = rawBundle.spkEncoded;
          bundle.addChild(spk);

          final spks = XmppElement()..name = 'signedPreKeySignature';
          spks.textValue = rawBundle.spkSignatureEncoded;
          bundle.addChild(spks);

          final ik = XmppElement()..name = 'identityKey';
          ik.textValue = rawBundle.ikEncoded;
          bundle.addChild(ik);

          bundle.addChild(XmppElement()..name = 'prekeys');

          item.addChild(bundle);
          items.addChild(item);
          pubsub.addChild(items);
          result.addChild(pubsub);
          return result;
        };

        final fetched =
            await pep.fetchLegacyBundle('user2@example.com', 1);
        expect(fetched, isNotNull);
        expect(fetched!.ikEncoded, rawBundle.ikEncoded);
        expect(fetched.spkEncoded, rawBundle.spkEncoded);
      },
    );
  });
}
