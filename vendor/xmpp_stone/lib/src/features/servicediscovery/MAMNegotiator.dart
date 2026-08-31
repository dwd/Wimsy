import 'dart:async';

import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/forms/FieldElement.dart';
import 'package:xmpp_stone/src/elements/forms/QueryElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/elements/stanzas/AbstractStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';

import '../../Connection.dart';
import '../../logger/Log.dart';
import '../Negotiator.dart';
import 'Feature.dart';

class MAMNegotiator extends Negotiator {
  static const TAG = 'MAMNegotiator';

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
    _instances[connection]?._subscription?.cancel();
    _instances[connection]?._responseTimer?.cancel();
    _instances.remove(connection);
  }

  late IqStanza _myUnrespondedIqStanza;

  StreamSubscription<AbstractStanza?>? _subscription;
  Timer? _responseTimer;

  final Connection _connection;
  final Duration responseTimeout;

  final List<MamQueryParameters> _supportedParameters = [];

  bool enabled = false;

  bool? hasExtended;

  MAMNegotiator(
    this._connection, {
    this.responseTimeout = const Duration(seconds: 15),
  }) {
    expectedName = 'urn:xmpp:mam';
  }

  bool get isQueryByIdSupported =>
      _supportedParameters.contains(MamQueryParameters.BEFORE_ID) &&
      _supportedParameters.contains(MamQueryParameters.AFTER_ID);

  bool get isQueryByDateSupported =>
      _supportedParameters.contains(MamQueryParameters.START) &&
      _supportedParameters.contains(MamQueryParameters.END);

  bool get isQueryByJidSupported =>
      _supportedParameters.contains(MamQueryParameters.WITH);

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
    if (match(nonzas).isNotEmpty) {
      enabled = true;
      state = NegotiatorState.NEGOTIATING;
      _subscription = _connection.inStanzasStream.listen(checkStanzas);
      _responseTimer = Timer(responseTimeout, _handleResponseTimeout);
      sendRequest();
    }
  }

  @override
  void backToIdle() {
    _responseTimer?.cancel();
    _responseTimer = null;
    _subscription?.cancel();
    _subscription = null;
    super.backToIdle();
  }

  void _handleResponseTimeout() {
    if (state != NegotiatorState.NEGOTIATING) return;
    Log.w(TAG, 'MAM capability query timed out; continuing connection setup');
    _responseTimer = null;
    _subscription?.cancel();
    _subscription = null;
    state = NegotiatorState.DONE;
  }

  void sendRequest() {
    var iqStanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.GET);
    var query = QueryElement();
    query.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:mam:2'));
    iqStanza.addChild(query);
    _myUnrespondedIqStanza = iqStanza;
    _connection.writeStanza(iqStanza);
  }

  void checkStanzas(AbstractStanza? stanza) {
    if (stanza is IqStanza && stanza.id == _myUnrespondedIqStanza.id) {
      _responseTimer?.cancel();
      _responseTimer = null;
      var x = stanza.getChild('query')?.getChild('x');
      if (x != null) {
        x.children.forEach((element) {
          if (element is FieldElement) {
            switch (element.varAttr) {
              case 'start':
                _supportedParameters.add(MamQueryParameters.START);
                break;
              case 'end':
                _supportedParameters.add(MamQueryParameters.END);
                break;
              case 'with':
                _supportedParameters.add(MamQueryParameters.WITH);
                break;
              case 'before-id':
                _supportedParameters.add(MamQueryParameters.BEFORE_ID);
                break;
              case 'after-id':
                _supportedParameters.add(MamQueryParameters.AFTER_ID);
                break;
              case 'ids':
                _supportedParameters.add(MamQueryParameters.IDS);
                break;
            }
          }
        });
      }
      state = NegotiatorState.DONE;
      _subscription?.cancel();
      _subscription = null;
    }
  }

  void checkForExtendedSupport(List<Nonza> nonzas) {
    hasExtended = nonzas.any(
        (element) => (element as Feature).xmppVar == 'urn:xmpp:mam:2#extended');
  }
}

enum MamQueryParameters { WITH, START, END, BEFORE_ID, AFTER_ID, IDS }
