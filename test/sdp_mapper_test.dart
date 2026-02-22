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
        'a=mid:audio\n'
        'a=fingerprint:sha-256 AA:BB\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\n'
        'a=rtpmap:111 opus/48000/2\n'
        'a=fmtp:111 minptime=10;useinbandfec=1\n'
        'a=rtcp-fb:111 nack pli\n'
        'a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\n';

    final mapping = mapSdpToJingle(
      sdp: sdp,
      mediaKind: CallMediaKind.audio,
    );

    expect(mapping.transport.ufrag, 'ufrag');
    expect(mapping.transport.password, 'pwd');
    expect(mapping.transport.fingerprint?.hash, 'sha-256');
    expect(mapping.description.payloadTypes, hasLength(1));
    expect(mapping.description.payloadTypes.first.name, 'opus');
    expect(mapping.description.payloadTypes.first.parameters['minptime'], '10');
    expect(mapping.description.rtcpFeedback, isNotEmpty);
    expect(mapping.description.headerExtensions, isNotEmpty);
    expect(mapping.contentName, 'audio');
  });

  test('buildMinimalSdpFromJingle includes rtpmap', () {
    final sdp = buildMinimalSdpFromJingle(
      description: const JingleRtpDescription(
        media: 'audio',
        payloadTypes: [
          JingleRtpPayloadType(
            id: 111,
            name: 'opus',
            clockRate: 48000,
            channels: 2,
            parameters: {'minptime': '10'},
          ),
        ],
        rtcpFeedback: [
          JingleRtpFeedback(type: 'nack', subtype: 'pli'),
        ],
        headerExtensions: [
          JingleRtpHeaderExtension(
            id: 1,
            uri: 'urn:ietf:params:rtp-hdrext:ssrc-audio-level',
          ),
        ],
      ),
      transport: const JingleIceTransport(
        ufrag: 'uf',
        password: 'pw',
        candidates: [],
      ),
      contentName: 'audio',
    );

    expect(sdp, contains('a=rtpmap:111 opus/48000/2'));
    expect(sdp, contains('a=fmtp:111 minptime=10'));
    expect(sdp, contains('a=rtcp-fb:* nack pli'));
    expect(sdp, contains('a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level'));
  });
}
