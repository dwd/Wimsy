import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/encryption/legacy_double_ratchet.dart';
import 'package:wimsy/encryption/legacy_x3dh.dart';

/// Builds a simulated Alice (initiator) / Bob (responder) session pair via
/// our own X3DH. NOTE: self-consistency only, not a known-answer test.
Future<(LegacyRatchetSession, LegacyRatchetSession)> _pair() async {
  final x = X25519();
  final ikA = await x.newKeyPair();
  final ekA = await x.newKeyPair();
  final ikB = await x.newKeyPair();
  final spkB = await x.newKeyPair();
  final opkB = await x.newKeyPair();
  final ikAPub = addDjbType((await ikA.extractPublicKey()).bytes);
  final ikBPub = addDjbType((await ikB.extractPublicKey()).bytes);

  final aliceX = await legacyX3dhInitiator(
    ourIdentityKey: ikA,
    ourBaseKey: ekA,
    theirIdentityKey: ikBPub,
    theirSignedPreKey: (await spkB.extractPublicKey()).bytes,
    theirOneTimePreKey: (await opkB.extractPublicKey()).bytes,
  );
  final bobX = await legacyX3dhReceiver(
    ourIdentityKey: ikB,
    ourSignedPreKey: spkB,
    ourOneTimePreKey: opkB,
    theirIdentityKey: ikAPub,
    theirBaseKey: (await ekA.extractPublicKey()).bytes,
  );
  final alice = await LegacyRatchetSession.initiator(
    x3dh: aliceX,
    ourIdentityPublicKey: ikAPub,
    theirIdentityPublicKey: ikBPub,
    theirSignedPreKey: (await spkB.extractPublicKey()).bytes,
  );
  final bob = await LegacyRatchetSession.responder(
    x3dh: bobX,
    ourIdentityPublicKey: ikBPub,
    theirIdentityPublicKey: ikAPub,
    ourSignedPreKey: spkB,
  );
  return (alice, bob);
}

List<int> _b(String s) => utf8.encode(s);
String _s(List<int> b) => utf8.decode(b);

void main() {
  test('in-order messages both directions across ratchet steps', () async {
    final (alice, bob) = await _pair();
    for (var i = 0; i < 3; i++) {
      expect(_s(await bob.decrypt(await alice.encrypt(_b('a$i')))), 'a$i');
    }
    for (var i = 0; i < 2; i++) {
      expect(_s(await alice.decrypt(await bob.encrypt(_b('b$i')))), 'b$i');
    }
    expect(_s(await bob.decrypt(await alice.encrypt(_b('a3')))), 'a3');
    expect(_s(await alice.decrypt(await bob.encrypt(_b('b2')))), 'b2');
  });

  test(
    'out-of-order messages within a chain and across a ratchet step',
    () async {
      final (alice, bob) = await _pair();
      final m0 = await alice.encrypt(_b('m0'));
      final m1 = await alice.encrypt(_b('m1'));
      final m2 = await alice.encrypt(_b('m2'));
      expect(_s(await bob.decrypt(m2)), 'm2');
      expect(_s(await bob.decrypt(m0)), 'm0');

      // Bob replies (new ratchet), Alice answers on a new chain, then the
      // late m1 from the old chain finally arrives at Bob.
      final r0 = await bob.encrypt(_b('r0'));
      expect(_s(await alice.decrypt(r0)), 'r0');
      final n0 = await alice.encrypt(_b('n0'));
      expect(_s(await bob.decrypt(n0)), 'n0');
      expect(_s(await bob.decrypt(m1)), 'm1');
    },
  );

  test('replay is rejected and tampered MAC does not disturb state', () async {
    final (alice, bob) = await _pair();
    final m0 = await alice.encrypt(_b('m0'));
    final m1 = await alice.encrypt(_b('m1'));
    expect(_s(await bob.decrypt(m0)), 'm0');
    await expectLater(bob.decrypt(m0), throwsA(isA<LegacyRatchetException>()));

    final bad = List<int>.from(m1)..[m1.length - 1] ^= 0x01;
    await expectLater(bob.decrypt(bad), throwsA(isA<LegacyRatchetException>()));
    // The genuine message still decrypts afterwards.
    expect(_s(await bob.decrypt(m1)), 'm1');
  });

  test(
    'a forged message with a new ratchet key does not alter state',
    () async {
      final (alice, bob) = await _pair();
      final (mallory, _) = await _pair();
      final forged = await mallory.encrypt(_b('evil'));
      await expectLater(
        bob.decrypt(forged),
        throwsA(isA<LegacyRatchetException>()),
      );
      expect(_s(await bob.decrypt(await alice.encrypt(_b('ok')))), 'ok');
    },
  );

  test('wrong sender/receiver identity order fails MAC', () async {
    final (alice, bob) = await _pair();
    final m = await alice.encrypt(_b('x'));
    final swapped = LegacyRatchetSession.fromJson({
      ...bob.toJson(),
      'ourIdentity': base64Encode(bob.theirIdentityPublicKey),
      'theirIdentity': base64Encode(bob.ourIdentityPublicKey),
    });
    await expectLater(
      swapped.decrypt(m),
      throwsA(isA<LegacyRatchetException>()),
    );
  });

  test('too-far-ahead counter is rejected', () async {
    final (alice, bob) = await _pair();
    alice.senderIndex = kMaxSkipAhead + 5;
    final m = await alice.encrypt(_b('far'));
    await expectLater(bob.decrypt(m), throwsA(isA<LegacyRatchetException>()));
  });

  test('state survives a JSON round trip mid-conversation', () async {
    final (alice, bob) = await _pair();
    final m0 = await alice.encrypt(_b('m0'));
    final m2 = (await alice.encrypt(_b('m1')), await alice.encrypt(_b('m2')));
    expect(_s(await bob.decrypt(m2.$2)), 'm2'); // caches skipped m1
    var bob2 = LegacyRatchetSession.fromJson(
      jsonDecode(jsonEncode(bob.toJson())) as Map<String, dynamic>,
    );
    expect(_s(await bob2.decrypt(m0)), 'm0');
    expect(_s(await bob2.decrypt(m2.$1)), 'm1');
    final r = await bob2.encrypt(_b('reply'));
    bob2 = LegacyRatchetSession.fromJson(
      jsonDecode(jsonEncode(bob2.toJson())) as Map<String, dynamic>,
    );
    expect(_s(await alice.decrypt(r)), 'reply');
    expect(_s(await bob2.decrypt(await alice.encrypt(_b('again')))), 'again');
  });
}
