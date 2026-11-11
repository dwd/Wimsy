import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/avatar_metadata.dart';
import '../models/chat_message.dart';
import '../models/contact_entry.dart';
import 'fast_token_record.dart';
import 'iap_cache_record.dart';
import 'secure_store.dart';

class StorageService {
  static const _secureBoxName = 'wimsy_secure';
  static const _saltKey = 'wimsy_salt';
  static const _accountKey = 'account';
  // XEP-0484 FAST tokens, keyed by bare JID, so that a token issued for one
  // account is never presented for another.
  static const _fastTokensKey = 'fast_tokens';
  static const _iapCachesKey = 'iap_caches';
  static const _quicSessionKey = 'quic_session_key';
  static const _saslUserAgentsKey = 'sasl_user_agents';
  static const _rosterKey = 'roster';
  static const _rosterVersionKey = 'roster_version';
  static const _messagesKey = 'messages';
  static const _roomMessagesKey = 'room_messages';
  static const _avatarMetadataKey = 'avatar_metadata';
  static const _avatarBlobsKey = 'avatar_blobs';
  static const _vcardAvatarsKey = 'vcard_avatars';
  static const _vcardAvatarStateKey = 'vcard_avatar_state';
  static const _bookmarksKey = 'bookmarks';
  static const _displayedSyncKey = 'displayed_sync';
  // Timestamps (ISO-8601) for each chat's last-displayed marker, stored
  // alongside the stanzaId so we can fall back to timestamp comparison
  // when the message itself has been evicted from the cache.
  static const _displayedSyncTimestampsKey = 'displayed_sync_timestamps';
  // R1.3: pending (chatJid -> stanza-id) markers we received via MDS but
  // could not yet match against any local message. These are resolved
  // lazily as messages with the matching stanza-id arrive (live or via
  // MAM) and are removed from disk once resolved.
  static const _displayedSyncPendingKey = 'displayed_sync_pending';
  static const _controlMessageOutboxKey = 'control_message_outbox';
  // R5: persisted Entity Capabilities (XEP-0115) cache, keyed by
  // `node#ver`. Values are the disco#info feature lists.
  static const _entityCapsKey = 'entity_caps';
  // R2.1: single global anchor for the newest MAM id we've ingested
  // across all chats. The intent is to enable a unified MAM catch-up
  // query (`<query><x type=submit><field var=after-id>...`) that
  // replaces the per-chat fan-out at connect time. We persist the
  // anchor today; the unified query is a follow-up.
  static const _lastMamIdSeenKey = 'last_mam_id_seen';
  // XEP-0258: the raw `<catalog/>` XML of the last-fetched security-label
  // catalogue (the labels the user is allowed to attach to an outgoing
  // message), so the catalogue is available offline / before the next
  // fetch completes.
  static const _securityLabelCatalogKey = 'security_label_catalog';
  // Per-scope (1:1 bare JID, or 'room:'+room bare JID) latest confirmed
  // mam-id, updated as MAM results arrive and (once catch-up for that scope
  // has completed this session) as trusted live ids arrive. Persisted so a
  // disconnect or crash mid-catch-up resumes from the last confirmed
  // position rather than re-deriving it from the message cache.
  static const _mamLastIdsKey = 'mam_last_ids';
  // Per-scope flag recording whether MAM catch-up last completed for that
  // scope, persisted alongside the id above so the two always agree about
  // how trustworthy the last-known id is.
  static const _mamCatchUpCompleteKey = 'mam_catchup_complete';
  static const int _maxCachedMessageBytes = 20 * 1024 * 1024;

  // ---------------------------------------------------------------------
  // Per-record key prefixes.
  //
  // Hive is an append-only log: every `put` appends the *whole* encoded
  // value and only reclaims the space on compaction. Storing a hot cache as
  // one aggregated map value therefore costs the size of the entire cache on
  // every single update (a 20 MB message cache re-written per received
  // message, a multi-megabyte avatar map re-written per fetched vCard). That
  // write amplification is what grew the box to hundreds of gigabytes, at
  // which point Hive could no longer open it at all because opening a box
  // reads the complete file into memory.
  //
  // The hot caches are therefore stored one record per item: a write now
  // costs the size of that single chat / avatar / caps entry.
  static const _messagePrefix = 'msg:';
  static const _roomMessagePrefix = 'rmsg:';
  static const _avatarBlobPrefix = 'ablob:';
  static const _vcardAvatarPrefix = 'vcav:';
  static const _entityCapsPrefix = 'caps:';
  // XEP-0258: raw SPIF (Security Policy Information File) XML documents
  // fetched from the server's policy IQHandler (`urn:xmpp:sec-label:policy:0`),
  // keyed by policy id, so labels can still be parsed against a known
  // policy offline / before the next fetch completes.
  static const _securityLabelPolicyPrefix = 'seclabelpolicy:';
  // Trust-on-first-use decisions for TLS certificates that failed standard
  // CA validation (e.g. self-signed certificates), keyed by `host:port`, so
  // the user is only prompted once per server certificate.
  static const _trustedCertPrefix = 'trustedcert:';
  // OMEMO2 (urn:xmpp:omemo:2, see lib/encryption/omemo2_backend.dart): the
  // per-contact device list, keyed by bare JID.
  static const _omemo2DeviceListPrefix = 'omemo2dl:';
  // OMEMO2: cached peer device key bundles, keyed by 'bareJid:deviceId'.
  static const _omemo2BundlePrefix = 'omemo2bundle:';
  // OMEMO2: serialised Double Ratchet session state, keyed by
  // 'bareJid:deviceId'.
  static const _omemo2RatchetPrefix = 'omemo2rk:';
  // OMEMO2: Blind-Trust-Before-Verification trust decisions, keyed by
  // 'bareJid:deviceId'.
  static const _omemo2TrustPrefix = 'omemo2trust:';
  // OMEMO2: secure-store key prefix for a local account's identity key
  // material (the `OmemoDevice`, including private keys). Never stored in
  // the (unencrypted-at-rest) Hive box.
  static const _omemo2IdentitySecureKeyPrefix = 'omemo2_identity:';
  // EncryptionManager (lib/encryption/encryption_manager.dart): per-JID
  // selected E2EE protocol id for 1:1 conversations (e.g. 'omemo2').
  static const _encryptionProtocolPrefix = 'encproto:';
  // EncryptionManager: global default encryption policy id ('never',
  // 'ifSupported', or 'always'), applied to conversations with no explicit
  // per-contact choice recorded above. Synced via a private PEP node (see
  // `lib/xmpp/encryption_settings_pep.dart`).
  static const _encryptionDefaultPolicyKey = 'encdefaultpolicy';
  // EncryptionManager: per-cryptosystem enable/disable flag, keyed by
  // protocol id (e.g. 'omemo2'). A disabled cryptosystem is hidden from
  // menus/screens and never auto-selected by the default policy above.
  static const _encryptionProtocolEnabledPrefix = 'encprotoenabled:';
  // TrustStore (lib/encryption/trust_store.dart): generic, protocol-agnostic
  // trust decisions shared by every EncryptionBackend, keyed by
  // 'bareJid:deviceOrKeyId'. Distinct from the OMEMO2-specific
  // Blind-Trust-Before-Verification bookkeeping above, which drives
  // omemo_dart's own session-enablement internals.
  static const _trustStorePrefix = 'trust:';
  // Legacy OMEMO (eu.siacs.conversations.axolotl, see
  // lib/encryption/omemo_backend.dart): mirrors the OMEMO2 prefixes above
  // one-for-one, but kept under distinct keys since legacy-OMEMO and
  // OMEMO2 devices for the same contact are different device
  // lists/namespaces that must be tracked independently.
  static const _omemoDeviceListPrefix = 'omemodl:';
  static const _omemoBundlePrefix = 'omemobundle:';
  static const _omemoRatchetPrefix = 'omemork:';
  // Legacy-OMEMO sessions of our from-scratch libsignal-compatible Double
  // Ratchet (lib/encryption/legacy_double_ratchet.dart); deliberately a
  // different prefix from `omemork:` (omemo_dart's incompatible ratchets).
  static const _legacySignalSessionPrefix = 'omemosig:';
  static const _omemoTrustPrefix = 'omemotrust:';
  static const _omemoIdentitySecureKeyPrefix = 'omemo_identity:';
  // OX (urn:xmpp:openpgp:0, XEP-0373/XEP-0374, see
  // lib/encryption/ox_backend.dart): secure-store key prefix for a local
  // account's OpenPGP private key material. Never stored in the
  // (unencrypted-at-rest) Hive box.
  static const _oxIdentitySecureKeyPrefix = 'ox_identity:';
  // OX: cached peer public keys (armored), keyed by 'bareJid:fingerprint'.
  static const _oxPublicKeyPrefix = 'oxpubkey:';
  // OX: cached list of known OpenPGP key fingerprints per contact, keyed by
  // bare JID, mirroring the OMEMO2 per-contact device list.
  static const _oxFingerprintListPrefix = 'oxfp:';

  /// The maximum number of messages loaded or retained in the local cache per
  /// conversation.
  ///
  /// The initial chat viewport displays 60 messages (`_initialMessageWindowSize`).
  /// Keeping 100 messages per conversation in cache guarantees that the initial
  /// window is rendered immediately on open without network latency, while
  /// leaving headroom for smooth backwards scrolling before paging older history
  /// from the MAM archive on the server. Bounding the cached history per chat
  /// also prevents slow startup decoding, memory bloat, GC pressure, and large
  /// write amplification as the client runs over time.
  @visibleForTesting
  static const int defaultMaxCachedMessagesPerChat = 100;

  @visibleForTesting
  int maxCachedMessagesPerChat = defaultMaxCachedMessagesPerChat;

  /// Above this size the box is considered bloated and is compacted eagerly
  /// rather than waiting for Hive's own (60 overwrites) heuristic. Mutable
  /// so tests can exercise the guard without writing tens of megabytes.
  @visibleForTesting
  int compactThresholdBytes = 32 * 1024 * 1024;

  /// A box larger than this cannot be opened safely (Hive reads the whole
  /// file into memory), so it is salvaged into a fresh box instead.
  @visibleForTesting
  int salvageThresholdBytes = 256 * 1024 * 1024;

  /// Number of hot-path writes between box-size checks.
  static const int _writesBetweenSizeChecks = 32;

  /// Keys worth rescuing from a bloated box. Message/avatar/caps caches are
  /// deliberately *not* salvaged: they are re-fetchable and are exactly the
  /// data that made the file unmanageable.
  static const List<String> _essentialKeys = [
    _accountKey,
    _fastTokensKey,
    _iapCachesKey,
    _quicSessionKey,
    _saslUserAgentsKey,
    _rosterKey,
    _rosterVersionKey,
    _bookmarksKey,
    _displayedSyncKey,
    _displayedSyncTimestampsKey,
    _displayedSyncPendingKey,
    _controlMessageOutboxKey,
    _avatarMetadataKey,
    _vcardAvatarStateKey,
    _lastMamIdSeenKey,
    _securityLabelCatalogKey,
    _mamLastIdsKey,
    _mamCatchUpCompleteKey,
  ];

  /// [secureStore] is only injected by tests; production code uses the
  /// platform keystore implementation.
  StorageService({SecureStore? secureStore})
    : _secureStorage = secureStore ?? createSecureStore();

  final SecureStore _secureStorage;
  Box<dynamic>? _box;
  String? _hivePath;
  int _writesSinceSizeCheck = 0;
  bool _compacting = false;

  /// In-memory mirror of the per-chat message records. Keeping it here means
  /// a message store only has to re-encode (and re-write) the affected chat
  /// instead of reading and re-writing every cached conversation.
  final Map<String, List<ChatMessage>> _messageCache = {};
  final Map<String, List<ChatMessage>> _roomMessageCache = {};

  /// Initializes Hive. [path] is only used by tests, which cannot rely on
  /// the platform's application-documents directory.
  Future<void> initialize({String? path}) async {
    if (path != null) {
      _hivePath = path;
      Hive.init(path);
      return;
    }
    await Hive.initFlutter();
    try {
      _hivePath = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      // Without a path we simply skip the size guard; everything else works.
      _hivePath = null;
    }
  }

  /// FAST tokens belong to a client identity, which must remain stable across
  /// reconnects and application restarts (XEP-0484 section 4.1).
  Future<String> saslUserAgentId(String bareJid) async {
    final box = _box;
    if (box == null) throw StateError('Account storage is locked');
    final stored = box.get(_saslUserAgentsKey);
    final ids = stored is Map
        ? Map<String, dynamic>.from(stored)
        : <String, dynamic>{};
    final previous = ids[bareJid];
    if (previous is String && previous.isNotEmpty) return previous;
    final bytes = _randomBytes(16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    ids[bareJid] = id;
    await box.put(_saslUserAgentsKey, ids);
    await box.flush();
    return id;
  }

  Future<QuicSessionStorageSettings?>? _quicSessionSettingsFuture;

  /// The separate ticket file is encrypted with a random key protected by Hive.
  /// Its key must reach durable storage before Rust can persist any tickets.
  Future<QuicSessionStorageSettings?> quicSessionStorageSettings() {
    if (!isUnlocked) return Future.value(null);
    return _quicSessionSettingsFuture ??= _loadQuicSessionStorageSettings();
  }

  Future<QuicSessionStorageSettings?> _loadQuicSessionStorageSettings() async {
    final box = _box;
    final directory = _hivePath;
    if (kIsWeb || box == null || directory == null) return null;
    final saved = box.get(_quicSessionKey);
    final List<int> key;
    if (saved is List &&
        saved.length == 32 &&
        saved.every((byte) => byte is int && byte >= 0 && byte <= 255)) {
      key = List<int>.from(saved);
    } else {
      key = _randomBytes(32);
      await box.put(_quicSessionKey, key);
      await box.flush();
    }
    return QuicSessionStorageSettings(
      '${Directory(directory).absolute.path}${Platform.pathSeparator}quic-sessions.bin',
      Uint8List.fromList(key),
    );
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
    _quicSessionSettingsFuture = null;
    await _box?.close();
    _box = null;
    _messageCache.clear();
    _roomMessageCache.clear();
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

  /// Loads the persisted FAST (XEP-0484) credentials for [bareJid], or null
  /// when no usable token is stored. Expired tokens are treated as absent and
  /// removed from disk so we do not present them to the server.
  FastTokenRecord? loadFastToken(String bareJid) {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return null;
    }
    final data = box.get(_fastTokensKey);
    if (data is! Map) {
      return null;
    }
    final entry = data[bareJid];
    if (entry is! Map) {
      return null;
    }
    final record = FastTokenRecord.fromMap(Map<String, dynamic>.from(entry));
    if (record == null) {
      return null;
    }
    if (record.isExpired) {
      unawaited(clearFastToken(bareJid));
      return null;
    }
    return record;
  }

  /// Persists the FAST credentials issued for [bareJid], replacing any
  /// previously stored token for that account.
  Future<void> storeFastToken(String bareJid, FastTokenRecord record) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      throw StateError('FAST credential storage is unavailable');
    }
    final existing = box.get(_fastTokensKey);
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(
        existing.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    next[bareJid] = record.toMap();
    await box.put(_fastTokensKey, next);
    await box.flush();
  }

  /// Drops the stored FAST credentials for [bareJid], e.g. after the server
  /// rejected the token, so the next connection authenticates with SCRAM.
  Future<void> clearFastToken(String bareJid) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    final existing = box.get(_fastTokensKey);
    if (existing is! Map || !existing.containsKey(bareJid)) {
      return;
    }
    final next = <String, dynamic>{};
    next.addAll(existing.map((key, value) => MapEntry(key.toString(), value)));
    next.remove(bareJid);
    await box.put(_fastTokensKey, next);
  }

  /// Drops every stored FAST token (forget-account flows).
  Future<void> clearFastTokens() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_fastTokensKey, const <String, dynamic>{});
  }

  /// Forget negotiation shortcuts so a cache reset performs full discovery.
  Future<void> clearIapCaches() async {
    await _box?.delete(_iapCachesKey);
  }

  IapCacheRecord? loadIapCache(String bareJid) {
    final data = _box?.get(_iapCachesKey);
    if (bareJid.isEmpty || data is! Map || data[bareJid] is! Map) return null;
    return IapCacheRecord.fromMap(
      Map<String, dynamic>.from(data[bareJid] as Map),
    );
  }

  Future<void> storeIapCache(String bareJid, IapCacheRecord record) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) return;
    final existing = box.get(_iapCachesKey);
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(
        existing.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    next[bareJid] = record.toMap();
    await box.put(_iapCachesKey, next);
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
          final contact = ContactEntry.fromMap(
            Map<String, dynamic>.from(entry),
          );
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

  String? loadRosterVersion() {
    final box = _box;
    if (box == null) {
      return null;
    }
    final value = box.get(_rosterVersionKey);
    final version = value?.toString();
    return (version == null || version.isEmpty) ? null : version;
  }

  Future<void> storeRosterVersion(String? version) async {
    final box = _box;
    if (box == null) {
      return;
    }
    if (version == null || version.isEmpty) {
      await box.delete(_rosterVersionKey);
      return;
    }
    await box.put(_rosterVersionKey, version);
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
          final bookmark = ContactEntry.fromMap(
            Map<String, dynamic>.from(entry),
          );
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
    await box.put(
      _bookmarksKey,
      bookmarks.map((entry) => entry.toMap()).toList(),
    );
  }

  Map<String, List<ChatMessage>> loadMessages() {
    if (_box == null) {
      return const {};
    }
    return _copyMessageCache(_messageCache);
  }

  Map<String, List<ChatMessage>> loadRoomMessages() {
    if (_box == null) {
      return const {};
    }
    return _copyMessageCache(_roomMessageCache);
  }

  Future<void> storeMessagesForJid(
    String bareJid,
    List<ChatMessage> messages,
  ) async {
    await _storeMessagesForJid(bareJid, messages, isRoom: false);
  }

  Future<void> storeRoomMessagesForJid(
    String roomJid,
    List<ChatMessage> messages,
  ) async {
    await _storeMessagesForJid(roomJid, messages, isRoom: true);
  }

  /// Writes a single conversation. Only the record of [jid] (plus any chat
  /// whose messages the size limit evicted) is re-encoded and written, so the
  /// cost of caching a message no longer scales with the size of the whole
  /// cache.
  Future<void> _storeMessagesForJid(
    String jid,
    List<ChatMessage> messages, {
    required bool isRoom,
  }) async {
    final box = _box;
    if (box == null) {
      return;
    }
    if (jid.isEmpty) {
      if (isRoom) {
        await clearRoomMessages();
      } else {
        _messageCache.clear();
        await _deleteKeysWithPrefix(_messagePrefix);
      }
      return;
    }
    final cache = isRoom ? _roomMessageCache : _messageCache;
    final bounded = messages.length > maxCachedMessagesPerChat
        ? messages.sublist(messages.length - maxCachedMessagesPerChat)
        : messages;
    cache[jid] = List<ChatMessage>.from(bounded);
    final touched = <_MessageCacheKey>{_MessageCacheKey(jid, isRoom)};
    touched.addAll(_enforceMessageCacheLimit());
    await _writeMessageRecords(touched);
    _afterHotWrite();
  }

  Future<void> _writeMessageRecords(Set<_MessageCacheKey> keys) async {
    final box = _box;
    if (box == null || keys.isEmpty) {
      return;
    }
    final writes = <String, dynamic>{};
    final deletes = <String>[];
    for (final key in keys) {
      final cache = key.isRoom ? _roomMessageCache : _messageCache;
      final boxKey = _messageRecordKey(key);
      final list = cache[key.jid];
      if (list == null || list.isEmpty) {
        cache.remove(key.jid);
        if (box.containsKey(boxKey)) {
          deletes.add(boxKey);
        }
        continue;
      }
      writes[boxKey] = list
          .map((message) => message.toMap())
          .toList(growable: false);
    }
    if (deletes.isNotEmpty) {
      await box.deleteAll(deletes);
    }
    if (writes.isNotEmpty) {
      await box.putAll(writes);
    }
  }

  String _messageRecordKey(_MessageCacheKey key) {
    return '${key.isRoom ? _roomMessagePrefix : _messagePrefix}${key.jid}';
  }

  Map<String, List<ChatMessage>> _copyMessageCache(
    Map<String, List<ChatMessage>> cache,
  ) {
    return cache.map(
      (jid, messages) => MapEntry(jid, List<ChatMessage>.from(messages)),
    );
  }

  /// Reads the per-chat message records into memory. Called once when the
  /// box is opened.
  void _seedMessageCaches() {
    final box = _box;
    _messageCache.clear();
    _roomMessageCache.clear();
    if (box == null) {
      return;
    }
    var invalidCache = false;
    for (final key in box.keys) {
      final name = key.toString();
      final bool isRoom;
      final String jid;
      if (name.startsWith(_roomMessagePrefix)) {
        isRoom = true;
        jid = name.substring(_roomMessagePrefix.length);
      } else if (name.startsWith(_messagePrefix)) {
        isRoom = false;
        jid = name.substring(_messagePrefix.length);
      } else {
        continue;
      }
      if (jid.isEmpty) {
        continue;
      }
      final value = box.get(name);
      if (value is! List) {
        continue;
      }
      final rawList = value.length > maxCachedMessagesPerChat
          ? value.sublist(value.length - maxCachedMessagesPerChat)
          : value;
      final messages = <ChatMessage>[];
      for (final raw in rawList) {
        if (raw is! Map) {
          continue;
        }
        final rawMap = Map<String, dynamic>.from(raw);
        final rawXml = rawMap['rawXml']?.toString() ?? '';
        if (rawXml.isEmpty) {
          invalidCache = true;
          continue;
        }
        final message = ChatMessage.fromMap(rawMap);
        if (message != null) {
          messages.add(message);
        }
      }
      if (messages.isEmpty) {
        continue;
      }
      (isRoom ? _roomMessageCache : _messageCache)[jid] = messages;
    }
    if (invalidCache) {
      // A record written by an older, incompatible format: drop the whole
      // message cache rather than showing half-decoded history.
      _clearMessageCaches();
    }
  }

  /// Trims the oldest messages until the in-memory cache is back below
  /// [_maxCachedMessageBytes]. Returns the chats whose records changed so the
  /// caller can persist exactly those.
  Set<_MessageCacheKey> _enforceMessageCacheLimit() {
    var totalBytes =
        _totalMessageBytes(_messageCache) +
        _totalMessageBytes(_roomMessageCache);
    if (totalBytes <= _maxCachedMessageBytes) {
      return const {};
    }
    final all = <_CachedMessageRef>[];
    for (final entry in _messageCache.entries) {
      for (final message in entry.value) {
        all.add(
          _CachedMessageRef(
            entry.value,
            message,
            _MessageCacheKey(entry.key, false),
          ),
        );
      }
    }
    for (final entry in _roomMessageCache.entries) {
      for (final message in entry.value) {
        all.add(
          _CachedMessageRef(
            entry.value,
            message,
            _MessageCacheKey(entry.key, true),
          ),
        );
      }
    }
    all.sort((a, b) => a.message.timestamp.compareTo(b.message.timestamp));
    final touched = <_MessageCacheKey>{};
    var index = 0;
    while (totalBytes > _maxCachedMessageBytes && index < all.length) {
      final ref = all[index];
      if (ref.list.remove(ref.message)) {
        totalBytes -= _messageBytes(ref.message);
        touched.add(ref.cacheKey);
      }
      index += 1;
    }
    _messageCache.removeWhere((_, list) => list.isEmpty);
    _roomMessageCache.removeWhere((_, list) => list.isEmpty);
    return touched;
  }

  int _totalMessageBytes(Map<String, List<ChatMessage>> messages) {
    var total = 0;
    for (final list in messages.values) {
      for (final message in list) {
        total += _messageBytes(message);
      }
    }
    return total;
  }

  int _messageBytes(ChatMessage message) {
    final raw = message.rawXml ?? '';
    return utf8.encode(raw).length;
  }

  void _clearMessageCaches() {
    _messageCache.clear();
    _roomMessageCache.clear();
    if (_box == null) {
      return;
    }
    unawaited(_deleteKeysWithPrefix(_messagePrefix));
    unawaited(_deleteKeysWithPrefix(_roomMessagePrefix));
  }

  Future<void> clearRoster() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_rosterKey, const <dynamic>[]);
    await box.delete(_rosterVersionKey);
  }

  Future<void> clearBookmarks() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_bookmarksKey, const <dynamic>[]);
  }

  Future<void> clearDisplayedSync() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_displayedSyncKey, const <String, dynamic>{});
    await box.put(_displayedSyncTimestampsKey, const <String, dynamic>{});
    // R1.3: also wipe the pending-resolution map so disconnect/forget
    // genuinely clears all MDS-related state.
    await box.put(_displayedSyncPendingKey, const <String, dynamic>{});
  }

  Future<void> clearRoomMessages() async {
    _roomMessageCache.clear();
    await _deleteKeysWithPrefix(_roomMessagePrefix);
  }

  Map<String, AvatarMetadata> loadAvatarMetadata() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(
      _avatarMetadataKey,
      defaultValue: const <String, dynamic>{},
    );
    if (data is Map) {
      final result = <String, AvatarMetadata>{};
      for (final entry in data.entries) {
        if (entry.value is Map) {
          final meta = AvatarMetadata.fromMap(
            Map<String, dynamic>.from(entry.value as Map),
          );
          if (meta != null) {
            result[entry.key.toString()] = meta;
          }
        }
      }
      return result;
    }
    return const {};
  }

  Map<String, String> loadDisplayedSync() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(
      _displayedSyncKey,
      defaultValue: const <String, dynamic>{},
    );
    if (data is Map) {
      final result = <String, String>{};
      for (final entry in data.entries) {
        final key = entry.key.toString();
        final value = entry.value?.toString() ?? '';
        if (key.isNotEmpty && value.isNotEmpty) {
          result[key] = value;
        }
      }
      return result;
    }
    return const {};
  }

  Map<String, DateTime> loadDisplayedSyncTimestamps() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(
      _displayedSyncTimestampsKey,
      defaultValue: const <String, dynamic>{},
    );
    if (data is! Map) {
      return const {};
    }
    final result = <String, DateTime>{};
    for (final entry in data.entries) {
      final ts = DateTime.tryParse(entry.value.toString());
      if (ts != null) {
        result[entry.key.toString()] = ts;
      }
    }
    return result;
  }

  Future<void> storeDisplayedSyncTimestamps(
    Map<String, DateTime> timestamps,
  ) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(
      _displayedSyncTimestampsKey,
      timestamps.map((k, v) => MapEntry(k, v.toIso8601String())),
    );
  }

  Future<void> storeDisplayedSync(Map<String, String> sync) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_displayedSyncKey, Map<String, String>.from(sync));
  }

  /// R1.3: load pending displayed-sync markers — i.e. (chatJid -> stanzaId)
  /// pairs we received from the MDS node but could not yet match against
  /// any locally cached message. The XmppService resolves these as
  /// matching messages arrive (live, via MAM, or via Carbons).
  Map<String, String> loadDisplayedSyncPending() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(
      _displayedSyncPendingKey,
      defaultValue: const <String, dynamic>{},
    );
    if (data is Map) {
      final result = <String, String>{};
      for (final entry in data.entries) {
        final key = entry.key.toString();
        final value = entry.value?.toString() ?? '';
        if (key.isNotEmpty && value.isNotEmpty) {
          result[key] = value;
        }
      }
      return result;
    }
    return const {};
  }

  /// R1.3: persist the pending-resolution map.
  Future<void> storeDisplayedSyncPending(Map<String, String> pending) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_displayedSyncPendingKey, Map<String, String>.from(pending));
  }

  List<Map<String, dynamic>> loadControlMessageOutbox() {
    final data = _box?.get(_controlMessageOutboxKey, defaultValue: const []);
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: false);
  }

  Future<void> storeControlMessageOutbox(
    List<Map<String, dynamic>> entries,
  ) async {
    final box = _box;
    if (box == null) return;
    await box.put(_controlMessageOutboxKey, entries);
  }

  /// R5: load the persisted Entity Capabilities (XEP-0115) cache. The
  /// returned map is keyed by `node#ver` and the values are the verified
  /// `disco#info` feature lists.
  ///
  /// We persist this cache to skip the per-`node#ver` `disco#info` IQ
  /// fan-out at connect time when MUC presence broadcasts caps for many
  /// occupants. If the cache returns nothing for a given `node#ver` the
  /// existing online query path still runs.
  Map<String, Set<String>> loadEntityCaps() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final result = <String, Set<String>>{};
    for (final key in _keysWithPrefix(box, _entityCapsPrefix)) {
      final capsKey = key.substring(_entityCapsPrefix.length);
      if (capsKey.isEmpty) {
        continue;
      }
      final value = box.get(key);
      if (value is! List) {
        continue;
      }
      final features = <String>{
        for (final feature in value)
          if (feature is String && feature.isNotEmpty) feature,
      };
      if (features.isNotEmpty) {
        result[capsKey] = features;
      }
    }
    return result;
  }

  /// R5: persist a single `node#ver` -> features mapping. Existing entries
  /// for other `node#ver` keys are preserved. We never overwrite an
  /// existing entry — Entity Capabilities are content-addressed by hash so
  /// a stable key always corresponds to the same feature set.
  Future<void> storeEntityCaps(String capsKey, Set<String> features) async {
    final box = _box;
    if (box == null) {
      return;
    }
    if (capsKey.isEmpty || features.isEmpty) {
      return;
    }
    final recordKey = '$_entityCapsPrefix$capsKey';
    if (box.containsKey(recordKey)) {
      return;
    }
    await box.put(recordKey, features.toList(growable: false));
    _afterHotWrite();
  }

  /// R5: clear the entire caps cache (e.g. for "forget account" flows).
  Future<void> clearEntityCaps() async {
    await _deleteKeysWithPrefix(_entityCapsPrefix);
  }

  /// Returns whether a SHA-256 certificate fingerprint ([sha256Hex], lower
  /// case hex) was previously trusted by the user for `$host:$port`, used to
  /// avoid re-prompting on every connection to the same server.
  bool isCertificateTrusted(String host, int port, String sha256Hex) {
    final box = _box;
    if (box == null) {
      return false;
    }
    final value = box.get('$_trustedCertPrefix$host:$port');
    if (value is! List) {
      return false;
    }
    return value.any(
      (entry) => entry is String && entry.toLowerCase() == sha256Hex,
    );
  }

  /// Remembers that the certificate fingerprint [sha256Hex] presented by
  /// `$host:$port` was accepted by the user. Multiple fingerprints can be
  /// trusted per server (e.g. across a certificate rotation).
  Future<void> trustCertificate(String host, int port, String sha256Hex) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final recordKey = '$_trustedCertPrefix$host:$port';
    final existing = box.get(recordKey);
    final fingerprints = <String>{
      if (existing is List)
        for (final entry in existing)
          if (entry is String) entry,
    }..add(sha256Hex.toLowerCase());
    await box.put(recordKey, fingerprints.toList(growable: false));
  }

  /// Clears all remembered certificate trust decisions (e.g. for "forget
  /// account" flows, or a security-conscious user wanting a clean slate).
  Future<void> clearTrustedCertificates() async {
    await _deleteKeysWithPrefix(_trustedCertPrefix);
  }

  /// R2.1: load the persisted "newest MAM id we've seen" anchor across
  /// all chats. Returns null when there is no recorded anchor.
  String? loadLastMamIdSeen() {
    final box = _box;
    if (box == null) {
      return null;
    }
    final value = box.get(_lastMamIdSeenKey)?.toString();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  /// R2.1: persist the global anchor. Callers should only call this with
  /// an id that is genuinely newer than the previous anchor; the helper
  /// performs no ordering check (MAM ids are server-assigned and only
  /// totally ordered within a single MAM archive, so the value passed
  /// here must come from the caller's append path).
  Future<void> storeLastMamIdSeen(String mamId) async {
    final box = _box;
    if (box == null) {
      return;
    }
    if (mamId.isEmpty) {
      return;
    }
    await box.put(_lastMamIdSeenKey, mamId);
  }

  /// R2.1: clear the anchor (forget-account flows).
  Future<void> clearLastMamIdSeen() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.delete(_lastMamIdSeenKey);
  }

  /// Loads the per-scope (1:1 bare JID, or `'room:'+roomJid`) latest
  /// confirmed mam-id, so catch-up can resume from exactly where the
  /// previous session left off even after a disconnect or crash.
  Map<String, String> loadMamLastIds() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(_mamLastIdsKey, defaultValue: const <String, dynamic>{});
    if (data is! Map) {
      return const {};
    }
    final result = <String, String>{};
    for (final entry in data.entries) {
      final key = entry.key.toString();
      final value = entry.value?.toString() ?? '';
      if (key.isNotEmpty && value.isNotEmpty) {
        result[key] = value;
      }
    }
    return result;
  }

  /// Persists the full per-scope latest-mam-id map (see [loadMamLastIds]).
  Future<void> storeMamLastIds(Map<String, String> lastIds) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_mamLastIdsKey, Map<String, String>.from(lastIds));
  }

  /// Loads the set of scopes for which MAM catch-up was marked complete as
  /// of the last persist.
  Set<String> loadMamCatchUpCompleteScopes() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(_mamCatchUpCompleteKey, defaultValue: const <dynamic>[]);
    if (data is! List) {
      return const {};
    }
    return data.map((e) => e.toString()).where((e) => e.isNotEmpty).toSet();
  }

  /// Persists the set of scopes for which MAM catch-up is currently
  /// complete (see [loadMamCatchUpCompleteScopes]).
  Future<void> storeMamCatchUpCompleteScopes(Set<String> scopes) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_mamCatchUpCompleteKey, scopes.toList(growable: false));
  }

  /// Clears all persisted per-scope MAM cursor state (forget-account flows).
  Future<void> clearMamCursors() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.delete(_mamLastIdsKey);
    await box.delete(_mamCatchUpCompleteKey);
  }

  Future<void> storeAvatarMetadata(
    String bareJid,
    AvatarMetadata metadata,
  ) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final existing = box.get(
      _avatarMetadataKey,
      defaultValue: <String, dynamic>{},
    );
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(
        existing.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    next[bareJid] = metadata.toMap();
    await box.put(_avatarMetadataKey, next);
  }

  Future<void> removeAvatarMetadata(String bareJid) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) return;
    final existing = box.get(
      _avatarMetadataKey,
      defaultValue: <String, dynamic>{},
    );
    if (existing is! Map || !existing.containsKey(bareJid)) return;
    final next = Map<String, dynamic>.from(existing)..remove(bareJid);
    await box.put(_avatarMetadataKey, next);
  }

  Map<String, String> loadAvatarBlobs() {
    return _loadPrefixedStrings(_avatarBlobPrefix);
  }

  Future<void> storeAvatarBlob(String hash, String base64Data) async {
    final box = _box;
    if (box == null || hash.isEmpty) {
      return;
    }
    await box.put('$_avatarBlobPrefix$hash', base64Data);
    _afterHotWrite();
  }

  /// R3.1: replace the entire avatar-blobs map with [blobs]. Used by the
  /// PEP avatar GC pass that keeps only blobs referenced by a current
  /// metadata entry.
  Future<void> replaceAvatarBlobs(Map<String, String> blobs) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final keep = <String, dynamic>{
      for (final entry in blobs.entries)
        if (entry.key.isNotEmpty) '$_avatarBlobPrefix${entry.key}': entry.value,
    };
    final stale = _keysWithPrefix(
      box,
      _avatarBlobPrefix,
    ).where((key) => !keep.containsKey(key)).toList(growable: false);
    if (stale.isNotEmpty) {
      await box.deleteAll(stale);
    }
    if (keep.isNotEmpty) {
      await box.putAll(keep);
    }
  }

  Future<void> clearAvatars() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_avatarMetadataKey, <String, dynamic>{});
    await _deleteKeysWithPrefix(_avatarBlobPrefix);
  }

  Map<String, String> loadVcardAvatars() {
    return _loadPrefixedStrings(_vcardAvatarPrefix);
  }

  /// Loads every persisted SPIF policy document, keyed by policy id.
  Map<String, String> loadSecurityLabelPolicies() {
    return _loadPrefixedStrings(_securityLabelPolicyPrefix);
  }

  /// Replaces the entire persisted SPIF policy set with [policies] (id ->
  /// raw SPIF XML), dropping any previously-persisted policy no longer
  /// present on the server. Mirrors [replaceAvatarBlobs].
  Future<void> replaceSecurityLabelPolicies(
    Map<String, String> policies,
  ) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final keep = <String, dynamic>{
      for (final entry in policies.entries)
        if (entry.key.isNotEmpty)
          '$_securityLabelPolicyPrefix${entry.key}': entry.value,
    };
    final stale = _keysWithPrefix(
      box,
      _securityLabelPolicyPrefix,
    ).where((key) => !keep.containsKey(key)).toList(growable: false);
    if (stale.isNotEmpty) {
      await box.deleteAll(stale);
    }
    if (keep.isNotEmpty) {
      await box.putAll(keep);
    }
  }

  /// Loads the raw `<catalog/>` XML of the last-fetched security-label
  /// catalogue, or null if none has ever been fetched/seeded.
  String? loadSecurityLabelCatalog() {
    final box = _box;
    if (box == null) {
      return null;
    }
    return box.get(_securityLabelCatalogKey)?.toString();
  }

  /// Replaces the persisted security-label catalogue with [xml] (the raw
  /// `<catalog/>` document). Mirrors [replaceSecurityLabelPolicies].
  Future<void> replaceSecurityLabelCatalog(String xml) async {
    final box = _box;
    if (box == null) {
      return;
    }
    await box.put(_securityLabelCatalogKey, xml);
  }

  /// Reads every record whose key starts with [prefix] into a map keyed by
  /// the remainder of the key.
  Map<String, String> _loadPrefixedStrings(String prefix) {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final result = <String, String>{};
    for (final key in _keysWithPrefix(box, prefix)) {
      final value = box.get(key);
      if (value == null) {
        continue;
      }
      final id = key.substring(prefix.length);
      if (id.isEmpty) {
        continue;
      }
      result[id] = value.toString();
    }
    return result;
  }

  Map<String, String> loadVcardAvatarState() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final data = box.get(
      _vcardAvatarStateKey,
      defaultValue: const <String, dynamic>{},
    );
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
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_vcardAvatarPrefix$bareJid', base64Data);
    _afterHotWrite();
  }

  Future<void> removeVcardAvatar(String bareJid) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.delete('$_vcardAvatarPrefix$bareJid');
  }

  Future<void> removeVcardAvatarState(String bareJid) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) return;
    final existing = box.get(
      _vcardAvatarStateKey,
      defaultValue: <String, dynamic>{},
    );
    if (existing is! Map || !existing.containsKey(bareJid)) return;
    final next = Map<String, dynamic>.from(existing)..remove(bareJid);
    await box.put(_vcardAvatarStateKey, next);
  }

  Future<void> storeVcardAvatarState(String bareJid, String state) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final existing = box.get(
      _vcardAvatarStateKey,
      defaultValue: <String, dynamic>{},
    );
    final next = <String, dynamic>{};
    if (existing is Map) {
      next.addAll(
        existing.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    next[bareJid] = state;
    await box.put(_vcardAvatarStateKey, next);
  }

  Future<void> clearVcardAvatars() async {
    final box = _box;
    if (box == null) {
      return;
    }
    await _deleteKeysWithPrefix(_vcardAvatarPrefix);
    await box.put(_vcardAvatarStateKey, <String, dynamic>{});
  }

  // -------------------------------------------------------------------
  // OMEMO2 (urn:xmpp:omemo:2) storage.
  //
  // Session/ratchet state, cached peer bundles and device lists live in
  // the (encrypted-at-rest) Hive box, following the same per-record-key
  // pattern as the avatar/caps caches above. The local identity key
  // (including private key material) instead goes through [SecureStore],
  // mirroring how the PIN salt is handled.
  // -------------------------------------------------------------------

  /// Stores the serialised local OMEMO2 identity (`OmemoDevice`, see
  /// `lib/encryption/omemo2_serialization.dart`) for [bareJid] in the
  /// platform secure store.
  Future<void> storeOmemo2Identity(
    String bareJid,
    Map<String, dynamic> deviceJson,
  ) async {
    if (bareJid.isEmpty) {
      return;
    }
    await _secureStorage.write(
      key: '$_omemo2IdentitySecureKeyPrefix$bareJid',
      value: jsonEncode(deviceJson),
    );
  }

  /// Loads the serialised local OMEMO2 identity for [bareJid], or `null`
  /// if none has been generated/persisted yet.
  Future<Map<String, dynamic>?> loadOmemo2Identity(String bareJid) async {
    if (bareJid.isEmpty) {
      return null;
    }
    final raw = await _secureStorage.read(
      key: '$_omemo2IdentitySecureKeyPrefix$bareJid',
    );
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  /// Deletes the local OMEMO2 identity for [bareJid] (e.g. "forget
  /// account" flows).
  Future<void> removeOmemo2Identity(String bareJid) async {
    if (bareJid.isEmpty) {
      return;
    }
    await _secureStorage.delete(key: '$_omemo2IdentitySecureKeyPrefix$bareJid');
  }

  // -------------------------------------------------------------------
  // OX (urn:xmpp:openpgp:0, see lib/encryption/ox_backend.dart) storage.
  //
  // Mirrors the OMEMO2 split above: the local OpenPGP private key goes
  // through [SecureStore], while cached peer public keys/fingerprint
  // lists live in the Hive box.
  // -------------------------------------------------------------------

  /// Stores the armored local OX (OpenPGP) private key for [bareJid] in the
  /// platform secure store.
  Future<void> storeOxIdentity(String bareJid, String armoredPrivateKey) async {
    if (bareJid.isEmpty) {
      return;
    }
    await _secureStorage.write(
      key: '$_oxIdentitySecureKeyPrefix$bareJid',
      value: armoredPrivateKey,
    );
  }

  /// Loads the armored local OX private key for [bareJid], or `null` if
  /// none has been generated/imported yet.
  Future<String?> loadOxIdentity(String bareJid) async {
    if (bareJid.isEmpty) {
      return null;
    }
    final raw = await _secureStorage.read(
      key: '$_oxIdentitySecureKeyPrefix$bareJid',
    );
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  /// Deletes the local OX identity for [bareJid] (e.g. "forget account"
  /// flows).
  Future<void> removeOxIdentity(String bareJid) async {
    if (bareJid.isEmpty) {
      return;
    }
    await _secureStorage.delete(key: '$_oxIdentitySecureKeyPrefix$bareJid');
  }

  /// Caches a peer's armored OX public key so it does not need to be
  /// re-fetched via PEP on every encryption attempt.
  Future<void> storeOxPublicKey(
    String bareJid,
    String fingerprint,
    String armoredPublicKey,
  ) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_oxPublicKeyPrefix$bareJid:$fingerprint', armoredPublicKey);
    final known = loadOxFingerprintList(bareJid) ?? [];
    if (!known.contains(fingerprint)) {
      await box.put('$_oxFingerprintListPrefix$bareJid', [
        ...known,
        fingerprint,
      ]);
    }
    _afterHotWrite();
  }

  /// Loads a peer's cached armored OX public key for [fingerprint], or
  /// `null` if not cached.
  String? loadOxPublicKey(String bareJid, String fingerprint) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_oxPublicKeyPrefix$bareJid:$fingerprint');
    return data is String ? data : null;
  }

  /// Loads the list of known OX key fingerprints cached for [bareJid], or
  /// `null` if none are cached.
  List<String>? loadOxFingerprintList(String bareJid) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_oxFingerprintListPrefix$bareJid');
    if (data is List) {
      return data.map((e) => e.toString()).toList();
    }
    return null;
  }

  /// Persists the known OMEMO2 device list for [bareJid].
  Future<void> storeOmemo2DeviceList(
    String bareJid,
    List<int> deviceIds,
  ) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_omemo2DeviceListPrefix$bareJid', deviceIds);
    _afterHotWrite();
  }

  /// Loads the cached OMEMO2 device list for [bareJid], or `null` if none
  /// is cached.
  List<int>? loadOmemo2DeviceList(String bareJid) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_omemo2DeviceListPrefix$bareJid');
    if (data is List) {
      return data.map((e) => e as int).toList();
    }
    return null;
  }

  /// Wipes the cached OMEMO2 device list for [bareJid] (e.g. before a
  /// user-triggered "refresh devices from PEP" re-fetch; see
  /// `Omemo2Backend.refreshDevices`).
  Future<void> removeOmemo2DeviceList(String bareJid) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.delete('$_omemo2DeviceListPrefix$bareJid');
  }

  /// Caches a peer's OMEMO2 key bundle so it does not need to be re-fetched
  /// via PEP on every session establishment attempt.
  Future<void> storeOmemo2Bundle(
    String bareJid,
    int deviceId,
    Map<String, dynamic> bundleJson,
  ) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_omemo2BundlePrefix$bareJid:$deviceId', bundleJson);
    _afterHotWrite();
  }

  Map<String, dynamic>? loadOmemo2Bundle(String bareJid, int deviceId) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_omemo2BundlePrefix$bareJid:$deviceId');
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  /// Wipes every cached OMEMO2 key bundle belonging to [bareJid] (e.g.
  /// before a user-triggered "refresh devices from PEP" re-fetch; see
  /// `Omemo2Backend.refreshDevices`).
  Future<void> removeOmemo2BundlesForJid(String bareJid) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    final keys = _keysWithPrefix(box, '$_omemo2BundlePrefix$bareJid:');
    await box.deleteAll(keys);
  }

  /// Persists a single OMEMO2 Double Ratchet session (see
  /// `lib/encryption/omemo2_serialization.dart` for the on-disk shape).
  Future<void> storeOmemo2Ratchet(
    String bareJid,
    int deviceId,
    Map<String, dynamic> ratchetJson,
  ) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_omemo2RatchetPrefix$bareJid:$deviceId', ratchetJson);
    _afterHotWrite();
  }

  Map<String, dynamic>? loadOmemo2Ratchet(String bareJid, int deviceId) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_omemo2RatchetPrefix$bareJid:$deviceId');
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  /// Loads every persisted ratchet belonging to [bareJid], keyed by device
  /// id.
  Map<int, Map<String, dynamic>> loadOmemo2RatchetsForJid(String bareJid) {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final prefix = '$_omemo2RatchetPrefix$bareJid:';
    final result = <int, Map<String, dynamic>>{};
    for (final key in _keysWithPrefix(box, prefix)) {
      final deviceId = int.tryParse(key.substring(prefix.length));
      if (deviceId == null) {
        continue;
      }
      final data = box.get(key);
      if (data is Map) {
        result[deviceId] = Map<String, dynamic>.from(data);
      }
    }
    return result;
  }

  Future<void> removeOmemo2Ratchets(
    List<MapEntry<String, int>> ratchetKeys,
  ) async {
    final box = _box;
    if (box == null || ratchetKeys.isEmpty) {
      return;
    }
    await box.deleteAll([
      for (final entry in ratchetKeys)
        '$_omemo2RatchetPrefix${entry.key}:${entry.value}',
    ]);
  }

  /// Persists a Blind-Trust-Before-Verification trust decision for a single
  /// device.
  Future<void> storeOmemo2Trust(
    String bareJid,
    int deviceId,
    Map<String, dynamic> trustJson,
  ) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_omemo2TrustPrefix$bareJid:$deviceId', trustJson);
    _afterHotWrite();
  }

  /// Loads every persisted trust decision for [bareJid].
  List<Map<String, dynamic>> loadOmemo2TrustForJid(String bareJid) {
    final box = _box;
    if (box == null) {
      return const [];
    }
    final prefix = '$_omemo2TrustPrefix$bareJid:';
    return [
      for (final key in _keysWithPrefix(box, prefix))
        if (box.get(key) is Map) Map<String, dynamic>.from(box.get(key) as Map),
    ];
  }

  Future<void> removeOmemo2TrustForJid(String bareJid) async {
    await _deleteKeysWithPrefix('$_omemo2TrustPrefix$bareJid:');
  }

  // -------------------------------------------------------------------
  // Legacy OMEMO (eu.siacs.conversations.axolotl) storage.
  //
  // Mirrors the OMEMO2 storage above exactly, one-for-one, but under
  // distinct keys/prefixes (see lib/encryption/omemo_backend.dart).
  // -------------------------------------------------------------------

  /// Stores the serialised local legacy-OMEMO identity (`OmemoDevice`) for
  /// [bareJid] in the platform secure store.
  Future<void> storeOmemoIdentity(
    String bareJid,
    Map<String, dynamic> deviceJson,
  ) async {
    if (bareJid.isEmpty) {
      return;
    }
    await _secureStorage.write(
      key: '$_omemoIdentitySecureKeyPrefix$bareJid',
      value: jsonEncode(deviceJson),
    );
  }

  /// Loads the serialised local legacy-OMEMO identity for [bareJid], or
  /// `null` if none has been generated/persisted yet.
  Future<Map<String, dynamic>?> loadOmemoIdentity(String bareJid) async {
    if (bareJid.isEmpty) {
      return null;
    }
    final raw = await _secureStorage.read(
      key: '$_omemoIdentitySecureKeyPrefix$bareJid',
    );
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  /// Deletes the local legacy-OMEMO identity for [bareJid] (e.g. "forget
  /// account" flows).
  Future<void> removeOmemoIdentity(String bareJid) async {
    if (bareJid.isEmpty) {
      return;
    }
    await _secureStorage.delete(key: '$_omemoIdentitySecureKeyPrefix$bareJid');
  }

  /// Persists the known legacy-OMEMO device list for [bareJid].
  Future<void> storeOmemoDeviceList(String bareJid, List<int> deviceIds) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_omemoDeviceListPrefix$bareJid', deviceIds);
    _afterHotWrite();
  }

  /// Loads the cached legacy-OMEMO device list for [bareJid], or `null` if
  /// none is cached.
  List<int>? loadOmemoDeviceList(String bareJid) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_omemoDeviceListPrefix$bareJid');
    if (data is List) {
      return data.map((e) => e as int).toList();
    }
    return null;
  }

  /// Wipes the cached legacy-OMEMO device list for [bareJid] (e.g. before
  /// a user-triggered "refresh devices from PEP" re-fetch; see
  /// `OmemoBackend.refreshDevices`).
  Future<void> removeOmemoDeviceList(String bareJid) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.delete('$_omemoDeviceListPrefix$bareJid');
  }

  /// Caches a peer's legacy-OMEMO key bundle so it does not need to be
  /// re-fetched via PEP on every session establishment attempt.
  Future<void> storeOmemoBundle(
    String bareJid,
    int deviceId,
    Map<String, dynamic> bundleJson,
  ) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_omemoBundlePrefix$bareJid:$deviceId', bundleJson);
    _afterHotWrite();
  }

  Map<String, dynamic>? loadOmemoBundle(String bareJid, int deviceId) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_omemoBundlePrefix$bareJid:$deviceId');
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  /// Wipes every cached legacy-OMEMO key bundle belonging to [bareJid]
  /// (e.g. before a user-triggered "refresh devices from PEP" re-fetch;
  /// see `OmemoBackend.refreshDevices`).
  Future<void> removeOmemoBundlesForJid(String bareJid) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    final keys = _keysWithPrefix(box, '$_omemoBundlePrefix$bareJid:');
    await box.deleteAll(keys);
  }

  /// Persists a single legacy-OMEMO Double Ratchet session.
  Future<void> storeOmemoRatchet(
    String bareJid,
    int deviceId,
    Map<String, dynamic> ratchetJson,
  ) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_omemoRatchetPrefix$bareJid:$deviceId', ratchetJson);
    _afterHotWrite();
  }

  Map<String, dynamic>? loadOmemoRatchet(String bareJid, int deviceId) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_omemoRatchetPrefix$bareJid:$deviceId');
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  /// Loads every persisted legacy-OMEMO ratchet belonging to [bareJid],
  /// keyed by device id.
  Map<int, Map<String, dynamic>> loadOmemoRatchetsForJid(String bareJid) {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final prefix = '$_omemoRatchetPrefix$bareJid:';
    final result = <int, Map<String, dynamic>>{};
    for (final key in _keysWithPrefix(box, prefix)) {
      final deviceId = int.tryParse(key.substring(prefix.length));
      if (deviceId == null) {
        continue;
      }
      final data = box.get(key);
      if (data is Map) {
        result[deviceId] = Map<String, dynamic>.from(data);
      }
    }
    return result;
  }

  Future<void> removeOmemoRatchets(
    List<MapEntry<String, int>> ratchetKeys,
  ) async {
    final box = _box;
    if (box == null || ratchetKeys.isEmpty) {
      return;
    }
    await box.deleteAll([
      for (final entry in ratchetKeys)
        '$_omemoRatchetPrefix${entry.key}:${entry.value}',
    ]);
  }

  /// Persists the serialized libsignal-compatible legacy-OMEMO Double
  /// Ratchet session ([sessionJson], a JSON string because the nested
  /// structure would otherwise come back from Hive with loose types) for
  /// [bareJid]/[deviceId].
  Future<void> storeLegacySignalSession(
    String bareJid,
    int deviceId,
    String sessionJson,
  ) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_legacySignalSessionPrefix$bareJid:$deviceId', sessionJson);
    _afterHotWrite();
  }

  /// Loads the serialized legacy-OMEMO Double Ratchet session for
  /// [bareJid]/[deviceId], or `null` if none exists.
  String? loadLegacySignalSession(String bareJid, int deviceId) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_legacySignalSessionPrefix$bareJid:$deviceId');
    return data is String && data.isNotEmpty ? data : null;
  }

  /// Removes every libsignal-compatible legacy-OMEMO session of [bareJid].
  Future<void> removeLegacySignalSessionsForJid(String bareJid) async {
    await _deleteKeysWithPrefix('$_legacySignalSessionPrefix$bareJid:');
  }

  /// Persists a Blind-Trust-Before-Verification trust decision for a
  /// single legacy-OMEMO device.
  Future<void> storeOmemoTrust(
    String bareJid,
    int deviceId,
    Map<String, dynamic> trustJson,
  ) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await box.put('$_omemoTrustPrefix$bareJid:$deviceId', trustJson);
    _afterHotWrite();
  }

  /// Loads every persisted legacy-OMEMO trust decision for [bareJid].
  List<Map<String, dynamic>> loadOmemoTrustForJid(String bareJid) {
    final box = _box;
    if (box == null) {
      return const [];
    }
    final prefix = '$_omemoTrustPrefix$bareJid:';
    return [
      for (final key in _keysWithPrefix(box, prefix))
        if (box.get(key) is Map) Map<String, dynamic>.from(box.get(key) as Map),
    ];
  }

  Future<void> removeOmemoTrustForJid(String bareJid) async {
    await _deleteKeysWithPrefix('$_omemoTrustPrefix$bareJid:');
  }

  /// Persists the generic [TrustStore] trust-state value (the
  /// `TrustState.name`, e.g. `'tofu'`/`'verified'`) for the device/key
  /// [deviceOrKeyId] belonging to [bareJid]. Shared by every
  /// [EncryptionBackend] (see `lib/encryption/trust_store.dart`), unlike
  /// the OMEMO2-specific BTBV bookkeeping above.
  Future<void> storeTrustState(
    String bareJid,
    String deviceOrKeyId,
    String stateName,
  ) async {
    final box = _box;
    if (box == null || bareJid.isEmpty || deviceOrKeyId.isEmpty) {
      return;
    }
    await box.put('$_trustStorePrefix$bareJid:$deviceOrKeyId', stateName);
    _afterHotWrite();
  }

  /// Loads the persisted generic [TrustStore] trust-state value for
  /// [bareJid]/[deviceOrKeyId], or `null` if none has been recorded yet.
  String? loadTrustState(String bareJid, String deviceOrKeyId) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_trustStorePrefix$bareJid:$deviceOrKeyId');
    return data is String && data.isNotEmpty ? data : null;
  }

  /// Removes every persisted generic [TrustStore] trust-state value for
  /// [bareJid] (e.g. "forget contact" flows).
  Future<void> removeTrustStatesForJid(String bareJid) async {
    await _deleteKeysWithPrefix('$_trustStorePrefix$bareJid:');
  }

  /// Persists the selected end-to-end-encryption protocol id (e.g.
  /// `'omemo2'`, or `null`/absent for "none") for a 1:1 conversation with
  /// [bareJid]. See `lib/encryption/encryption_manager.dart`.
  Future<void> storeEncryptionProtocolForJid(
    String bareJid,
    String? protocolId,
  ) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    final key = '$_encryptionProtocolPrefix$bareJid';
    if (protocolId == null || protocolId.isEmpty) {
      await box.delete(key);
    } else {
      await box.put(key, protocolId);
    }
    _afterHotWrite();
  }

  /// Loads the previously selected encryption protocol id for [bareJid],
  /// or `null` if none was selected (i.e. encryption is off for that
  /// conversation).
  String? loadEncryptionProtocolForJid(String bareJid) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_encryptionProtocolPrefix$bareJid');
    return data is String && data.isNotEmpty ? data : null;
  }

  /// Every bare JID with an explicit persisted per-contact encryption
  /// protocol choice, for re-publishing to the per-contact PEP settings
  /// node on reconnect. See `lib/xmpp/encryption_settings_pep.dart`.
  Map<String, String> loadAllEncryptionProtocolChoices() {
    final box = _box;
    if (box == null) {
      return const {};
    }
    final result = <String, String>{};
    for (final key in box.keys) {
      if (key is String && key.startsWith(_encryptionProtocolPrefix)) {
        final value = box.get(key);
        if (value is String && value.isNotEmpty) {
          result[key.substring(_encryptionProtocolPrefix.length)] = value;
        }
      }
    }
    return result;
  }

  /// Persists the global default encryption policy id (`'never'`,
  /// `'ifSupported'`, or `'always'`). See `EncryptionDefaultPolicy`.
  Future<void> storeEncryptionDefaultPolicy(String? policyId) async {
    final box = _box;
    if (box == null) {
      return;
    }
    if (policyId == null || policyId.isEmpty) {
      await box.delete(_encryptionDefaultPolicyKey);
    } else {
      await box.put(_encryptionDefaultPolicyKey, policyId);
    }
    _afterHotWrite();
  }

  /// Loads the persisted global default encryption policy id, or `null` if
  /// none has been set yet.
  String? loadEncryptionDefaultPolicy() {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get(_encryptionDefaultPolicyKey);
    return data is String && data.isNotEmpty ? data : null;
  }

  /// Persists whether [protocolId] (e.g. `'omemo2'`) is enabled as a
  /// cryptosystem. Disabled cryptosystems are hidden from menus/screens and
  /// are never auto-selected by the global default policy.
  Future<void> storeEncryptionProtocolEnabled(
    String protocolId,
    bool enabled,
  ) async {
    final box = _box;
    if (box == null || protocolId.isEmpty) {
      return;
    }
    await box.put('$_encryptionProtocolEnabledPrefix$protocolId', enabled);
    _afterHotWrite();
  }

  /// Loads whether [protocolId] is enabled, or `null` if no explicit choice
  /// has been persisted yet (callers should default to enabled/`true`).
  bool? loadEncryptionProtocolEnabled(String protocolId) {
    final box = _box;
    if (box == null) {
      return null;
    }
    final data = box.get('$_encryptionProtocolEnabledPrefix$protocolId');
    return data is bool ? data : null;
  }

  /// Wipes all local OMEMO2 state for [bareJid] (ratchets, cached bundles,
  /// device list and trust decisions), e.g. for a "forget contact"/"reset
  /// session" flow. Does not touch the local identity key.
  Future<void> clearOmemo2StateForJid(String bareJid) async {
    final box = _box;
    if (box == null || bareJid.isEmpty) {
      return;
    }
    await _deleteKeysWithPrefix('$_omemo2RatchetPrefix$bareJid:');
    await _deleteKeysWithPrefix('$_omemo2BundlePrefix$bareJid:');
    await _deleteKeysWithPrefix('$_omemo2TrustPrefix$bareJid:');
    await _deleteKeysWithPrefix('$_trustStorePrefix$bareJid:');
    await box.delete('$_omemo2DeviceListPrefix$bareJid');
  }

  Future<void> _openBoxWithPin(String pin, List<int> salt) async {
    final key = await _deriveKey(pin, salt);
    final cipher = HiveAesCipher(key);
    await _salvageBoxIfOversized(cipher);
    _box = await Hive.openBox<dynamic>(
      _secureBoxName,
      encryptionCipher: cipher,
    );
    await _migrateAggregatedCaches();
    _seedMessageCaches();
    await _compactIfOversized();
  }

  /// Absolute path of the encrypted box file, or null when Hive was
  /// initialized without a known directory (e.g. web).
  String? get _boxFile {
    final dir = _hivePath;
    if (dir == null || dir.isEmpty) {
      return null;
    }
    return '$dir${Platform.pathSeparator}$_secureBoxName.hive';
  }

  int _boxFileSize() {
    final path = _boxFile;
    if (path == null) {
      return 0;
    }
    try {
      final file = File(path);
      return file.existsSync() ? file.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Recovers from a box that has grown beyond [salvageThresholdBytes].
  ///
  /// Opening a regular box reads the whole file into memory, so a bloated box
  /// makes the app die with an out-of-memory error before it can do anything
  /// about it. A *lazy* box only streams the keys, which lets us copy the
  /// handful of records that are not re-fetchable ([_essentialKeys]) into a
  /// brand new, compact box and drop everything else.
  Future<void> _salvageBoxIfOversized(HiveAesCipher cipher) async {
    final size = _boxFileSize();
    if (size <= salvageThresholdBytes) {
      return;
    }
    debugPrint(
      'StorageService: box is ${size ~/ (1024 * 1024)} MiB, salvaging '
      'essential records into a fresh box',
    );
    final salvaged = <String, dynamic>{};
    try {
      final lazyBox = await Hive.openLazyBox<dynamic>(
        _secureBoxName,
        encryptionCipher: cipher,
      );
      for (final key in _essentialKeys) {
        if (!lazyBox.containsKey(key)) {
          continue;
        }
        try {
          final value = await lazyBox.get(key);
          if (value != null) {
            salvaged[key] = value;
          }
        } catch (error) {
          debugPrint('StorageService: could not salvage "$key": $error');
        }
      }
      await lazyBox.close();
    } catch (error) {
      debugPrint('StorageService: salvage pass failed: $error');
    }
    try {
      await Hive.deleteBoxFromDisk(_secureBoxName);
    } catch (error) {
      debugPrint('StorageService: could not delete bloated box: $error');
    }
    if (salvaged.isEmpty) {
      return;
    }
    final box = await Hive.openBox<dynamic>(
      _secureBoxName,
      encryptionCipher: cipher,
    );
    await box.putAll(salvaged);
    await box.close();
    debugPrint(
      'StorageService: salvaged ${salvaged.length} records; caches will be '
      'rebuilt from the server',
    );
  }

  /// Rewrites the legacy aggregated caches (one giant map per cache) into
  /// the per-record layout and drops the old keys. Runs once per box.
  Future<void> _migrateAggregatedCaches() async {
    final box = _box;
    if (box == null) {
      return;
    }
    var migrated = false;
    migrated |= await _migrateMapKey(box, _messagesKey, _messagePrefix);
    migrated |= await _migrateMapKey(box, _roomMessagesKey, _roomMessagePrefix);
    migrated |= await _migrateMapKey(box, _avatarBlobsKey, _avatarBlobPrefix);
    migrated |= await _migrateMapKey(box, _vcardAvatarsKey, _vcardAvatarPrefix);
    migrated |= await _migrateMapKey(box, _entityCapsKey, _entityCapsPrefix);
    if (migrated) {
      // The legacy values are still in the append-only log; reclaim them now
      // rather than after another 60 writes.
      await _compact();
    }
  }

  Future<bool> _migrateMapKey(
    Box<dynamic> box,
    String legacyKey,
    String prefix,
  ) async {
    final data = box.get(legacyKey);
    if (data is! Map) {
      if (box.containsKey(legacyKey)) {
        await box.delete(legacyKey);
        return true;
      }
      return false;
    }
    final entries = <String, dynamic>{};
    for (final entry in data.entries) {
      final key = entry.key.toString();
      if (key.isEmpty || entry.value == null) {
        continue;
      }
      entries['$prefix$key'] = entry.value;
    }
    if (entries.isNotEmpty) {
      await box.putAll(entries);
    }
    await box.delete(legacyKey);
    return true;
  }

  Iterable<String> _keysWithPrefix(Box<dynamic> box, String prefix) {
    return box.keys
        .map((key) => key.toString())
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
  }

  Future<void> _deleteKeysWithPrefix(String prefix) async {
    final box = _box;
    if (box == null) {
      return;
    }
    final keys = _keysWithPrefix(box, prefix);
    if (keys.isEmpty) {
      return;
    }
    await box.deleteAll(keys);
  }

  /// Compacts the box when it has grown past [compactThresholdBytes]. Hive
  /// compacts on its own every 60 overwrites, but it also silently gives up
  /// forever if a single compaction throws, so we check the actual file size
  /// periodically as a backstop.
  Future<void> _compactIfOversized() async {
    if (_boxFileSize() <= compactThresholdBytes) {
      return;
    }
    await _compact();
  }

  Future<void> _compact() async {
    final box = _box;
    if (box == null || _compacting) {
      return;
    }
    _compacting = true;
    try {
      await box.compact();
    } catch (error) {
      debugPrint('StorageService: compaction failed: $error');
    } finally {
      _compacting = false;
    }
  }

  /// Called after every hot-path write. Checks the on-disk size once every
  /// [_writesBetweenSizeChecks] writes so a runaway cache can never grow the
  /// file without bound again.
  void _afterHotWrite() {
    _writesSinceSizeCheck += 1;
    if (_writesSinceSizeCheck < _writesBetweenSizeChecks) {
      return;
    }
    _writesSinceSizeCheck = 0;
    unawaited(_compactIfOversized());
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

class _CachedMessageRef {
  _CachedMessageRef(this.list, this.message, this.cacheKey);

  final List<ChatMessage> list;
  final ChatMessage message;
  final _MessageCacheKey cacheKey;
}

/// Identifies a single cached conversation: its JID plus whether it lives in
/// the one-to-one or the groupchat cache.
class _MessageCacheKey {
  const _MessageCacheKey(this.jid, this.isRoom);

  final String jid;
  final bool isRoom;

  @override
  bool operator ==(Object other) =>
      other is _MessageCacheKey && other.jid == jid && other.isRoom == isRoom;

  @override
  int get hashCode => Object.hash(jid, isRoom);
}

/// Secret configuration passed directly to the native QUIC layer, never logged.
class QuicSessionStorageSettings {
  const QuicSessionStorageSettings(this.path, this.key);
  final String path;
  final Uint8List key;
}
