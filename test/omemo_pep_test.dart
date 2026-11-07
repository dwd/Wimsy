import 'dart:convert';

import 'package:cryptography/cryptography.dart' show KeyPairType;
import 'package:flutter_test/flutter_test.dart';
import 'package:omemo_dart/omemo_dart.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'package:wimsy/encryption/xeddsa.dart';
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

        // Regression: real clients (libsignal's SignedPreKeyRecord) sign
        // the *serialized*, type-byte-prefixed SPK, not the raw 32-byte
        // key we strip above for X3DH/ECDH use. The bundle must retain
        // the original 33-byte wire bytes separately so signature
        // verification checks against what was actually signed, or every
        // real-world legacy-OMEMO session fails with
        // InvalidKeyExchangeSignatureError.
        expect(
          bundle.spkSignatureMessage,
          [0x05, ...rawSpk],
          reason:
              'spkSignatureMessage must be the original DJB-type-prefixed '
              'SPK bytes as received on the wire, not the stripped raw key',
        );
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

    test(
      'full wire+crypto round trip: a genuinely XEdDSA-signed X25519 '
      'bundle, published and re-fetched purely through the production '
      'OmemoPep wire code (no test-side re-implementation of the DJB-byte '
      'or Montgomery->Edwards transforms), verifies successfully via '
      'x3dhFromBundle',
      () async {
        // This closes the gap left by the unit tests above (which only
        // check field-level wire preservation) and by
        // `test/omemo_backend_test.dart`'s x3dhFromBundle test (which
        // signs with a genuine Ed25519 key, not a real client's XEdDSA-
        // over-X25519 scheme) and its FakeOmemoPep-based session tests
        // (which manually mirror the DJB-byte transform instead of going
        // through this file's real `_legacyBundleToElement`/
        // `_legacyBundleFromElement`). Here we build a bundle exactly as
        // `OmemoBackend._generateNewLegacyDevice`/`_legacyBundleFromDevice`
        // do (genuine X25519 identity key, SPK signed via [xeddsaSign]
        // over the DJB-type-prefixed SPK bytes), push it through the real
        // publish/fetch wire round trip, and then feed the result into the
        // real `x3dhFromBundle` signature-verification/session-setup code
        // -- true end-to-end cryptographic validation.
        final ik = await OmemoKeyPair.generateNewPair(KeyPairType.x25519);
        final spk = await OmemoKeyPair.generateNewPair(KeyPairType.x25519);
        final opk = await OmemoKeyPair.generateNewPair(KeyPairType.x25519);

        final rawSpkBytes = await spk.pk.getBytes();
        final djbPrefixedSpkBytes = [0x05, ...rawSpkBytes];
        final signature = xeddsaSign(
          await ik.sk.getBytes(),
          djbPrefixedSpkBytes,
        );

        final rawBundle = OmemoBundle(
          'user2@example.com',
          1,
          base64Encode(rawSpkBytes),
          55,
          base64Encode(signature),
          base64Encode(await ik.pk.getBytes()),
          {7: base64Encode(await opk.pk.getBytes())},
          spkSignatureMessageEncoded: base64Encode(djbPrefixedSpkBytes),
        );

        // Publish via the real `OmemoPep` (exercises `_legacyBundleToElement`,
        // which prepends the libsignal DJB type byte to ik/spk/opk).
        await pep.publishLegacyBundle(rawBundle);
        final publishIq = connection.written.last as IqStanza;
        final publishedBundleElement = publishIq
            .getChild('pubsub')!
            .getChild('publish')!
            .getChild('item')!
            .getChild('bundle')!;

        // Simulate a server echoing that exact same wire element back on
        // fetch, and fetch it via the real `OmemoPep` (exercises
        // `_legacyBundleFromElement`, which strips the DJB type byte and
        // sets `ikIsX25519`/`spkSignatureMessageEncoded` for us).
        connection.respond = (request) {
          final result = IqStanza(request.id, IqStanzaType.RESULT);
          final pubsub = XmppElement()..name = 'pubsub';
          pubsub.addAttribute(
            XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'),
          );
          final items = XmppElement()..name = 'items';
          final item = XmppElement()..name = 'item';
          item.addChild(publishedBundleElement);
          items.addChild(item);
          pubsub.addChild(items);
          result.addChild(pubsub);
          return result;
        };

        final fetchedBundle = await pep.fetchLegacyBundle(
          'user2@example.com',
          1,
        );
        expect(fetchedBundle, isNotNull);
        expect(fetchedBundle!.ikIsX25519, isTrue);

        // Genuine end-to-end crypto check: a different real contact
        // initiating a session to this bundle must find the SPK signature
        // valid.
        final initiatorIk = await OmemoKeyPair.generateNewPair(
          KeyPairType.x25519,
        );
        final result = await x3dhFromBundle(fetchedBundle, initiatorIk);
        expect(
          result.isType<InvalidKeyExchangeSignatureError>(),
          isFalse,
          reason:
              'a genuinely XEdDSA-signed, real-world-shaped legacy-OMEMO '
              'bundle, round-tripped purely through the production publish/'
              'fetch wire code, must verify successfully',
        );
        expect(result.isType<X3DHAliceResult>(), isTrue);
      },
    );
  });

  group('OMEMO/OMEMO2 PEP nodes force pubsub#access_model = open', () {
    // XEP-0384's device-list/bundle nodes must be readable by any contact
    // without a prior subscription/whitelist entry -- exactly the
    // situation when a session is first being established. Without
    // explicitly asserting `open` via `<publish-options>`, these nodes
    // would end up with whatever access model the server defaults newly
    // auto-created PEP nodes to (implementation-defined per XEP-0060
    // §7.1.4), which could silently make them unreadable.
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

    String? accessModelOf(IqStanza iq) {
      final form = iq.getChild('pubsub')?.getChild('publish-options')?.getChild('x');
      if (form == null) return null;
      for (final field in form.children.where((c) => c.name == 'field')) {
        if (field.getAttribute('var')?.value == 'pubsub#access_model') {
          return field.getChild('value')?.textValue;
        }
      }
      return null;
    }

    test('publishDeviceList (OMEMO2) asserts access_model = open', () async {
      await pep.publishDeviceList([1]);
      final iq = connection.written.last as IqStanza;
      expect(accessModelOf(iq), 'open');
    });

    test('publishBundle (OMEMO2) asserts access_model = open', () async {
      final bundle = OmemoBundle(
        'user@example.com',
        1,
        base64Encode(List<int>.generate(32, (i) => i)),
        1,
        base64Encode([1, 2, 3]),
        base64Encode(List<int>.generate(32, (i) => 32 + i)),
        const {},
      );
      await pep.publishBundle(bundle);
      final iq = connection.written.last as IqStanza;
      expect(accessModelOf(iq), 'open');
    });

    test('publishLegacyDeviceList asserts access_model = open', () async {
      await pep.publishLegacyDeviceList([1]);
      final iq = connection.written.last as IqStanza;
      expect(accessModelOf(iq), 'open');
    });

    test('publishLegacyBundle asserts access_model = open', () async {
      final bundle = OmemoBundle(
        'user@example.com',
        1,
        base64Encode(List<int>.generate(32, (i) => i)),
        1,
        base64Encode([1, 2, 3]),
        base64Encode(List<int>.generate(32, (i) => 32 + i)),
        const {},
      );
      await pep.publishLegacyBundle(bundle);
      final iq = connection.written.last as IqStanza;
      expect(accessModelOf(iq), 'open');
    });

    test(
      'on precondition-not-met, reconfigures the node to open and retries '
      'the publish, succeeding on the second attempt',
      () async {
        var publishAttempts = 0;
        connection.respond = (request) {
          final pubsub = request.getChild('pubsub');
          final publish = pubsub?.getChild('publish');
          if (publish != null) {
            publishAttempts++;
            if (publishAttempts == 1) {
              final result = IqStanza(request.id, IqStanzaType.ERROR);
              final error = XmppElement()..name = 'error';
              final condition = XmppElement()..name = 'precondition-not-met';
              condition.addAttribute(
                XmppAttribute(
                  'xmlns',
                  'http://jabber.org/protocol/pubsub#errors',
                ),
              );
              error.addChild(condition);
              result.addChild(error);
              return result;
            }
          }
          return IqStanza(request.id, IqStanzaType.RESULT);
        };

        await pep.publishLegacyDeviceList([1]);

        expect(publishAttempts, 2);
        // A `pubsub#owner` reconfigure (`type="set"`) IQ should have been
        // sent between the failed and successful publish attempts (a
        // `type="get"` IQ fetching the node's current config form is also
        // sent first, to learn which fields it actually supports -- see
        // the next test).
        final configureIq = connection.written.firstWhere(
          (s) =>
              s is IqStanza &&
              s.type == IqStanzaType.SET &&
              s.getChild('pubsub')?.getAttribute('xmlns')?.value ==
                  'http://jabber.org/protocol/pubsub#owner',
        ) as IqStanza;
        final configForm = configureIq
            .getChild('pubsub')
            ?.getChild('configure')
            ?.getChild('x');
        final accessModelField = configForm?.children
            .where((c) => c.name == 'field')
            .firstWhere(
              (f) => f.getAttribute('var')?.value == 'pubsub#access_model',
            );
        expect(accessModelField?.getChild('value')?.textValue, 'open');

        // Final publish (second attempt) must have succeeded.
        final finalPublishIq = connection.written.lastWhere(
          (s) =>
              s is IqStanza &&
              s.getChild('pubsub')?.getChild('publish') != null,
        ) as IqStanza;
        expect(accessModelOf(finalPublishIq), 'open');
      },
    );

    test(
      'when the node does not support pubsub#send_last_published_item, '
      'the retry omits it instead of looping on precondition-not-met '
      'forever',
      () async {
        // Regression test: Conversations could see devices/bundles in the
        // PEP explorer, but never got updates, because some servers never
        // expose `pubsub#send_last_published_item` on the OMEMO
        // devices/bundles node's own configuration form. Asserting that
        // field unconditionally in <publish-options>/<configure> made
        // every single publish -- including the "fixed up" retry after
        // reconfiguring -- fail with the exact same
        // `precondition-not-met`, forever, with no way to recover short of
        // a full reset. See `wimsy.log`.
        var publishAttempts = 0;
        connection.respond = (request) {
          final pubsub = request.getChild('pubsub');
          final getConfigure = request.type == IqStanzaType.GET
              ? pubsub?.getChild('configure')
              : null;
          if (getConfigure != null) {
            // The node's own configuration form doesn't list
            // pubsub#send_last_published_item at all.
            final result = IqStanza(request.id, IqStanzaType.RESULT);
            final resultPubsub = XmppElement()..name = 'pubsub';
            resultPubsub.addAttribute(
              XmppAttribute(
                'xmlns',
                'http://jabber.org/protocol/pubsub#owner',
              ),
            );
            final configure = XmppElement()..name = 'configure';
            final form = XmppElement()..name = 'x';
            form.addAttribute(XmppAttribute('xmlns', 'jabber:x:data'));
            form.addAttribute(XmppAttribute('type', 'result'));
            for (final field in [
              'pubsub#persist_items',
              'pubsub#access_model',
              'pubsub#max_items',
            ]) {
              final f = XmppElement()..name = 'field';
              f.addAttribute(XmppAttribute('var', field));
              form.addChild(f);
            }
            configure.addChild(form);
            resultPubsub.addChild(configure);
            result.addChild(resultPubsub);
            return result;
          }
          final publish = pubsub?.getChild('publish');
          if (publish != null) {
            publishAttempts++;
            final options = pubsub!
                .getChild('publish-options')
                ?.getChild('x');
            final hasUnsupportedField = options?.children
                    .where((c) => c.name == 'field')
                    .any(
                      (f) =>
                          f.getAttribute('var')?.value ==
                          'pubsub#send_last_published_item',
                    ) ??
                false;
            if (publishAttempts == 1 || hasUnsupportedField) {
              final result = IqStanza(request.id, IqStanzaType.ERROR);
              final error = XmppElement()..name = 'error';
              final condition = XmppElement()..name = 'precondition-not-met';
              condition.addAttribute(
                XmppAttribute(
                  'xmlns',
                  'http://jabber.org/protocol/pubsub#errors',
                ),
              );
              error.addChild(condition);
              result.addChild(error);
              return result;
            }
          }
          return IqStanza(request.id, IqStanzaType.RESULT);
        };

        await pep.publishLegacyDeviceList([1]);

        // The final (successful) publish must not have asserted the
        // unsupported field.
        final finalPublishIq = connection.written.lastWhere(
          (s) =>
              s is IqStanza &&
              s.getChild('pubsub')?.getChild('publish') != null,
        ) as IqStanza;
        final finalOptions =
            finalPublishIq.getChild('pubsub')?.getChild('publish-options')?.getChild('x');
        final stillAssertsUnsupportedField = finalOptions?.children
                .where((c) => c.name == 'field')
                .any(
                  (f) =>
                      f.getAttribute('var')?.value ==
                      'pubsub#send_last_published_item',
                ) ??
            false;
        expect(stillAssertsUnsupportedField, isFalse);
        expect(accessModelOf(finalPublishIq), 'open');
      },
    );
  });
}
