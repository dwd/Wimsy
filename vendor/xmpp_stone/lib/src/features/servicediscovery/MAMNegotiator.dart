import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';

import '../../Connection.dart';
import '../Negotiator.dart';
import 'Feature.dart';

class MAMNegotiator extends Negotiator {
  static final Map<Connection, MAMNegotiator> _instances = {};

  static MAMNegotiator getInstance(Connection connection) {
    var instance = _instances[connection];
    if (instance == null) {
      instance = MAMNegotiator(connection);
      _instances[connection] = instance;
    }
    return instance;
  }

  static void removeInstance(Connection connection) {
    _instances.remove(connection);
  }

  bool enabled = false;

  bool hasExtended = false;

  MAMNegotiator(Connection _) {
    expectedName = 'urn:xmpp:mam';
  }

  /// Core MAM requires the `before-id` and `after-id` alternatives only when
  /// the archive advertises the extended feature.
  bool get isQueryByIdSupported => hasExtended;

  /// Every MAM 2 archive is required to support the `start` and `end` fields.
  bool get isQueryByDateSupported => enabled;

  /// Every MAM 2 archive is required to support the `with` field.
  bool get isQueryByJidSupported => enabled;

  @override
  List<Nonza> match(List<Nonza> requests) {
    return requests
        .where((element) =>
            element is Feature &&
            ((element).xmppVar == 'urn:xmpp:mam:2' ||
                (element).xmppVar == 'urn:xmpp:mam:2#extended'))
        .toList();
  }

  @override
  void negotiate(List<Nonza> nonzas) {
    final features = match(nonzas).cast<Feature>();
    enabled = features.isNotEmpty;
    hasExtended = features.any(
      (feature) => feature.xmppVar == 'urn:xmpp:mam:2#extended',
    );
    state = NegotiatorState.NEGOTIATING;
    // negotiate() runs before ConnectionNegotiatorManager subscribes to the
    // broadcast state stream, so publish completion in the next microtask.
    Future<void>.microtask(() => state = NegotiatorState.DONE);
  }
}
