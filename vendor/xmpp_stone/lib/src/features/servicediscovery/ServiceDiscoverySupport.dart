const List<String> SERVICE_DISCOVERY_SUPPORT_LIST = [
  'http://jabber.org/protocol/chatstates',
  'http://jabber.org/protocol/ibb',
  'urn:xmpp:blocking',
  'urn:xmpp:avatar:metadata+notify',
  'urn:xmpp:jingle:1',
  'urn:xmpp:jingle:apps:rtp:1',
  'urn:xmpp:jingle:apps:rtp:audio',
  'urn:xmpp:jingle:apps:rtp:video',
  'urn:xmpp:jingle:transports:ice-udp:1',
  'urn:xmpp:jingle:apps:dtls:0',
  'urn:xmpp:jingle:apps:file-transfer:5',
  'urn:xmpp:jingle:transports:ibb:1',
  'urn:xmpp:mds:displayed:0+notify',
];

const List<Map<String, String>> SERVICE_DISCOVERY_IDENTITIES = [
  {
    'category': 'client',
    'type': 'pc',
    'name': 'Wimsy',
    'lang': '',
  },
];
