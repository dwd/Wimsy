import 'package:xmpp_stone/xmpp_stone.dart';

const String jmiNamespace = 'urn:xmpp:jingle-message:0';
const String rtpNamespace = 'urn:xmpp:jingle:apps:rtp:1';
const String rtcpFbNamespace = 'urn:xmpp:jingle:apps:rtp:rtcp-fb:0';
const String rtpHdrextNamespace = 'urn:xmpp:jingle:apps:rtp:rtp-hdrext:0';

enum JmiAction {
  propose,
  proceed,
  reject,
  ringing,
  retract,
}

class JmiPropose {
  const JmiPropose({
    required this.sid,
    required this.description,
  });

  final String sid;
  final JingleRtpDescription description;
}

XmppElement buildJmiProposeElement({
  required String sid,
  required JingleRtpDescription description,
}) {
  final propose = XmppElement()..name = 'propose';
  propose.addAttribute(XmppAttribute('xmlns', jmiNamespace));
  propose.addAttribute(XmppAttribute('id', sid));
  propose.addChild(_buildRtpDescription(description));
  return propose;
}

XmppElement buildJmiProceedElement({required String sid}) {
  final proceed = XmppElement()..name = 'proceed';
  proceed.addAttribute(XmppAttribute('xmlns', jmiNamespace));
  proceed.addAttribute(XmppAttribute('id', sid));
  return proceed;
}

XmppElement buildJmiRejectElement({required String sid}) {
  final reject = XmppElement()..name = 'reject';
  reject.addAttribute(XmppAttribute('xmlns', jmiNamespace));
  reject.addAttribute(XmppAttribute('id', sid));
  return reject;
}

XmppElement buildJmiRingingElement({required String sid}) {
  final ringing = XmppElement()..name = 'ringing';
  ringing.addAttribute(XmppAttribute('xmlns', jmiNamespace));
  ringing.addAttribute(XmppAttribute('id', sid));
  return ringing;
}

XmppElement buildJmiRetractElement({required String sid}) {
  final retract = XmppElement()..name = 'retract';
  retract.addAttribute(XmppAttribute('xmlns', jmiNamespace));
  retract.addAttribute(XmppAttribute('id', sid));
  return retract;
}

JmiAction? parseJmiAction(XmppElement stanza) {
  for (final child in stanza.children) {
    final name = child.name ?? '';
    if (child.getAttribute('xmlns')?.value != jmiNamespace) {
      continue;
    }
    switch (name) {
      case 'propose':
        return JmiAction.propose;
      case 'proceed':
        return JmiAction.proceed;
      case 'reject':
        return JmiAction.reject;
      case 'ringing':
        return JmiAction.ringing;
      case 'retract':
        return JmiAction.retract;
    }
  }
  return null;
}

JmiPropose? parseJmiPropose(XmppElement stanza) {
  for (final child in stanza.children) {
    if (child.name != 'propose' ||
        child.getAttribute('xmlns')?.value != jmiNamespace) {
      continue;
    }
    final sid = child.getAttribute('id')?.value ?? '';
    if (sid.isEmpty) {
      return null;
    }
    final description = _parseRtpDescription(child.getChild('description'));
    if (description == null) {
      return null;
    }
    return JmiPropose(sid: sid, description: description);
  }
  return null;
}

String? parseJmiSid(XmppElement stanza) {
  for (final child in stanza.children) {
    if (child.getAttribute('xmlns')?.value != jmiNamespace) {
      continue;
    }
    final sid = child.getAttribute('id')?.value ?? '';
    if (sid.isNotEmpty) {
      return sid;
    }
  }
  return null;
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
    for (final entry in payload.parameters.entries) {
      final param = XmppElement()..name = 'parameter';
      param.addAttribute(XmppAttribute('name', entry.key));
      param.addAttribute(XmppAttribute('value', entry.value));
      payloadElement.addChild(param);
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
      final parameters = <String, String>{};
      for (final param in child.children) {
        if (param.name != 'parameter') {
          continue;
        }
        final nameAttr = param.getAttribute('name')?.value ?? '';
        final valueAttr = param.getAttribute('value')?.value ?? '';
        if (nameAttr.isEmpty) {
          continue;
        }
        parameters[nameAttr] = valueAttr;
      }
      payloadTypes.add(JingleRtpPayloadType(
        id: id,
        name: (name == null || name.isEmpty) ? null : name,
        clockRate: clockRate,
        channels: channels,
        parameters: parameters,
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
