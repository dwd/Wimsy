import 'dart:convert';

import 'package:omemo_dart/omemo_dart.dart';
import 'package:xml/xml.dart' as xml;
import 'package:xmpp_stone/xmpp_stone.dart';

import '../storage/storage_service.dart';
import 'encryption_backend.dart';
import 'omemo2_serialization.dart';

/// The `urn:xmpp:omemo:2` namespace, mirrored from
/// `lib/xmpp/omemo_pep.dart` (kept as a local constant here to avoid this
/// file depending on the XMPP-transport-specific `OmemoPep` class).
const String omemo2Namespace = 'urn:xmpp:omemo:2';

/// The subset of [OmemoPep] (see `lib/xmpp/omemo_pep.dart`) that
/// [Omemo2Backend] depends on, extracted as an interface so tests can
/// supply an in-memory fake instead of a real `Connection`.
abstract class Omemo2PepTransport {
  Future<void> publishDeviceList(List<int> deviceIds);
  Future<List<int>?> fetchDeviceList(String bareJid);
  void subscribeToDeviceList(String bareJid);
  Future<void> publishBundle(OmemoBundle bundle);
  Future<OmemoBundle?> fetchBundle(String bareJid, int deviceId);
}

/// `urn:xmpp:omemo:2` (XEP-0384 "OMEMO2") [EncryptionBackend], wrapping
/// `omemo_dart`'s [OmemoManager] (X3DH + Double Ratchet session
/// management) and persisting its state via [StorageService] (Hive for
/// session/bundle/device-list data) and the platform secure store (for the
/// local identity key), through the OMEMO2 PEP nodes published/fetched by
/// [Omemo2PepTransport].
class Omemo2Backend implements EncryptionBackend {
  Omemo2Backend._(
    this.selfBareJid,
    this.storage,
    this.pep,
    this._omemoManager,
    this._trustManager,
  );

  @override
  String get protocolId => 'omemo2';

  final String selfBareJid;
  final StorageService storage;
  final Omemo2PepTransport pep;

  final OmemoManager _omemoManager;
  final BlindTrustBeforeVerificationTrustManager _trustManager;

  /// Creates (or restores, if a device was already persisted) an
  /// [Omemo2Backend] for [selfBareJid].
  static Future<Omemo2Backend> create({
    required String selfBareJid,
    required StorageService storage,
    required Omemo2PepTransport pep,
  }) async {
    final device = await _loadOrGenerateDevice(selfBareJid, storage);

    late final BlindTrustBeforeVerificationTrustManager trustManager;
    trustManager = BlindTrustBeforeVerificationTrustManager(
      loadData: (jid) async {
        return [
          for (final trustJson in storage.loadOmemo2TrustForJid(jid))
            BTBVTrustData(
              jid,
              trustJson['device'] as int,
              BTBVTrustState.fromInt(trustJson['state'] as int),
              trustJson['enabled'] as bool,
              false,
            ),
        ];
      },
      commit: (data) async {
        await storage.storeOmemo2Trust(data.jid, data.device, {
          'device': data.device,
          'state': data.state.value,
          'enabled': data.enabled,
        });
      },
      removeTrust: (jid) async {
        await storage.removeOmemo2TrustForJid(jid);
      },
    );

    late final OmemoManager omemoManager;
    omemoManager = OmemoManager(
      device,
      trustManager,
      // Heartbeat messages are only required for liveness pings on
      // freshly-created ratchets; Step 1 doesn't send proactive heartbeats.
      (result, recipientJid) async {},
      (jid) async {
        return storage.loadOmemo2DeviceList(jid) ?? await pep.fetchDeviceList(jid);
      },
      (jid, id) async {
        final cached = storage.loadOmemo2Bundle(jid, id);
        if (cached != null) {
          return _bundleFromJson(jid, id, cached);
        }
        final fetched = await pep.fetchBundle(jid, id);
        if (fetched != null) {
          await storage.storeOmemo2Bundle(jid, id, await _bundleToJson(fetched));
        }
        return fetched;
      },
      (jid) async => pep.subscribeToDeviceList(jid),
      (ownDevice) async => pep.publishBundle(await ownDevice.toBundle()),
      commitDevice: (updatedDevice) async {
        await storage.storeOmemo2Identity(
          selfBareJid,
          await omemoDeviceToJson(updatedDevice),
        );
      },
      commitDeviceList: (jid, devices) async {
        await storage.storeOmemo2DeviceList(jid, devices);
      },
      commitRatchets: (ratchets) async {
        for (final entry in ratchets) {
          await storage.storeOmemo2Ratchet(
            entry.jid,
            entry.id,
            await omemoRatchetToJson(entry.ratchet),
          );
        }
      },
      removeRatchets: (keys) async {
        await storage.removeOmemo2Ratchets([
          for (final key in keys) MapEntry(key.jid, key.deviceId),
        ]);
      },
      loadRatchets: (jid) async {
        final ratchetsJson = storage.loadOmemo2RatchetsForJid(jid);
        if (ratchetsJson.isEmpty) {
          return null;
        }
        final ratchets = <RatchetMapKey, OmemoDoubleRatchet>{};
        for (final entry in ratchetsJson.entries) {
          ratchets[RatchetMapKey(jid, entry.key)] = await omemoRatchetFromJson(
            entry.value,
          );
        }
        final devices =
            storage.loadOmemo2DeviceList(jid) ?? ratchetsJson.keys.toList();
        return OmemoDataPackage(devices, ratchets);
      },
    );

    return Omemo2Backend._(
      selfBareJid,
      storage,
      pep,
      omemoManager,
      trustManager,
    );
  }

  static Future<OmemoDevice> _loadOrGenerateDevice(
    String selfBareJid,
    StorageService storage,
  ) async {
    final storedJson = await storage.loadOmemo2Identity(selfBareJid);
    if (storedJson != null) {
      return omemoDeviceFromJson(storedJson);
    }
    final device = await OmemoDevice.generateNewDevice(selfBareJid);
    await storage.storeOmemo2Identity(
      selfBareJid,
      await omemoDeviceToJson(device),
    );
    return device;
  }

  static Future<Map<String, dynamic>> _bundleToJson(
    OmemoBundle bundle,
  ) async {
    return {
      'jid': bundle.jid,
      'id': bundle.id,
      'spk': bundle.spkEncoded,
      'spkId': bundle.spkId,
      'spks': bundle.spkSignatureEncoded,
      'ik': bundle.ikEncoded,
      'opks': bundle.opksEncoded,
    };
  }

  static OmemoBundle _bundleFromJson(
    String jid,
    int deviceId,
    Map<String, dynamic> json,
  ) {
    final opksRaw = (json['opks'] as Map).cast<dynamic, dynamic>();
    return OmemoBundle(
      jid,
      deviceId,
      json['spk'] as String,
      json['spkId'] as int,
      json['spks'] as String,
      json['ik'] as String,
      {
        for (final entry in opksRaw.entries)
          int.parse(entry.key.toString()): entry.value as String,
      },
    );
  }

  /// Publishes our own device bundle and device list via PEP so contacts
  /// can discover us and build OMEMO2 sessions with us.
  @override
  Future<void> publishIdentity() async {
    final device = await _omemoManager.getDevice();
    await pep.publishBundle(await device.toBundle());
    final knownDevices = storage.loadOmemo2DeviceList(selfBareJid) ?? [];
    final deviceIds = {...knownDevices, device.id}.toList();
    await storage.storeOmemo2DeviceList(selfBareJid, deviceIds);
    await pep.publishDeviceList(deviceIds);
  }

  @override
  Future<EncryptedPayload> encryptForSend(
    String toBareJid,
    String plaintext,
  ) async {
    // XEP-0420 (Stanza Content Encryption) wraps the actual payload in an
    // <envelope/>; Step 1 encrypts a minimal envelope carrying just the
    // plaintext <body/>, matching the shape omemo_dart's own example uses.
    final envelope = XmppElement()..name = 'envelope';
    envelope.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:sce:1'));
    final content = XmppElement()..name = 'content';
    final body = XmppElement()..name = 'body';
    body.textValue = plaintext;
    content.addChild(body);
    envelope.addChild(content);

    final result = await _omemoManager.onOutgoingStanza(
      OmemoOutgoingStanza([toBareJid], envelope.buildXmlString()),
    );

    final encrypted = XmppElement()..name = 'encrypted';
    encrypted.addAttribute(XmppAttribute('xmlns', omemo2Namespace));
    final device = await _omemoManager.getDevice();
    final header = XmppElement()..name = 'header';
    header.addAttribute(XmppAttribute('sid', device.id.toString()));
    final keysForJid = result.encryptedKeys[toBareJid] ?? const [];
    final keysElement = XmppElement()..name = 'keys';
    keysElement.addAttribute(XmppAttribute('jid', toBareJid));
    for (final key in keysForJid) {
      final keyElement = XmppElement()..name = 'key';
      keyElement.addAttribute(XmppAttribute('rid', key.rid.toString()));
      if (key.kex) {
        keyElement.addAttribute(XmppAttribute('kex', 'true'));
      }
      keyElement.textValue = key.value;
      keysElement.addChild(keyElement);
    }
    header.addChild(keysElement);
    encrypted.addChild(header);
    if (result.ciphertext != null) {
      final payload = XmppElement()..name = 'payload';
      payload.textValue = base64Encode(result.ciphertext!);
      encrypted.addChild(payload);
    }

    return EncryptedPayload(
      element: encrypted,
      fallbackBody:
          'This message is encrypted with OMEMO2 '
          '(https://xmpp.org/extensions/xep-0384.html) but your client '
          'does not support it.',
    );
  }

  @override
  Future<DecryptResult> decryptIncoming(XmppElement stanza) async {
    final encrypted = stanza.name == 'encrypted'
        ? stanza
        : stanza.getChild('encrypted');
    if (encrypted == null ||
        encrypted.getAttribute('xmlns')?.value != omemo2Namespace) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: TrustState.untrusted,
        error: 'Stanza does not contain an OMEMO2 <encrypted/> element',
      );
    }
    final fromJid = stanza.getAttribute('from')?.value;
    final bareSenderJid = fromJid == null
        ? null
        : Jid.fromFullJid(fromJid).userAtDomain;
    final header = encrypted.getChild('header');
    final sid = int.tryParse(header?.getAttribute('sid')?.value ?? '');
    if (bareSenderJid == null || sid == null) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: TrustState.untrusted,
        error: 'Missing sender JID or device id (sid) on <encrypted/>',
      );
    }
    final keysElement = header?.getChild('keys');
    final keys = <EncryptedKey>[
      for (final keyElement in keysElement?.children ?? const [])
        if (keyElement.name == 'key')
          EncryptedKey(
            int.tryParse(keyElement.getAttribute('rid')?.value ?? '') ?? -1,
            keyElement.textValue?.trim() ?? '',
            keyElement.getAttribute('kex')?.value == 'true',
          ),
    ]..removeWhere((key) => key.rid == -1 || key.value.isEmpty);
    final payload = encrypted.getChild('payload')?.textValue?.trim();

    final result = await _omemoManager.onIncomingStanza(
      OmemoIncomingStanza(
        bareSenderJid,
        sid,
        keys,
        payload,
        false,
      ),
    );

    if (result.error != null || result.payload == null) {
      return DecryptResult(
        plaintext: null,
        protocolId: protocolId,
        senderTrust: await trustStateFor(bareSenderJid, deviceOrKeyId: '$sid'),
        error: result.error?.toString() ?? 'Empty OMEMO2 message',
      );
    }

    // The decrypted payload is the serialised XEP-0420 <envelope/>; Step 1
    // only needs the <body/> text carried within it.
    final plaintext = _extractEnvelopeBody(result.payload!);

    return DecryptResult(
      plaintext: plaintext,
      protocolId: protocolId,
      senderTrust: await trustStateFor(bareSenderJid, deviceOrKeyId: '$sid'),
    );
  }

  /// Extracts the plaintext `<body/>` text from a serialised XEP-0420
  /// `<envelope/>` (see [encryptForSend]), or `null` if the payload isn't
  /// in the expected shape.
  String? _extractEnvelopeBody(String envelopeXml) {
    try {
      final document = xml.XmlDocument.parse(envelopeXml);
      final body = document.rootElement
          .findElements('content')
          .firstOrNull
          ?.findElements('body')
          .firstOrNull;
      return body?.innerText.trim();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<TrustState> trustStateFor(
    String bareJid, {
    String? deviceOrKeyId,
  }) async {
    final deviceId = deviceOrKeyId == null ? null : int.tryParse(deviceOrKeyId);
    final devicesTrust = await _trustManager.getDevicesTrust(bareJid);
    if (deviceId == null) {
      if (devicesTrust.isEmpty) {
        return TrustState.untrusted;
      }
      if (devicesTrust.values.any(
        (data) => data.state == BTBVTrustState.verified,
      )) {
        return TrustState.verified;
      }
      return TrustState.tofu;
    }
    final data = devicesTrust[deviceId];
    if (data == null) {
      return TrustState.untrusted;
    }
    switch (data.state) {
      case BTBVTrustState.verified:
        return TrustState.verified;
      case BTBVTrustState.blindTrust:
        return TrustState.tofu;
      case BTBVTrustState.notTrusted:
        return TrustState.untrusted;
    }
  }

  @override
  Future<void> setTrust(
    String bareJid,
    String deviceOrKeyId,
    TrustState state,
  ) async {
    final deviceId = int.parse(deviceOrKeyId);
    final btbvState = switch (state) {
      TrustState.verified => BTBVTrustState.verified,
      TrustState.tofu => BTBVTrustState.blindTrust,
      TrustState.untrusted => BTBVTrustState.notTrusted,
      TrustState.revoked => BTBVTrustState.notTrusted,
    };
    await _trustManager.setDeviceTrust(bareJid, deviceId, btbvState);
    if (state == TrustState.revoked) {
      await _trustManager.setEnabled(bareJid, deviceId, false);
    }
  }
}
