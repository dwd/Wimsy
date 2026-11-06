import 'package:xmpp_stone/xmpp_stone.dart';

/// Trust level of a contact's device or key as understood by an
/// [EncryptionBackend]. Mirrors the trust states commonly used by OMEMO/OX
/// style end-to-end encryption flows (Trust-on-First-Use, explicit
/// verification via fingerprint comparison, explicit distrust, and
/// revocation of a previously trusted key/device).
enum TrustState {
  /// The key/device was accepted automatically (Trust-on-First-Use) and has
  /// not been explicitly verified by the user.
  tofu,

  /// The user has explicitly verified this key/device (e.g. by comparing
  /// fingerprints out-of-band).
  verified,

  /// The key/device is known but explicitly not trusted.
  untrusted,

  /// The key/device was trusted at some point but has since been revoked
  /// (e.g. the device was removed, or the user withdrew their verification).
  revoked,
}

/// The result of attempting to encrypt an outgoing message with an
/// [EncryptionBackend].
///
/// The payload is modelled as the already-built `<encrypted/>` (or
/// protocol-equivalent) [XmppElement] that the caller should attach as a
/// child of the outgoing `<message/>` stanza, since every supported
/// protocol (OMEMO, OMEMO2, OX) ultimately contributes one or more XML
/// elements to the stanza. Backends may additionally expose a plaintext
/// fallback body (e.g. a warning body such as "This message is encrypted
/// with OMEMO2...") via [fallbackBody] for clients that don't support the
/// scheme.
class EncryptedPayload {
  EncryptedPayload({
    required this.element,
    this.fallbackBody,
  });

  /// The element to attach to the outgoing stanza (e.g. `<encrypted/>`
  /// in the protocol's namespace).
  final XmppElement element;

  /// An optional plaintext fallback `<body/>` text for clients that do not
  /// understand/support the encryption protocol used.
  final String? fallbackBody;
}

/// The result of attempting to decrypt an incoming stanza with an
/// [EncryptionBackend].
class DecryptResult {
  DecryptResult({
    required this.plaintext,
    required this.protocolId,
    required this.senderTrust,
    this.error,
  });

  /// The decrypted plaintext body, or `null` if the stanza could not be
  /// decrypted (see [error] for details).
  final String? plaintext;

  /// The identifier of the protocol that produced this result (e.g.
  /// `'omemo2'`), matching [EncryptionBackend.protocolId].
  final String protocolId;

  /// The trust state of the sender's key/device that produced this
  /// message, as currently known to the backend.
  final TrustState senderTrust;

  /// A human-readable description of why decryption failed, when
  /// [plaintext] is `null`.
  final String? error;
}

/// Shared interface implemented by every end-to-end-encryption backend
/// supported by Wimsy (e.g. OMEMO, OMEMO2, OX). An `EncryptionManager` (to
/// be introduced in a later step of the E2EE plan) will select and drive
/// the appropriate backend per conversation/recipient.
abstract class EncryptionBackend {
  /// Short, stable identifier for this backend's protocol, e.g. `'omemo'`,
  /// `'omemo2'`, or `'ox'`. Used for bookkeeping (e.g. tagging
  /// [DecryptResult]s and persisted trust state) and must be unique
  /// across the set of active backends.
  String get protocolId;

  /// Encrypts [plaintext] for sending to [toBareJid], returning the
  /// resulting [EncryptedPayload] ready to attach to the outgoing stanza.
  Future<EncryptedPayload> encryptForSend(String toBareJid, String plaintext);

  /// Attempts to decrypt an incoming [stanza] (typically a `<message/>`)
  /// that may contain a payload encrypted with this backend's protocol.
  Future<DecryptResult> decryptIncoming(XmppElement stanza);

  /// Publishes this backend's identity material (e.g. an OMEMO device
  /// bundle/device-list, or an OX public key) via PEP so that contacts
  /// can discover it and start encrypted sessions with us.
  Future<void> publishIdentity();

  /// Returns the currently known [TrustState] for [bareJid], optionally
  /// scoped to a specific device or key via [deviceOrKeyId]. When
  /// [deviceOrKeyId] is omitted, implementations should return an
  /// aggregate/representative trust state for the JID (e.g. the most
  /// permissive trust across its devices), or [TrustState.untrusted] if
  /// nothing is known yet.
  Future<TrustState> trustStateFor(String bareJid, {String? deviceOrKeyId});

  /// Updates the trust state for the device/key identified by
  /// [deviceOrKeyId] belonging to [bareJid].
  Future<void> setTrust(String bareJid, String deviceOrKeyId, TrustState state);
}
