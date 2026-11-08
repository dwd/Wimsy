/// Pure-Dart implementation of libsignal's Double Ratchet session
/// (`SessionCipher`/`SessionState`) as used by legacy OMEMO (XEP-0384
/// v0.3.0) clients: Conversations, Gajim, Dino, ...
///
/// This is stage two of replacing `omemo_dart`'s crypto core, whose ratchet
/// and MAC scheme are incompatible with real clients. It builds on
/// `legacy_x3dh.dart` (which supplies the initial root/chain key) and
/// `legacy_signal_wire.dart` (the on-the-wire `SignalMessage` layout).
/// Only `package:cryptography` primitives are used; no libsignal code was
/// copied.
///
/// Key derivations (all HKDF is HKDF-SHA256):
///  * Root KDF (DH ratchet step): `HKDF(ikm = DH output, salt = rootKey,
///    info = "WhisperRatchet", 64 bytes)` -> new root key (32) || new chain
///    key (32).
///  * Chain KDF: `messageKeySeed = HMAC-SHA256(chainKey, 0x01)`,
///    `nextChainKey = HMAC-SHA256(chainKey, 0x02)`.
///  * Message keys: `HKDF(ikm = messageKeySeed, salt = 32 zero bytes,
///    info = "WhisperMessageKeys", 80 bytes)` -> AES-256 key (32) ||
///    HMAC key (32) || CBC IV (16).
///  * Payload: AES-256-CBC with PKCS#7 padding.
///  * MAC: `HMAC-SHA256(macKey, senderIdentity || receiverIdentity ||
///    serializedMessageWithoutMac)[0:8]`, where both identity keys are the
///    33-byte DJB-prefixed form and `serializedMessageWithoutMac` is the
///    version byte plus protobuf body. The *sender's* identity key comes
///    first (libsignal's `SignalMessage.getMac(senderIdentityKey,
///    receiverIdentityKey, macKey, serialized)`).
///
/// Ratchet state machine (mirrors libsignal):
///  * Initiator ("Alice", after X3DH): receiver chain = (their signed
///    prekey, X3DH chain key); a fresh ratchet key pair is generated and a
///    root-KDF step with DH(theirSignedPreKey, ourNewRatchet) produces the
///    sender chain.
///  * Responder ("Bob"): sender chain = (our signed prekey pair, X3DH chain
///    key), root = X3DH root key; no receiver chain yet. The first incoming
///    message triggers a DH ratchet step.
///  * Incoming message with an unknown ratchet key: receiver chain from
///    root-KDF(DH(theirRatchet, ourRatchetPriv)), then a new ratchet pair
///    and sender chain from root-KDF(DH(theirRatchet, ourNewRatchet));
///    `previousCounter` = length of the sender chain we are leaving.
///  * Out-of-order messages: message keys for skipped counters are cached
///    per receiver chain (max [kMaxSkippedMessageKeys] per chain, at most
///    [kMaxReceiverChains] chains remembered) and consumed exactly once.
///
/// Decryption is transactional: the session is only mutated if the MAC
/// verified and the payload decrypted, so a forged message cannot advance
/// or corrupt state.
///
/// VERIFICATION STATUS: verified by self-consistency tests only (two
/// instances of this implementation talking to each other, in order and out
/// of order). No external known-answer vectors or live libsignal client were
/// available. The details most worth double-checking against an
/// authoritative libsignal source are: the MAC identity-key order (sender
/// first), the "WhisperRatchet"/"WhisperMessageKeys" info strings and the
/// zero salt for the message-keys HKDF, and the chain counter starting at 0.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'legacy_signal_wire.dart';
import 'legacy_x3dh.dart';

/// Maximum number of messages we are willing to skip ahead in one chain.
const int kMaxSkipAhead = 2000;

/// Maximum cached skipped message keys per receiver chain.
const int kMaxSkippedMessageKeys = 2000;

/// Maximum number of old receiver chains retained.
const int kMaxReceiverChains = 5;

/// Thrown when a message cannot be decrypted (bad MAC, replay, too far
/// ahead, malformed).
class LegacyRatchetException implements Exception {
  LegacyRatchetException(this.message);

  final String message;

  @override
  String toString() => 'LegacyRatchetException: $message';
}

class _MessageKeys {
  _MessageKeys(this.cipherKey, this.macKey, this.iv);

  final Uint8List cipherKey;
  final Uint8List macKey;
  final Uint8List iv;

  Map<String, dynamic> toJson() => {
    'c': base64Encode(cipherKey),
    'm': base64Encode(macKey),
    'i': base64Encode(iv),
  };

  factory _MessageKeys.fromJson(Map<String, dynamic> j) => _MessageKeys(
    base64Decode(j['c'] as String),
    base64Decode(j['m'] as String),
    base64Decode(j['i'] as String),
  );
}

class _ReceiverChain {
  _ReceiverChain(this.ratchetPublicKey, this.chainKey, this.index);

  /// Raw 32-byte peer ratchet public key identifying this chain.
  final Uint8List ratchetPublicKey;
  Uint8List chainKey;
  int index;

  /// Cached keys for counters we skipped, keyed by counter.
  final Map<int, _MessageKeys> skipped = {};

  _ReceiverChain clone() {
    final c = _ReceiverChain(
      Uint8List.fromList(ratchetPublicKey),
      Uint8List.fromList(chainKey),
      index,
    );
    c.skipped.addAll(skipped);
    return c;
  }

  Map<String, dynamic> toJson() => {
    'r': base64Encode(ratchetPublicKey),
    'k': base64Encode(chainKey),
    'n': index,
    's': {for (final e in skipped.entries) '${e.key}': e.value.toJson()},
  };

  factory _ReceiverChain.fromJson(Map<String, dynamic> j) {
    final c = _ReceiverChain(
      base64Decode(j['r'] as String),
      base64Decode(j['k'] as String),
      j['n'] as int,
    );
    (j['s'] as Map<String, dynamic>).forEach((k, v) {
      c.skipped[int.parse(k)] = _MessageKeys.fromJson(
        v as Map<String, dynamic>,
      );
    });
    return c;
  }
}

final _aes = AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty);

Future<Uint8List> _hmac(List<int> key, List<int> data) async {
  final mac = await Hmac.sha256().calculateMac(data, secretKey: SecretKey(key));
  return Uint8List.fromList(mac.bytes);
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Future<_MessageKeys> _deriveMessageKeys(Uint8List chainKey) async {
  final seed = await _hmac(chainKey, const [0x01]);
  final okm = await legacyHkdf(
    ikm: seed,
    info: 'WhisperMessageKeys',
    length: 80,
  );
  return _MessageKeys(
    Uint8List.sublistView(okm, 0, 32),
    Uint8List.sublistView(okm, 32, 64),
    Uint8List.sublistView(okm, 64, 80),
  );
}

Future<Uint8List> _nextChainKey(Uint8List chainKey) =>
    _hmac(chainKey, const [0x02]);

/// Root KDF; returns (newRootKey, newChainKey).
Future<(Uint8List, Uint8List)> _rootKdf(
  Uint8List rootKey,
  Uint8List dhOutput,
) async {
  final okm = await legacyHkdf(
    ikm: dhOutput,
    salt: rootKey,
    info: 'WhisperRatchet',
    length: 64,
  );
  return (
    Uint8List.sublistView(okm, 0, 32),
    Uint8List.sublistView(okm, 32, 64),
  );
}

Future<Uint8List> _computeMac(
  List<int> senderIdentity,
  List<int> receiverIdentity,
  List<int> macKey,
  List<int> serializedWithoutMac,
) async {
  final full = await _hmac(macKey, [
    ...senderIdentity,
    ...receiverIdentity,
    ...serializedWithoutMac,
  ]);
  return Uint8List.sublistView(full, 0, kSignalMessageMacLength);
}

/// One Double Ratchet session with one remote device.
///
/// Create with [LegacyRatchetSession.initiator] or
/// [LegacyRatchetSession.responder], then [encrypt]/[decrypt]. State can
/// be persisted with [toJson]/[LegacyRatchetSession.fromJson]; callers
/// must persist after every successful [encrypt]/[decrypt].
class LegacyRatchetSession {
  LegacyRatchetSession._({
    required this.ourIdentityPublicKey,
    required this.theirIdentityPublicKey,
    required this.rootKey,
    required this.ourRatchetPrivate,
    required this.ourRatchetPublic,
    required this.senderChainKey,
    required this.senderIndex,
    required this.previousCounter,
    required this.receiverChains,
  });

  /// Our identity public key, 33-byte DJB-prefixed.
  final Uint8List ourIdentityPublicKey;

  /// Their identity public key, 33-byte DJB-prefixed.
  final Uint8List theirIdentityPublicKey;

  Uint8List rootKey;
  Uint8List ourRatchetPrivate;
  Uint8List ourRatchetPublic;
  Uint8List senderChainKey;

  /// Counter of the next message we will send in the current sender chain.
  int senderIndex;

  /// Length of the previous sender chain, sent as `previousCounter`.
  int previousCounter;

  /// Receiver chains, oldest first. (The element type is deliberately
  /// library-private: callers should treat the chains as opaque and only
  /// persist them via [toJson].)
  // ignore: library_private_types_in_public_api
  List<_ReceiverChain> receiverChains;

  /// Creates the initiator side ("Alice") from an X3DH [x3dh] result.
  /// [theirSignedPreKey] is the responder's signed prekey public key (raw
  /// or DJB-prefixed), which acts as their initial ratchet key.
  static Future<LegacyRatchetSession> initiator({
    required LegacyX3dhResult x3dh,
    required List<int> ourIdentityPublicKey,
    required List<int> theirIdentityPublicKey,
    required List<int> theirSignedPreKey,
  }) async {
    final theirRatchet = stripDjbType(theirSignedPreKey);
    final ratchetPair = await X25519().newKeyPair();
    final priv = Uint8List.fromList(await ratchetPair.extractPrivateKeyBytes());
    final pub = Uint8List.fromList(
      (await ratchetPair.extractPublicKey()).bytes,
    );
    final dh = await legacyDh(ratchetPair, theirRatchet);
    final (root, chain) = await _rootKdf(x3dh.rootKey, dh);
    return LegacyRatchetSession._(
      ourIdentityPublicKey: _normalizeIdentity(ourIdentityPublicKey),
      theirIdentityPublicKey: _normalizeIdentity(theirIdentityPublicKey),
      rootKey: root,
      ourRatchetPrivate: priv,
      ourRatchetPublic: pub,
      senderChainKey: chain,
      senderIndex: 0,
      previousCounter: 0,
      receiverChains: [_ReceiverChain(theirRatchet, x3dh.chainKey, 0)],
    );
  }

  /// Creates the responder side ("Bob") from an X3DH [x3dh] result and our
  /// signed prekey pair, which acts as our initial ratchet key.
  static Future<LegacyRatchetSession> responder({
    required LegacyX3dhResult x3dh,
    required List<int> ourIdentityPublicKey,
    required List<int> theirIdentityPublicKey,
    required SimpleKeyPair ourSignedPreKey,
  }) async {
    return LegacyRatchetSession._(
      ourIdentityPublicKey: _normalizeIdentity(ourIdentityPublicKey),
      theirIdentityPublicKey: _normalizeIdentity(theirIdentityPublicKey),
      rootKey: x3dh.rootKey,
      ourRatchetPrivate: Uint8List.fromList(
        await ourSignedPreKey.extractPrivateKeyBytes(),
      ),
      ourRatchetPublic: Uint8List.fromList(
        (await ourSignedPreKey.extractPublicKey()).bytes,
      ),
      senderChainKey: x3dh.chainKey,
      senderIndex: 0,
      previousCounter: 0,
      receiverChains: [],
    );
  }

  static Uint8List _normalizeIdentity(List<int> key) =>
      key.length == 32 ? addDjbType(key) : Uint8List.fromList(key);

  /// Our current ratchet public key, 33-byte DJB-prefixed.
  Uint8List get ourRatchetPublicKey => addDjbType(ourRatchetPublic);

  /// Encrypts [plaintext] into a wire-encoded `SignalMessage` (with
  /// trailing MAC) and advances the sending chain.
  Future<Uint8List> encrypt(List<int> plaintext) async {
    final keys = await _deriveMessageKeys(senderChainKey);
    final box = await _aes.encrypt(
      plaintext,
      secretKey: SecretKey(keys.cipherKey),
      nonce: keys.iv,
    );
    final unsigned = SignalMessageWire(
      version: kLegacySignalWireVersion,
      ratchetKey: ourRatchetPublicKey,
      counter: senderIndex,
      previousCounter: previousCounter,
      ciphertext: box.cipherText,
      mac: const [],
    ).serialize();
    final mac = await _computeMac(
      ourIdentityPublicKey,
      theirIdentityPublicKey,
      keys.macKey,
      unsigned,
    );
    senderChainKey = await _nextChainKey(senderChainKey);
    senderIndex++;
    return Uint8List.fromList([...unsigned, ...mac]);
  }

  /// Verifies and decrypts a wire-encoded `SignalMessage` ([messageBytes],
  /// including the trailing MAC). Throws [LegacyRatchetException] (leaving
  /// the session untouched) on any failure.
  Future<Uint8List> decrypt(List<int> messageBytes) async {
    final SignalMessageWire msg;
    try {
      msg = SignalMessageWire.parse(messageBytes);
    } on LegacySignalWireFormatException catch (e) {
      throw LegacyRatchetException(e.message);
    }
    final theirRatchet = stripDjbType(msg.ratchetKey);

    // Work on copies so that a failure leaves `this` unchanged.
    var root = rootKey;
    var ourPriv = ourRatchetPrivate;
    var ourPub = ourRatchetPublic;
    var sendChain = senderChainKey;
    var sendIndex = senderIndex;
    var prevCounter = previousCounter;
    final chains = receiverChains.map((c) => c.clone()).toList();

    var chain = chains
        .where((c) => _constantTimeEquals(c.ratchetPublicKey, theirRatchet))
        .firstOrNull;
    if (chain == null) {
      final (root1, recvChainKey) = await _rootKdf(
        root,
        await legacyDh(_pairOf(ourPriv, ourPub), theirRatchet),
      );
      final newPair = await X25519().newKeyPair();
      final newPriv = Uint8List.fromList(
        await newPair.extractPrivateKeyBytes(),
      );
      final newPub = Uint8List.fromList(
        (await newPair.extractPublicKey()).bytes,
      );
      final (root2, newSendChain) = await _rootKdf(
        root1,
        await legacyDh(newPair, theirRatchet),
      );
      chain = _ReceiverChain(theirRatchet, recvChainKey, 0);
      chains.add(chain);
      while (chains.length > kMaxReceiverChains) {
        chains.removeAt(0);
      }
      root = root2;
      ourPriv = newPriv;
      ourPub = newPub;
      prevCounter = sendIndex > 0 ? sendIndex - 1 : 0;
      sendChain = newSendChain;
      sendIndex = 0;
    }

    final _MessageKeys keys;
    if (msg.counter < chain.index) {
      final cached = chain.skipped.remove(msg.counter);
      if (cached == null) {
        throw LegacyRatchetException(
          'Duplicate or too-old message (counter ${msg.counter})',
        );
      }
      keys = cached;
    } else {
      if (msg.counter - chain.index > kMaxSkipAhead) {
        throw LegacyRatchetException('Message counter too far ahead');
      }
      while (chain.index < msg.counter) {
        chain.skipped[chain.index] = await _deriveMessageKeys(chain.chainKey);
        chain.chainKey = await _nextChainKey(chain.chainKey);
        chain.index++;
      }
      while (chain.skipped.length > kMaxSkippedMessageKeys) {
        chain.skipped.remove(
          chain.skipped.keys.reduce((a, b) => a < b ? a : b),
        );
      }
      keys = await _deriveMessageKeys(chain.chainKey);
      chain.chainKey = await _nextChainKey(chain.chainKey);
      chain.index++;
    }

    final unsigned = messageBytes.sublist(
      0,
      messageBytes.length - kSignalMessageMacLength,
    );
    final expectedMac = await _computeMac(
      theirIdentityPublicKey,
      ourIdentityPublicKey,
      keys.macKey,
      unsigned,
    );
    if (!_constantTimeEquals(expectedMac, msg.mac)) {
      throw LegacyRatchetException('Bad MAC');
    }
    final List<int> plaintext;
    try {
      plaintext = await _aes.decrypt(
        SecretBox(msg.ciphertext, nonce: keys.iv, mac: Mac.empty),
        secretKey: SecretKey(keys.cipherKey),
      );
    } catch (e) {
      throw LegacyRatchetException('Payload decryption failed: $e');
    }

    // Success: commit.
    rootKey = root;
    ourRatchetPrivate = ourPriv;
    ourRatchetPublic = ourPub;
    senderChainKey = sendChain;
    senderIndex = sendIndex;
    previousCounter = prevCounter;
    receiverChains = chains;
    return Uint8List.fromList(plaintext);
  }

  static SimpleKeyPair _pairOf(Uint8List priv, Uint8List pub) =>
      SimpleKeyPairData(
        priv,
        publicKey: SimplePublicKey(pub, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );

  /// Serializes the full session state (including private ratchet key
  /// material!) for persistence.
  Map<String, dynamic> toJson() => {
    'ourIdentity': base64Encode(ourIdentityPublicKey),
    'theirIdentity': base64Encode(theirIdentityPublicKey),
    'root': base64Encode(rootKey),
    'ratchetPriv': base64Encode(ourRatchetPrivate),
    'ratchetPub': base64Encode(ourRatchetPublic),
    'sendChain': base64Encode(senderChainKey),
    'sendIndex': senderIndex,
    'prevCounter': previousCounter,
    'recvChains': receiverChains.map((c) => c.toJson()).toList(),
  };

  factory LegacyRatchetSession.fromJson(Map<String, dynamic> j) =>
      LegacyRatchetSession._(
        ourIdentityPublicKey: base64Decode(j['ourIdentity'] as String),
        theirIdentityPublicKey: base64Decode(j['theirIdentity'] as String),
        rootKey: base64Decode(j['root'] as String),
        ourRatchetPrivate: base64Decode(j['ratchetPriv'] as String),
        ourRatchetPublic: base64Decode(j['ratchetPub'] as String),
        senderChainKey: base64Decode(j['sendChain'] as String),
        senderIndex: j['sendIndex'] as int,
        previousCounter: j['prevCounter'] as int,
        receiverChains: (j['recvChains'] as List)
            .map((c) => _ReceiverChain.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}
