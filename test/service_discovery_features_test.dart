import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/src/features/servicediscovery/ServiceDiscoverySupport.dart';

/// Regression tests for the disco#info features Wimsy advertises.
///
/// These exist primarily to catch accidental removals: the +notify entries
/// determine whether the server forwards PubSub events to us without an
/// explicit `<subscribe/>`, so missing one of them silently regresses
/// startup traffic (we'd fall back to polling via IQ each connect).
void main() {
  group('SERVICE_DISCOVERY_SUPPORT_LIST', () {
    test('R1.2: advertises urn:xmpp:mds:displayed:0+notify', () {
      expect(
        SERVICE_DISCOVERY_SUPPORT_LIST,
        contains('urn:xmpp:mds:displayed:0+notify'),
      );
    });

    test('advertises urn:xmpp:avatar:metadata+notify', () {
      expect(
        SERVICE_DISCOVERY_SUPPORT_LIST,
        contains('urn:xmpp:avatar:metadata+notify'),
      );
    });

    test('contains the core Jingle/RTP/file-transfer namespaces', () {
      const expected = [
        'urn:xmpp:jingle:1',
        'urn:xmpp:jingle-message:0',
        'urn:xmpp:jingle:apps:rtp:1',
        'urn:xmpp:jingle:apps:rtp:audio',
        'urn:xmpp:jingle:apps:rtp:video',
        'urn:xmpp:jingle:transports:ice-udp:1',
        'urn:xmpp:jingle:apps:dtls:0',
        'urn:xmpp:jingle:apps:file-transfer:5',
        'urn:xmpp:jingle:transports:ibb:1',
      ];
      for (final feature in expected) {
        expect(
          SERVICE_DISCOVERY_SUPPORT_LIST,
          contains(feature),
          reason: 'missing required disco feature: $feature',
        );
      }
    });

    test('contains chatstates, blocking, IBB, reply, fallback', () {
      const expected = [
        'http://jabber.org/protocol/chatstates',
        'http://jabber.org/protocol/ibb',
        'urn:xmpp:blocking',
        'urn:xmpp:reply:0',
        'urn:xmpp:feature-fallback:0',
      ];
      for (final feature in expected) {
        expect(
          SERVICE_DISCOVERY_SUPPORT_LIST,
          contains(feature),
          reason: 'missing required disco feature: $feature',
        );
      }
    });
  });
}
