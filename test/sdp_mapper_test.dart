import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/av/call_session.dart';
import 'package:wimsy/av/sdp_mapper.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('mapSdpToJingle extracts ICE and payloads', () {
    const sdp = 'v=0\n'
        'o=- 0 0 IN IP4 127.0.0.1\n'
        's=-\n'
        't=0 0\n'
        'a=ice-ufrag:ufrag\n'
        'a=ice-pwd:pwd\n'
        'a=fingerprint:sha-256 AA:BB\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\n'
        'a=rtpmap:111 opus/48000/2\n';

    final mapping = mapSdpToJingle(
      sdp: sdp,
      mediaKind: CallMediaKind.audio,
    );

    expect(mapping.transport.ufrag, 'ufrag');
    expect(mapping.transport.password, 'pwd');
    expect(mapping.transport.fingerprint?.hash, 'sha-256');
    expect(mapping.description.payloadTypes, hasLength(1));
    expect(mapping.description.payloadTypes.first.name, 'opus');
  });

  test('buildMinimalSdpFromJingle includes rtpmap', () {
    final sdp = buildMinimalSdpFromJingle(
      description: const JingleRtpDescription(
        media: 'audio',
        payloadTypes: [
          JingleRtpPayloadType(id: 111, name: 'opus', clockRate: 48000, channels: 2),
        ],
      ),
      transport: const JingleIceTransport(
        ufrag: 'uf',
        password: 'pw',
        candidates: [],
      ),
    );

    expect(sdp, contains('a=rtpmap:111 opus/48000/2'));
  });
}
