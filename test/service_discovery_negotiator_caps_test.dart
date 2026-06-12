import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';
import 'package:xmpp_stone/src/features/Negotiator.dart';
import 'package:xmpp_stone/src/features/servicediscovery/Feature.dart';

/// Tests for the XEP-0115 caps-hash elision of the server disco#info IQ.
///
/// On connect the server advertises its capabilities via a `<c>` element in
/// `<stream:features>`.  If we already have the verified feature set for that
/// `node#ver` in the cache we must skip the disco#info IQ entirely.  If the
/// hash is unknown we send the IQ as before and then cache the result so that
/// subsequent connects can elide it.

class _TestConnection extends Connection {
  _TestConnection(super.account);

  final List<AbstractStanza> written = [];
  final _inStanzasController = StreamController<AbstractStanza?>.broadcast();

  @override
  Stream<AbstractStanza?> get inStanzasStream => _inStanzasController.stream;

  @override
  void writeStanza(AbstractStanza stanza) => written.add(stanza);

  @override
  void writeNonza(Nonza nonza) {}

  @override
  void write(Object? message) {}

  /// Deliver a stanza as if it arrived from the server.
  void deliverIncoming(AbstractStanza stanza) {
    _inStanzasController.add(stanza);
  }
}

/// Build a minimal stream-features-like [XmppElement] that contains a caps
/// `<c>` child with the given [node] and [ver].  We use [XmppElement] directly
/// so the test has no dependency on the `xml` package.
XmppElement _streamFeaturesWithCaps({
  required String node,
  required String ver,
}) {
  final features = XmppElement()..name = 'stream:features';
  final c = XmppElement()..name = 'c';
  c.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/caps'));
  c.addAttribute(XmppAttribute('hash', 'sha-1'));
  c.addAttribute(XmppAttribute('node', node));
  c.addAttribute(XmppAttribute('ver', ver));
  features.addChild(c);
  return features;
}

/// Build a stream-features-like [XmppElement] with no caps child.
XmppElement _streamFeaturesNoCaps() {
  final features = XmppElement()..name = 'stream:features';
  final session = XmppElement()..name = 'session';
  session.addAttribute(
      XmppAttribute('xmlns', 'urn:ietf:params:xml:ns:xmpp-session'));
  features.addChild(session);
  return features;
}

/// Extract the `node#ver` caps key from a stream-features [XmppElement],
/// mirroring the logic in [ConnectionNegotiatorManager._extractServerCapsKey].
String? _extractCapsKey(XmppElement features) {
  for (final child in features.children) {
    if (child.name == 'c' &&
        child.getAttribute('xmlns')?.value ==
            'http://jabber.org/protocol/caps') {
      final node = child.getAttribute('node')?.value;
      final ver = child.getAttribute('ver')?.value;
      if (node != null && node.isNotEmpty && ver != null && ver.isNotEmpty) {
        return '$node#$ver';
      }
    }
  }
  return null;
}

void main() {
  setUp(() {
    // Clear the static caps cache and callback between tests to prevent
    // cross-test pollution.
    ServiceDiscoveryNegotiator.clearCapsCache();
    ServiceDiscoveryNegotiator.onCapsResult = null;
  });

  group('ServiceDiscoveryNegotiator caps-hash elision', () {
    test(
      'R: skips disco#info IQ when server caps hash is already cached',
      () async {
        const node = 'https://openfire.example.com/';
        const ver = 'TcsHJlFLfsfV63Fv7HoLvcmXAVw=';
        const capsKey = '$node#$ver';

        // Pre-seed the cache as if we had verified this caps hash in a
        // previous session.
        ServiceDiscoveryNegotiator.seedCapsCache({
          capsKey: {'urn:xmpp:mam:2', 'urn:xmpp:carbons:2'},
        });

        final account =
            XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
        final connection = _TestConnection(account);
        final negotiator = ServiceDiscoveryNegotiator.getInstance(connection);
        negotiator.serverCapsKey = capsKey;

        // Trigger negotiation — should use the cache, not send an IQ.
        negotiator.negotiate([]);

        expect(
          connection.written,
          isEmpty,
          reason: 'No disco#info IQ should be sent when caps are cached',
        );
        // The DONE state is set via Future.microtask so the
        // ConnectionNegotiatorManager's stateListener is attached first.
        // Await the microtask queue before asserting state.
        await Future.microtask(() {});
        expect(
          negotiator.state,
          NegotiatorState.DONE,
          reason: 'Negotiator should be DONE after a cache hit',
        );
        expect(
          negotiator.getSupportedFeatures().map((f) => f.xmppVar),
          containsAll(['urn:xmpp:mam:2', 'urn:xmpp:carbons:2']),
        );

        ServiceDiscoveryNegotiator.removeInstance(connection);
      },
    );

    test(
      'R: sends disco#info IQ when server caps hash is not cached',
      () {
        const node = 'https://openfire.example.com/';
        const ver = 'UNKNOWN_VER=';
        const capsKey = '$node#$ver';

        final account =
            XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
        final connection = _TestConnection(account);
        final negotiator = ServiceDiscoveryNegotiator.getInstance(connection);
        negotiator.serverCapsKey = capsKey;

        negotiator.negotiate([]);

        expect(
          connection.written,
          isNotEmpty,
          reason: 'A disco#info IQ must be sent for an unknown caps hash',
        );
        final iq = connection.written.first as IqStanza;
        expect(iq.type, IqStanzaType.GET);
        final query = iq.getChild('query');
        expect(
          query?.getAttribute('xmlns')?.value,
          'http://jabber.org/protocol/disco#info',
        );

        ServiceDiscoveryNegotiator.removeInstance(connection);
      },
    );

    test(
      'R: caches disco#info result and invokes onCapsResult callback',
      () async {
        const node = 'https://openfire.example.com/';
        const ver = 'NEW_VER=';
        const capsKey = '$node#$ver';

        String? callbackKey;
        Set<String>? callbackFeatures;
        ServiceDiscoveryNegotiator.onCapsResult = (k, f) {
          callbackKey = k;
          callbackFeatures = f;
        };

        final account =
            XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
        final connection = _TestConnection(account);
        final negotiator = ServiceDiscoveryNegotiator.getInstance(connection);
        negotiator.serverCapsKey = capsKey;

        // Trigger the IQ send.
        negotiator.negotiate([]);
        expect(connection.written, isNotEmpty);
        final iq = connection.written.first as IqStanza;

        // Simulate a disco#info result from the server by delivering it on
        // the inStanzasStream (which the IqRouter listens to).
        final result = IqStanza(iq.id, IqStanzaType.RESULT);
        result.fromJid = Jid.fromFullJid('example.com');
        final query = XmppElement()..name = 'query';
        query.addAttribute(
            XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
        final featureEl = Feature()
          ..addAttribute(XmppAttribute('var', 'urn:xmpp:mam:2'));
        query.addChild(featureEl);
        result.addChild(query);

        connection.deliverIncoming(result);

        // Allow the async IqRouter listener to process the stanza.
        await Future<void>.delayed(Duration.zero);

        expect(callbackKey, capsKey);
        expect(callbackFeatures, contains('urn:xmpp:mam:2'));

        // A second negotiator for the same caps key should now hit the cache.
        ServiceDiscoveryNegotiator.removeInstance(connection);
        final connection2 = _TestConnection(account);
        final negotiator2 =
            ServiceDiscoveryNegotiator.getInstance(connection2);
        negotiator2.serverCapsKey = capsKey;
        negotiator2.negotiate([]);

        expect(
          connection2.written,
          isEmpty,
          reason: 'Second connect should hit the cache and skip the IQ',
        );

        ServiceDiscoveryNegotiator.removeInstance(connection2);
      },
    );

    test(
      'R: no serverCapsKey set — still sends disco#info IQ',
      () {
        final account =
            XmppAccountSettings('test', 'user', 'example.com', 'pass', 5222);
        final connection = _TestConnection(account);
        final negotiator = ServiceDiscoveryNegotiator.getInstance(connection);
        // serverCapsKey is null (not set).

        negotiator.negotiate([]);

        expect(connection.written, isNotEmpty);

        ServiceDiscoveryNegotiator.removeInstance(connection);
      },
    );
  });

  group('Stream features caps key extraction', () {
    test(
      'R: extracts node#ver from stream features containing a caps element',
      () {
        const node = 'https://openfire.example.com/';
        const ver = 'TcsHJlFLfsfV63Fv7HoLvcmXAVw=';
        final features = _streamFeaturesWithCaps(node: node, ver: ver);

        expect(_extractCapsKey(features), '$node#$ver');
      },
    );

    test(
      'R: no caps key when stream features contain no caps element',
      () {
        final features = _streamFeaturesNoCaps();

        expect(_extractCapsKey(features), isNull);
      },
    );
  });
}
