import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/av/sdp_mapper.dart';
import 'package:wimsy/xmpp/jingle_grouping.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

void main() {
  test('contentNamesFor prefers explicit names and deduplicates', () {
    final names = contentNamesFor(const [
      JingleContent(
        name: 'audio0',
        creator: 'initiator',
        rtpDescription: JingleRtpDescription(media: 'audio', payloadTypes: []),
      ),
      JingleContent(
        name: '',
        creator: 'initiator',
        rtpDescription: JingleRtpDescription(media: 'video', payloadTypes: []),
      ),
      JingleContent(
        name: 'audio0',
        creator: 'initiator',
        rtpDescription: JingleRtpDescription(media: 'audio', payloadTypes: []),
      ),
    ]);

    expect(names, ['audio0', 'video']);
  });

  test('bundleGroupNamesForContents orders audio then video then extras', () {
    final names = bundleGroupNamesForContents(const [
      JingleContent(
        name: 'data0',
        creator: 'initiator',
        rtpDescription: JingleRtpDescription(
          media: 'application',
          payloadTypes: [],
        ),
      ),
      JingleContent(
        name: 'video0',
        creator: 'initiator',
        rtpDescription: JingleRtpDescription(media: 'video', payloadTypes: []),
      ),
      JingleContent(
        name: 'audio0',
        creator: 'initiator',
        rtpDescription: JingleRtpDescription(media: 'audio', payloadTypes: []),
      ),
    ]);

    expect(names, ['audio0', 'video0', 'data0']);
  });

  test('bundleTransportNameForMappings prefers audio content', () {
    const audioMapping = JingleSdpMapping(
      description: JingleRtpDescription(media: 'audio', payloadTypes: []),
      transport: JingleIceTransport(ufrag: 'a', password: 'b', candidates: []),
      contentName: 'audio0',
    );
    const videoMapping = JingleSdpMapping(
      description: JingleRtpDescription(media: 'video', payloadTypes: []),
      transport: JingleIceTransport(ufrag: 'a', password: 'b', candidates: []),
      contentName: 'video0',
    );

    final name = bundleTransportNameForMappings(const [
      videoMapping,
      audioMapping,
    ]);
    expect(name, 'audio0');
  });

  test('extractBundleGroupNames reads BUNDLE group from jingle stanza', () {
    final iq = IqStanza('id1', IqStanzaType.SET);
    final jingle = XmppElement()..name = 'jingle';
    final group = XmppElement()..name = 'group';
    group.addAttribute(
      XmppAttribute('xmlns', 'urn:xmpp:jingle:apps:grouping:0'),
    );
    group.addAttribute(XmppAttribute('semantics', 'BUNDLE'));
    final audio = XmppElement()..name = 'content';
    audio.addAttribute(XmppAttribute('name', 'audio0'));
    final video = XmppElement()..name = 'content';
    video.addAttribute(XmppAttribute('name', 'video0'));
    group.addChild(audio);
    group.addChild(video);
    jingle.addChild(group);
    iq.addChild(jingle);

    final names = extractBundleGroupNames(
      iq,
      groupingNamespace: 'urn:xmpp:jingle:apps:grouping:0',
      groupingBundle: 'BUNDLE',
    );
    expect(names, ['audio0', 'video0']);
  });

  test('attachBundleGroup adds group once and skips when existing', () {
    final iq = IqStanza('id2', IqStanzaType.SET);
    iq.addChild(XmppElement()..name = 'jingle');

    attachBundleGroup(
      iq,
      ['audio0', 'video0'],
      groupingNamespace: 'urn:xmpp:jingle:apps:grouping:0',
      groupingBundle: 'BUNDLE',
    );
    attachBundleGroup(
      iq,
      ['audio0', 'video0'],
      groupingNamespace: 'urn:xmpp:jingle:apps:grouping:0',
      groupingBundle: 'BUNDLE',
    );

    final jingle = iq.getChild('jingle');
    expect(jingle, isNotNull);
    final groups = jingle!.children
        .where((child) => child.name == 'group')
        .toList();
    expect(groups.length, 1);
  });
}
