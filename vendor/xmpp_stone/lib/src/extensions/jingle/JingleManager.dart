import 'dart:async';

import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/stanzas/AbstractStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';
import 'package:xmpp_stone/src/extensions/iq_router/IqRouter.dart';

enum JingleAction {
  sessionInitiate,
  sessionAccept,
  sessionTerminate,
  unknown,
}

class JingleFileTransferOffer {
  const JingleFileTransferOffer({
    required this.fileName,
    required this.fileSize,
    this.mediaType,
  });

  final String fileName;
  final int fileSize;
  final String? mediaType;
}

class JingleIbbTransport {
  const JingleIbbTransport({
    required this.sid,
    required this.blockSize,
    this.stanza,
  });

  final String sid;
  final int blockSize;
  final String? stanza;
}

class JingleIceCandidate {
  const JingleIceCandidate({
    required this.foundation,
    required this.component,
    required this.protocol,
    required this.priority,
    required this.ip,
    required this.port,
    required this.type,
    this.generation,
  });

  final String foundation;
  final int component;
  final String protocol;
  final int priority;
  final String ip;
  final int port;
  final String type;
  final int? generation;
}

class JingleDtlsFingerprint {
  const JingleDtlsFingerprint({
    required this.hash,
    required this.fingerprint,
    this.setup,
  });

  final String hash;
  final String fingerprint;
  final String? setup;
}

class JingleIceTransport {
  const JingleIceTransport({
    required this.ufrag,
    required this.password,
    required this.candidates,
    this.fingerprint,
  });

  final String ufrag;
  final String password;
  final List<JingleIceCandidate> candidates;
  final JingleDtlsFingerprint? fingerprint;
}

class JingleRtpPayloadType {
  const JingleRtpPayloadType({
    required this.id,
    this.name,
    this.clockRate,
    this.channels,
  });

  final int id;
  final String? name;
  final int? clockRate;
  final int? channels;
}

class JingleRtpFeedback {
  const JingleRtpFeedback({
    required this.type,
    this.subtype,
  });

  final String type;
  final String? subtype;
}

class JingleRtpHeaderExtension {
  const JingleRtpHeaderExtension({
    required this.id,
    required this.uri,
    this.senders,
  });

  final int id;
  final String uri;
  final String? senders;
}

class JingleRtpDescription {
  const JingleRtpDescription({
    required this.media,
    required this.payloadTypes,
    this.rtcpFeedback = const [],
    this.headerExtensions = const [],
  });

  final String media;
  final List<JingleRtpPayloadType> payloadTypes;
  final List<JingleRtpFeedback> rtcpFeedback;
  final List<JingleRtpHeaderExtension> headerExtensions;
}

class JingleContent {
  const JingleContent({
    required this.name,
    required this.creator,
    this.fileOffer,
    this.ibbTransport,
    this.rtpDescription,
    this.iceTransport,
  });

  final String name;
  final String creator;
  final JingleFileTransferOffer? fileOffer;
  final JingleIbbTransport? ibbTransport;
  final JingleRtpDescription? rtpDescription;
  final JingleIceTransport? iceTransport;
}

class JingleSessionEvent {
  const JingleSessionEvent({
    required this.action,
    required this.sid,
    required this.from,
    required this.to,
    required this.stanza,
    this.content,
    this.reason,
  });

  final JingleAction action;
  final String sid;
  final Jid from;
  final Jid to;
  final IqStanza stanza;
  final JingleContent? content;
  final String? reason;
}

class JingleManager {
  static const String jingleNamespace = 'urn:xmpp:jingle:1';
  static const String fileTransferNamespace = 'urn:xmpp:jingle:apps:file-transfer:5';
  static const String fileMetadataNamespace = 'urn:xmpp:file:metadata:0';
  static const String ibbTransportNamespace = 'urn:xmpp:jingle:transports:ibb:1';
  static const String rtpNamespace = 'urn:xmpp:jingle:apps:rtp:1';
  static const String iceUdpNamespace = 'urn:xmpp:jingle:transports:ice-udp:1';
  static const String dtlsNamespace = 'urn:xmpp:jingle:apps:dtls:0';
  static const String rtcpFbNamespace = 'urn:xmpp:jingle:apps:rtp:rtcp-fb:0';
  static const String rtpHdrextNamespace =
      'urn:xmpp:jingle:apps:rtp:rtp-hdrext:0';

  static final Map<Connection, JingleManager> _instances = {};

  static JingleManager getInstance(Connection connection) {
    var instance = _instances[connection];
    if (instance == null) {
      instance = JingleManager(connection);
      _instances[connection] = instance;
    }
    return instance;
  }

  static void removeInstance(Connection connection) {
    final instance = _instances.remove(connection);
    if (instance == null) {
      return;
    }
    IqRouter.getInstance(connection).unregisterNamespaceHandler(jingleNamespace);
  }

  final Connection _connection;
  final StreamController<JingleSessionEvent> _sessionController = StreamController.broadcast();

  Stream<JingleSessionEvent> get sessionStream => _sessionController.stream;

  JingleManager(this._connection) {
    IqRouter.getInstance(_connection).registerNamespaceHandler(
      jingleNamespace,
      _handleJingleIq,
    );
  }

  Future<IqStanza?> _handleJingleIq(IqStanza request) async {
    final event = _parseEvent(request);
    if (event == null) {
      return null;
    }
    _sessionController.add(event);
    return IqStanza(request.id, IqStanzaType.RESULT);
  }

  JingleSessionEvent? _parseEvent(IqStanza request) {
    final jingle = request.getChild('jingle');
    if (jingle == null ||
        jingle.getAttribute('xmlns')?.value != jingleNamespace) {
      return null;
    }
    final actionValue = jingle.getAttribute('action')?.value ?? '';
    final sid = jingle.getAttribute('sid')?.value ?? '';
    if (sid.isEmpty) {
      return null;
    }
    final action = _actionFromString(actionValue);
    final from = request.fromJid;
    final to = request.toJid ?? _connection.fullJid;
    if (from == null || to == null) {
      return null;
    }
    final content = _parseContent(jingle);
    final reason = _parseReason(jingle);
    return JingleSessionEvent(
      action: action,
      sid: sid,
      from: from,
      to: to,
      stanza: request,
      content: content,
      reason: reason,
    );
  }

  JingleContent? _parseContent(XmppElement jingle) {
    for (final child in jingle.children) {
      if (child.name != 'content') {
        continue;
      }
      final creator = child.getAttribute('creator')?.value ?? '';
      final name = child.getAttribute('name')?.value ?? '';
      final description = child.getChild('description');
      final offer = _parseFileOffer(description);
      final rtpDescription = _parseRtpDescription(description);
      final iceTransport = _parseIceTransport(child.getChild('transport'));
      final transport = _parseIbbTransport(child.getChild('transport'));
      if (name.isEmpty &&
          offer == null &&
          transport == null &&
          rtpDescription == null &&
          iceTransport == null) {
        continue;
      }
      return JingleContent(
        name: name,
        creator: creator.isEmpty ? 'initiator' : creator,
        fileOffer: offer,
        ibbTransport: transport,
        rtpDescription: rtpDescription,
        iceTransport: iceTransport,
      );
    }
    return null;
  }

  JingleFileTransferOffer? _parseFileOffer(XmppElement? description) {
    if (description == null ||
        description.getAttribute('xmlns')?.value != fileTransferNamespace) {
      return null;
    }
    XmppElement? fileElement;
    final offer = description.getChild('offer');
    if (offer != null) {
      fileElement = offer.getChild('file');
    } else {
      fileElement = description.getChild('file');
    }
    if (fileElement == null) {
      return null;
    }
    if (fileElement.getAttribute('xmlns')?.value == null) {
      fileElement.addAttribute(XmppAttribute('xmlns', fileMetadataNamespace));
    }
    final name = fileElement.getChild('name')?.textValue?.trim() ?? '';
    final sizeText = fileElement.getChild('size')?.textValue?.trim() ?? '';
    final size = int.tryParse(sizeText) ?? 0;
    if (name.isEmpty || size <= 0) {
      return null;
    }
    final mediaType = fileElement.getChild('media-type')?.textValue?.trim();
    return JingleFileTransferOffer(
      fileName: name,
      fileSize: size,
      mediaType: (mediaType == null || mediaType.isEmpty) ? null : mediaType,
    );
  }

  JingleIbbTransport? _parseIbbTransport(XmppElement? transport) {
    if (transport == null ||
        transport.getAttribute('xmlns')?.value != ibbTransportNamespace) {
      return null;
    }
    final sid = transport.getAttribute('sid')?.value ?? '';
    if (sid.isEmpty) {
      return null;
    }
    final blockSizeText = transport.getAttribute('block-size')?.value ?? '';
    final blockSize = int.tryParse(blockSizeText) ?? 4096;
    final stanza = transport.getAttribute('stanza')?.value;
    return JingleIbbTransport(
      sid: sid,
      blockSize: blockSize,
      stanza: stanza,
    );
  }

  JingleIceTransport? _parseIceTransport(XmppElement? transport) {
    if (transport == null ||
        transport.getAttribute('xmlns')?.value != iceUdpNamespace) {
      return null;
    }
    final ufrag = transport.getAttribute('ufrag')?.value ?? '';
    final password = transport.getAttribute('pwd')?.value ?? '';
    final candidates = <JingleIceCandidate>[];
    for (final child in transport.children) {
      if (child.name != 'candidate') {
        continue;
      }
      final foundation = child.getAttribute('foundation')?.value ?? '';
      final componentValue = child.getAttribute('component')?.value ?? '';
      final protocol = child.getAttribute('protocol')?.value ?? '';
      final priorityValue = child.getAttribute('priority')?.value ?? '';
      final ip = child.getAttribute('ip')?.value ?? '';
      final portValue = child.getAttribute('port')?.value ?? '';
      final type = child.getAttribute('type')?.value ?? '';
      final component = int.tryParse(componentValue);
      final priority = int.tryParse(priorityValue);
      final port = int.tryParse(portValue);
      if (foundation.isEmpty ||
          component == null ||
          protocol.isEmpty ||
          priority == null ||
          ip.isEmpty ||
          port == null ||
          type.isEmpty) {
        continue;
      }
      final generationValue = child.getAttribute('generation')?.value ?? '';
      final generation = int.tryParse(generationValue);
      candidates.add(JingleIceCandidate(
        foundation: foundation,
        component: component,
        protocol: protocol,
        priority: priority,
        ip: ip,
        port: port,
        type: type,
        generation: generation,
      ));
    }
    final fingerprint = _parseDtlsFingerprint(transport);
    if (ufrag.isEmpty && password.isEmpty && candidates.isEmpty) {
      return null;
    }
    return JingleIceTransport(
      ufrag: ufrag,
      password: password,
      candidates: candidates,
      fingerprint: fingerprint,
    );
  }

  JingleDtlsFingerprint? _parseDtlsFingerprint(XmppElement transport) {
    for (final child in transport.children) {
      if (child.name != 'fingerprint') {
        continue;
      }
      if (child.getAttribute('xmlns')?.value != dtlsNamespace) {
        continue;
      }
      final hash = child.getAttribute('hash')?.value ?? '';
      final fingerprint = child.textValue?.trim() ?? '';
      if (hash.isEmpty || fingerprint.isEmpty) {
        continue;
      }
      final setup = child.getAttribute('setup')?.value;
      return JingleDtlsFingerprint(
        hash: hash,
        fingerprint: fingerprint,
        setup: (setup == null || setup.isEmpty) ? null : setup,
      );
    }
    return null;
  }

  JingleRtpDescription? _parseRtpDescription(XmppElement? description) {
    if (description == null ||
        description.getAttribute('xmlns')?.value != rtpNamespace) {
      return null;
    }
    final media = description.getAttribute('media')?.value ?? '';
    if (media.isEmpty) {
      return null;
    }
    final payloadTypes = <JingleRtpPayloadType>[];
    final feedback = <JingleRtpFeedback>[];
    final headerExtensions = <JingleRtpHeaderExtension>[];
    for (final child in description.children) {
      if (child.name == 'payload-type') {
        final idValue = child.getAttribute('id')?.value ?? '';
        final id = int.tryParse(idValue);
        if (id == null) {
          continue;
        }
        final name = child.getAttribute('name')?.value;
        final clockRateValue = child.getAttribute('clockrate')?.value;
        final clockRate =
            clockRateValue == null ? null : int.tryParse(clockRateValue);
        final channelsValue = child.getAttribute('channels')?.value;
        final channels =
            channelsValue == null ? null : int.tryParse(channelsValue);
        payloadTypes.add(JingleRtpPayloadType(
          id: id,
          name: (name == null || name.isEmpty) ? null : name,
          clockRate: clockRate,
          channels: channels,
        ));
        continue;
      }
      if (child.name == 'rtcp-fb' &&
          child.getAttribute('xmlns')?.value == rtcpFbNamespace) {
        final type = child.getAttribute('type')?.value ?? '';
        if (type.isEmpty) {
          continue;
        }
        final subtype = child.getAttribute('subtype')?.value;
        feedback.add(JingleRtpFeedback(
          type: type,
          subtype: (subtype == null || subtype.isEmpty) ? null : subtype,
        ));
        continue;
      }
      if (child.name == 'rtp-hdrext' &&
          child.getAttribute('xmlns')?.value == rtpHdrextNamespace) {
        final idValue = child.getAttribute('id')?.value ?? '';
        final id = int.tryParse(idValue);
        final uri = child.getAttribute('uri')?.value ?? '';
        if (id == null || uri.isEmpty) {
          continue;
        }
        final senders = child.getAttribute('senders')?.value;
        headerExtensions.add(JingleRtpHeaderExtension(
          id: id,
          uri: uri,
          senders: (senders == null || senders.isEmpty) ? null : senders,
        ));
      }
    }
    return JingleRtpDescription(
      media: media,
      payloadTypes: payloadTypes,
      rtcpFeedback: feedback,
      headerExtensions: headerExtensions,
    );
  }

  String? _parseReason(XmppElement jingle) {
    final reason = jingle.getChild('reason');
    if (reason == null) {
      return null;
    }
    for (final child in reason.children) {
      final name = child.name;
      if (name != null && name.isNotEmpty && name != 'text') {
        return name;
      }
    }
    return null;
  }

  JingleAction _actionFromString(String action) {
    switch (action) {
      case 'session-initiate':
        return JingleAction.sessionInitiate;
      case 'session-accept':
        return JingleAction.sessionAccept;
      case 'session-terminate':
        return JingleAction.sessionTerminate;
      default:
        return JingleAction.unknown;
    }
  }

  IqStanza buildSessionInitiate({
    required Jid to,
    required String sid,
    required JingleContent content,
    required String ibbSid,
    required int blockSize,
  }) {
    final stanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.SET);
    stanza.toJid = to;
    stanza.fromJid = _connection.fullJid;
    stanza.addChild(_buildJinglePayload(
      action: 'session-initiate',
      sid: sid,
      content: content,
      ibbSid: ibbSid,
      blockSize: blockSize,
    ));
    return stanza;
  }

  IqStanza buildSessionAccept({
    required Jid to,
    required String sid,
    required JingleContent content,
    required String ibbSid,
    required int blockSize,
  }) {
    final stanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.SET);
    stanza.toJid = to;
    stanza.fromJid = _connection.fullJid;
    stanza.addChild(_buildJinglePayload(
      action: 'session-accept',
      sid: sid,
      content: content,
      ibbSid: ibbSid,
      blockSize: blockSize,
    ));
    return stanza;
  }

  IqStanza buildSessionTerminate({
    required Jid to,
    required String sid,
    required String reason,
  }) {
    final stanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.SET);
    stanza.toJid = to;
    stanza.fromJid = _connection.fullJid;
    final jingle = XmppElement()..name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', jingleNamespace));
    jingle.addAttribute(XmppAttribute('action', 'session-terminate'));
    jingle.addAttribute(XmppAttribute('sid', sid));
    final reasonElement = XmppElement()..name = 'reason';
    final reasonChild = XmppElement()..name = reason;
    reasonElement.addChild(reasonChild);
    jingle.addChild(reasonElement);
    stanza.addChild(jingle);
    return stanza;
  }

  IqStanza buildRtpSessionInitiate({
    required Jid to,
    required String sid,
    required String contentName,
    required String creator,
    required JingleRtpDescription description,
    JingleIceTransport? transport,
  }) {
    final stanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.SET);
    stanza.toJid = to;
    stanza.fromJid = _connection.fullJid;
    stanza.addChild(_buildRtpJinglePayload(
      action: 'session-initiate',
      sid: sid,
      contentName: contentName,
      creator: creator,
      description: description,
      transport: transport,
    ));
    return stanza;
  }

  IqStanza buildRtpSessionAccept({
    required Jid to,
    required String sid,
    required String contentName,
    required String creator,
    required JingleRtpDescription description,
    JingleIceTransport? transport,
  }) {
    final stanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.SET);
    stanza.toJid = to;
    stanza.fromJid = _connection.fullJid;
    stanza.addChild(_buildRtpJinglePayload(
      action: 'session-accept',
      sid: sid,
      contentName: contentName,
      creator: creator,
      description: description,
      transport: transport,
    ));
    return stanza;
  }

  XmppElement _buildJinglePayload({
    required String action,
    required String sid,
    required JingleContent content,
    required String ibbSid,
    required int blockSize,
  }) {
    final jingle = XmppElement()..name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', jingleNamespace));
    jingle.addAttribute(XmppAttribute('action', action));
    jingle.addAttribute(XmppAttribute('sid', sid));
    final contentElement = XmppElement()..name = 'content';
    contentElement.addAttribute(XmppAttribute('creator', content.creator));
    contentElement.addAttribute(XmppAttribute('name', content.name));

    if (content.fileOffer != null) {
      final description = XmppElement()..name = 'description';
      description.addAttribute(XmppAttribute('xmlns', fileTransferNamespace));
      final offer = XmppElement()..name = 'offer';
      final file = XmppElement()..name = 'file';
      file.addAttribute(XmppAttribute('xmlns', fileMetadataNamespace));
      final name = XmppElement()..name = 'name';
      name.textValue = content.fileOffer!.fileName;
      final size = XmppElement()..name = 'size';
      size.textValue = content.fileOffer!.fileSize.toString();
      file.addChild(name);
      file.addChild(size);
      final mediaType = content.fileOffer!.mediaType;
      if (mediaType != null && mediaType.isNotEmpty) {
        final media = XmppElement()..name = 'media-type';
        media.textValue = mediaType;
        file.addChild(media);
      }
      offer.addChild(file);
      description.addChild(offer);
      contentElement.addChild(description);
    }

    final transport = XmppElement()..name = 'transport';
    transport.addAttribute(XmppAttribute('xmlns', ibbTransportNamespace));
    transport.addAttribute(XmppAttribute('sid', ibbSid));
    transport.addAttribute(XmppAttribute('block-size', blockSize.toString()));
    transport.addAttribute(XmppAttribute('stanza', 'iq'));
    contentElement.addChild(transport);

    jingle.addChild(contentElement);
    return jingle;
  }

  XmppElement _buildRtpJinglePayload({
    required String action,
    required String sid,
    required String contentName,
    required String creator,
    required JingleRtpDescription description,
    JingleIceTransport? transport,
  }) {
    final jingle = XmppElement()..name = 'jingle';
    jingle.addAttribute(XmppAttribute('xmlns', jingleNamespace));
    jingle.addAttribute(XmppAttribute('action', action));
    jingle.addAttribute(XmppAttribute('sid', sid));

    final contentElement = XmppElement()..name = 'content';
    contentElement.addAttribute(XmppAttribute('creator', creator));
    contentElement.addAttribute(XmppAttribute('name', contentName));
    contentElement.addChild(_buildRtpDescription(description));
    if (transport != null) {
      contentElement.addChild(_buildIceTransport(transport));
    }
    jingle.addChild(contentElement);
    return jingle;
  }

  XmppElement _buildRtpDescription(JingleRtpDescription description) {
    final element = XmppElement()..name = 'description';
    element.addAttribute(XmppAttribute('xmlns', rtpNamespace));
    element.addAttribute(XmppAttribute('media', description.media));
    for (final payload in description.payloadTypes) {
      final payloadElement = XmppElement()..name = 'payload-type';
      payloadElement.addAttribute(XmppAttribute('id', payload.id.toString()));
      final name = payload.name;
      if (name != null && name.isNotEmpty) {
        payloadElement.addAttribute(XmppAttribute('name', name));
      }
      final clockRate = payload.clockRate;
      if (clockRate != null) {
        payloadElement.addAttribute(XmppAttribute('clockrate', clockRate.toString()));
      }
      final channels = payload.channels;
      if (channels != null) {
        payloadElement.addAttribute(XmppAttribute('channels', channels.toString()));
      }
      element.addChild(payloadElement);
    }
    for (final feedback in description.rtcpFeedback) {
      final fbElement = XmppElement()..name = 'rtcp-fb';
      fbElement.addAttribute(XmppAttribute('xmlns', rtcpFbNamespace));
      fbElement.addAttribute(XmppAttribute('type', feedback.type));
      final subtype = feedback.subtype;
      if (subtype != null && subtype.isNotEmpty) {
        fbElement.addAttribute(XmppAttribute('subtype', subtype));
      }
      element.addChild(fbElement);
    }
    for (final extension in description.headerExtensions) {
      final extElement = XmppElement()..name = 'rtp-hdrext';
      extElement.addAttribute(XmppAttribute('xmlns', rtpHdrextNamespace));
      extElement.addAttribute(XmppAttribute('id', extension.id.toString()));
      extElement.addAttribute(XmppAttribute('uri', extension.uri));
      final senders = extension.senders;
      if (senders != null && senders.isNotEmpty) {
        extElement.addAttribute(XmppAttribute('senders', senders));
      }
      element.addChild(extElement);
    }
    return element;
  }

  XmppElement _buildIceTransport(JingleIceTransport transport) {
    final element = XmppElement()..name = 'transport';
    element.addAttribute(XmppAttribute('xmlns', iceUdpNamespace));
    if (transport.ufrag.isNotEmpty) {
      element.addAttribute(XmppAttribute('ufrag', transport.ufrag));
    }
    if (transport.password.isNotEmpty) {
      element.addAttribute(XmppAttribute('pwd', transport.password));
    }
    final fingerprint = transport.fingerprint;
    if (fingerprint != null) {
      final fpElement = XmppElement()..name = 'fingerprint';
      fpElement.addAttribute(XmppAttribute('xmlns', dtlsNamespace));
      fpElement.addAttribute(XmppAttribute('hash', fingerprint.hash));
      final setup = fingerprint.setup;
      if (setup != null && setup.isNotEmpty) {
        fpElement.addAttribute(XmppAttribute('setup', setup));
      }
      fpElement.textValue = fingerprint.fingerprint;
      element.addChild(fpElement);
    }
    for (final candidate in transport.candidates) {
      final candidateElement = XmppElement()..name = 'candidate';
      candidateElement.addAttribute(
          XmppAttribute('foundation', candidate.foundation));
      candidateElement.addAttribute(
          XmppAttribute('component', candidate.component.toString()));
      candidateElement.addAttribute(
          XmppAttribute('protocol', candidate.protocol));
      candidateElement.addAttribute(
          XmppAttribute('priority', candidate.priority.toString()));
      candidateElement.addAttribute(XmppAttribute('ip', candidate.ip));
      candidateElement.addAttribute(
          XmppAttribute('port', candidate.port.toString()));
      candidateElement.addAttribute(XmppAttribute('type', candidate.type));
      final generation = candidate.generation;
      if (generation != null) {
        candidateElement.addAttribute(
            XmppAttribute('generation', generation.toString()));
      }
      element.addChild(candidateElement);
    }
    return element;
  }
}
