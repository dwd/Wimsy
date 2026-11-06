const List<String> SERVICE_DISCOVERY_SUPPORT_LIST = [
  'http://jabber.org/protocol/chatstates',
  'http://jabber.org/protocol/ibb',
  'urn:xmpp:blocking',
  'urn:xmpp:avatar:metadata+notify',
  'urn:xmpp:jingle:1',
  'urn:xmpp:jingle-message:0',
  'urn:xmpp:jingle:apps:rtp:1',
  'urn:xmpp:jingle:apps:rtp:audio',
  'urn:xmpp:jingle:apps:rtp:video',
  'urn:xmpp:jingle:apps:rtp:rtcp-fb:0',
  'urn:xmpp:jingle:apps:rtp:rtp-hdrext:0',
  'urn:xmpp:jingle:apps:rtp:ssma:0',
  'urn:xmpp:jingle:apps:grouping:0',
  'urn:xmpp:jingle:transports:ice-udp:1',
  'urn:xmpp:jingle:apps:dtls:0',
  'urn:xmpp:jingle:apps:file-transfer:5',
  'urn:xmpp:jingle:transports:ibb:1',
  'urn:xmpp:mds:displayed:0+notify',
  'urn:xmpp:reply:0',
  'urn:xmpp:feature-fallback:0',
  // OMEMO2 (XEP-0384 urn:xmpp:omemo:2) and legacy OMEMO (XEP-0384 v0.3.0,
  // eu.siacs.conversations.axolotl) device-list PEP nodes: advertising
  // "+notify" here is what makes contacts' clients (and ours) push PEP
  // <event/> updates proactively instead of relying solely on an explicit
  // IQ fetch, which is required for real-world interop (e.g. Conversations
  // subscribing to/seeing updates to our device list, and vice versa).
  'urn:xmpp:omemo:2:devices+notify',
  'eu.siacs.conversations.axolotl.devicelist+notify',
];

const List<Map<String, String>> SERVICE_DISCOVERY_IDENTITIES = [
  {
    'category': 'client',
    'type': 'pc',
    'name': 'Wimsy',
    'lang': '',
  },
];
