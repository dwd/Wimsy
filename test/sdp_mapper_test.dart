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
        'a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\n'
        'a=ssrc:1234 cname:abcd\n'
        'a=ssrc-group:FID 1234 5678\n';

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
    expect(mapping.description.sources, isNotEmpty);
    expect(mapping.description.sourceGroups, isNotEmpty);
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
        sources: [
          JingleRtpSource(ssrc: 1234, parameters: {'cname': 'abcd'}),
        ],
        sourceGroups: [
          JingleRtpSourceGroup(semantics: 'FID', sources: [1234, 5678]),
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
    expect(sdp, contains('a=rtcp-mux'));
    expect(sdp, contains('a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level'));
    expect(sdp, contains('a=ssrc:1234 cname:abcd'));
    expect(sdp, contains('a=ssrc-group:FID 1234 5678'));
  });

  test('mapSdpToJingle selects media section and preserves msid', () {
    const sdp = 'v=0\n'
        'o=- 0 0 IN IP4 127.0.0.1\n'
        's=-\n'
        't=0 0\n'
        'a=ice-ufrag:sessionuf\n'
        'a=ice-pwd:sessionpw\n'
        'a=fingerprint:sha-256 AA:BB\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\n'
        'a=mid:audio0\n'
        'a=msid:stream1 track1\n'
        'a=rtpmap:111 opus/48000/2\n'
        'a=ssrc:1111 cname:audio\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96\n'
        'a=mid:video0\n'
        'a=rtpmap:96 VP8/90000\n'
        'a=ssrc:2222 cname:video\n';

    final audioMapping = mapSdpToJingle(
      sdp: sdp,
      mediaKind: CallMediaKind.audio,
    );
    expect(audioMapping.contentName, 'audio0');
    expect(audioMapping.description.payloadTypes.first.name, 'opus');
    expect(audioMapping.description.sources.first.parameters['msid'], 'stream1 track1');

    final videoMapping = mapSdpToJingle(
      sdp: sdp,
      mediaKind: CallMediaKind.video,
    );
    expect(videoMapping.contentName, 'video0');
    expect(videoMapping.description.payloadTypes.first.name, 'VP8');
  });

  test('mapSdpToJingle captures DTLS setup attribute', () {
    const sdp = 'v=0\n'
        'o=- 0 0 IN IP4 127.0.0.1\n'
        's=-\n'
        't=0 0\n'
        'a=setup:actpass\n'
        'a=fingerprint:sha-256 AA:BB\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\n'
        'a=rtpmap:111 opus/48000/2\n';

    final mapping = mapSdpToJingle(
      sdp: sdp,
      mediaKind: CallMediaKind.audio,
    );

    expect(mapping.transport.fingerprint?.setup, 'actpass');
  });

  test('buildMinimalSdpFromJingle includes DTLS setup attribute', () {
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
        fingerprint: JingleDtlsFingerprint(
          hash: 'sha-256',
          fingerprint: 'AA:BB',
          setup: 'actpass',
        ),
      ),
      contentName: 'audio',
    );

    expect(sdp, contains('a=setup:actpass'));
  });

  test('buildMinimalSdpFromJingleContents includes bundle and mids', () {
    final sdp = buildMinimalSdpFromJingleContents(contents: const [
      JingleContent(
        name: 'audio0',
        creator: 'initiator',
        rtpDescription: JingleRtpDescription(
          media: 'audio',
          payloadTypes: [
            JingleRtpPayloadType(id: 111, name: 'opus', clockRate: 48000, channels: 2),
          ],
        ),
        iceTransport: JingleIceTransport(
          ufrag: 'uf',
          password: 'pw',
          candidates: [],
        ),
      ),
      JingleContent(
        name: 'video0',
        creator: 'initiator',
        rtpDescription: JingleRtpDescription(
          media: 'video',
          payloadTypes: [
            JingleRtpPayloadType(id: 96, name: 'VP8', clockRate: 90000),
          ],
        ),
        iceTransport: JingleIceTransport(
          ufrag: 'uf',
          password: 'pw',
          candidates: [],
        ),
      ),
    ]);

    expect(sdp, contains('a=group:BUNDLE audio0 video0'));
    expect(sdp, contains('a=mid:audio0'));
    expect(sdp, contains('a=mid:video0'));
    expect(sdp, contains('a=rtcp-mux'));
    expect(sdp, contains('m=audio 9 UDP/TLS/RTP/SAVPF 111'));
    expect(sdp, contains('m=video 9 UDP/TLS/RTP/SAVPF 96'));
  });
}
