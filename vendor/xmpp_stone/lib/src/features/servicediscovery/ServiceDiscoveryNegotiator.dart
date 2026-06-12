import 'dart:async';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/elements/stanzas/AbstractStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';
import 'package:xmpp_stone/src/extensions/iq_router/IqRouter.dart';
import 'package:xmpp_stone/src/features/Negotiator.dart';
import 'package:xmpp_stone/src/features/servicediscovery/Feature.dart';
import 'package:xmpp_stone/src/features/servicediscovery/Identity.dart';
import 'package:xmpp_stone/src/features/servicediscovery/ServiceDiscoverySupport.dart';

class ServiceDiscoveryNegotiator extends Negotiator {
  static const String NAMESPACE_DISCO_INFO =
      'http://jabber.org/protocol/disco#info';
  static const String _NAMESPACE_CAPS =
      'http://jabber.org/protocol/caps';

  static final Map<Connection, ServiceDiscoveryNegotiator> _instances = {};

  /// Caps cache shared across all connections: maps `node#ver` to the
  /// verified disco#info feature set. Seeded from persistent storage
  /// before connecting so we can skip the disco#info IQ when the server
  /// advertises a caps hash we already know.
  static final Map<String, Set<String>> _capsCache = {};

  /// Seed the caps cache from persistent storage. Call this before
  /// connecting so that the negotiator can elide the disco#info IQ when
  /// the server's caps hash is already known.
  static void seedCapsCache(Map<String, Set<String>> cached) {
    for (final entry in cached.entries) {
      _capsCache.putIfAbsent(entry.key, () => Set<String>.from(entry.value));
    }
  }

  /// Clear the entire caps cache. Intended for testing and account-reset
  /// flows only.
  static void clearCapsCache() {
    _capsCache.clear();
  }

  /// Callback invoked after a successful disco#info response so the app
  /// layer can persist the result. Set by the app before connecting.
  static void Function(String capsKey, Set<String> features)? onCapsResult;

  static ServiceDiscoveryNegotiator getInstance(Connection connection) {
    var instance = _instances[connection];
    if (instance == null) {
      instance = ServiceDiscoveryNegotiator(connection);
      _instances[connection] = instance;
    }
    return instance;
  }

  static void removeInstance(Connection connection) {
    _instances[connection]?._router.unregisterNamespaceHandler(NAMESPACE_DISCO_INFO);
    _instances.remove(connection);
  }

  IqStanza? fullRequestStanza;

  /// The `node#ver` caps key advertised by the server in stream features,
  /// if any. Set by [ConnectionNegotiatorManager] before [negotiate] is
  /// called.
  String? serverCapsKey;

  final Connection _connection;
  late final IqRouter _router;

  ServiceDiscoveryNegotiator(this._connection) {
    _connection.connectionStateStream.listen((state) {
      expectedName = 'ServiceDiscoveryNegotiator';
    });
    _router = IqRouter.getInstance(_connection);
    _router.registerNamespaceHandler(NAMESPACE_DISCO_INFO, _handleDiscoInfoRequest);
  }

  final StreamController<XmppElement> _errorStreamController =
      StreamController<XmppElement>();

  final List<Feature> _supportedFeatures = <Feature>[];

  final List<Identity> _supportedIdentities = <Identity>[];

  Stream<XmppElement> get errorStream {
    return _errorStreamController.stream;
  }

  @override
  List<Nonza> match(List<Nonza> requests) {
    return [];
  }

  @override
  void negotiate(List<Nonza> nonza) {
    if (state == NegotiatorState.IDLE) {
      state = NegotiatorState.NEGOTIATING;
      // If the server advertised a caps hash in stream features and we
      // already have the verified feature set cached, skip the disco#info
      // IQ entirely and populate features from the cache.
      final capsKey = serverCapsKey;
      if (capsKey != null) {
        final cached = _capsCache[capsKey];
        if (cached != null) {
          _populateFeaturesFromCache(cached);
          return;
        }
      }
      _sendServiceDiscoveryRequest();
    } else if (state == NegotiatorState.DONE) {}
  }

  void _populateFeaturesFromCache(Set<String> featureVars) {
    _supportedFeatures.clear();
    _supportedIdentities.clear();
    for (final featureVar in featureVars) {
      final f = Feature();
      f.addAttribute(XmppAttribute('var', featureVar));
      _supportedFeatures.add(f);
    }
    _connection.connectionNegotatiorManager.addFeatures(_supportedFeatures);
    // Defer the DONE state change so that the ConnectionNegotiatorManager's
    // stateListener is attached before the event fires. When the cache path
    // is taken, negotiate() is called synchronously inside negotiateNextFeature()
    // before the featureStateStream.listen() call, so a synchronous state
    // change would be missed by the broadcast stream.
    Future.microtask(() => state = NegotiatorState.DONE);
  }

  void _sendServiceDiscoveryRequest() {
    var request = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.GET);
    request.fromJid = _connection.fullJid;
    request.toJid = _connection.serverName;
    var queryElement = XmppElement();
    queryElement.name = 'query';
    queryElement.addAttribute(
        XmppAttribute('xmlns', 'http://jabber.org/protocol/disco#info'));
    request.addChild(queryElement);
    fullRequestStanza = request;
    if (request.id != null) {
      _router.registerResponseHandler(request.id!, _handleDiscoInfoResponse);
    }
    _connection.writeStanza(request);
  }

  void _handleDiscoInfoResponse(IqStanza stanza) {
    _parseFullInfoResponse(stanza);
  }

  void _parseFullInfoResponse(IqStanza stanza) {
    _supportedFeatures.clear();
    _supportedIdentities.clear();
    if (stanza.type == IqStanzaType.RESULT) {
      var queryStanza = stanza.getChild('query');
      if (queryStanza != null) {
        queryStanza.children.forEach((element) {
          if (element is Identity) {
            _supportedIdentities.add(element);
          } else if (element is Feature) {
            _supportedFeatures.add(element);
          }
        });
      }
      // Cache the result keyed by the server's caps hash so future
      // connections can skip the disco#info IQ.
      final capsKey = serverCapsKey;
      if (capsKey != null && _supportedFeatures.isNotEmpty) {
        final featureVars =
            _supportedFeatures.map((f) => f.xmppVar ?? '').where((v) => v.isNotEmpty).toSet();
        _capsCache.putIfAbsent(capsKey, () => featureVars);
        onCapsResult?.call(capsKey, featureVars);
      }
    } else if (stanza.type == IqStanzaType.ERROR) {
      var errorStanza = stanza.getChild('error');
      if (errorStanza != null) {
        _errorStreamController.add(errorStanza);
      }
    }
    _connection.connectionNegotatiorManager.addFeatures(_supportedFeatures);
    state = NegotiatorState.DONE;
  }

  bool isFeatureSupported(String feature) {
    return _supportedFeatures
            .firstWhereOrNull((element) => element.xmppVar == feature) !=
        null;
  }

  List<Feature> getSupportedFeatures() {
    return _supportedFeatures;
  }

  IqStanza? _handleDiscoInfoRequest(IqStanza request) {
    if (request.type != IqStanzaType.GET) {
      return null;
    }
    var iqStanza = IqStanza(request.id, IqStanzaType.RESULT);
    //iqStanza.fromJid = _connection.fullJid; //do not send for now
    iqStanza.toJid = request.fromJid;
    var query = XmppElement();
    query.name = 'query';
    query.addAttribute(XmppAttribute('xmlns', NAMESPACE_DISCO_INFO));
    for (final identity in SERVICE_DISCOVERY_IDENTITIES) {
      var identityElement = XmppElement();
      identityElement.name = 'identity';
      identityElement.addAttribute(
          XmppAttribute('category', identity['category'] ?? ''));
      identityElement
          .addAttribute(XmppAttribute('type', identity['type'] ?? ''));
      final name = identity['name'];
      if (name != null && name.isNotEmpty) {
        identityElement.addAttribute(XmppAttribute('name', name));
      }
      final lang = identity['lang'];
      if (lang != null && lang.isNotEmpty) {
        identityElement.addAttribute(XmppAttribute('xml:lang', lang));
      }
      query.addChild(identityElement);
    }
    SERVICE_DISCOVERY_SUPPORT_LIST.forEach((featureName) {
      var featureElement = XmppElement();
      featureElement.name = 'feature';
      featureElement.addAttribute(XmppAttribute('var', featureName));
      query.addChild(featureElement);
    });
    iqStanza.addChild(query);
    return iqStanza;
  }
}

extension ServiceDiscoveryExtension on Connection {
  List<Feature> getSupportedFeatures() {
    return ServiceDiscoveryNegotiator.getInstance(this).getSupportedFeatures();
  }
}
