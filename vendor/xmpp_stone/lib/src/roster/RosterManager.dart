import 'dart:async';

import 'package:tuple/tuple.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/stanzas/AbstractStanza.dart';
import 'package:xmpp_stone/src/elements/stanzas/IqStanza.dart';
import 'package:xmpp_stone/src/extensions/iq_router/IqRouter.dart';
import 'package:xmpp_stone/src/roster/Buddy.dart';

//todo check for rfc6121 2.6.2
//todo add support for jid groups
class RosterManager {
  static Map<Connection, RosterManager> instances = {};

  static RosterManager getInstance(Connection connection) {
    var manager = instances[connection];
    if (manager == null) {
      manager = RosterManager(connection);
      instances[connection] = manager;
    }
    return manager;
  }

  static void removeInstance(Connection connection) {
    instances[connection]?._router.unregisterNamespaceHandler('jabber:iq:roster');
    instances[connection]?._xmppConnectionStateSubscription.cancel();
    instances.remove(connection);
  }

  final Map<String, Tuple2<IqStanza, Completer?>> _myUnrespondedIqStanzas = {};

  final StreamController<List<Buddy>> _rosterController = StreamController<List<Buddy>>.broadcast();

  late StreamSubscription<XmppConnectionState> _xmppConnectionStateSubscription;
  late IqRouter _router;

  Stream<List<Buddy>> get rosterStream {
    return _rosterController.stream;
  }

  final Map<Jid, Buddy> _rosterMap = {};
  String? _rosterVersion;

  late Connection _connection;

  void queryForRoster() {
    var iqStanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.GET);
    var element = XmppElement();
    element.name = 'query';
    element.addAttribute(XmppAttribute('xmlns', 'jabber:iq:roster'));
    if (_rosterVersion != null && _rosterVersion!.isNotEmpty) {
      element.addAttribute(XmppAttribute('ver', _rosterVersion));
    }
    iqStanza.addChild(element);
    _myUnrespondedIqStanzas[iqStanza.id!] = Tuple2(iqStanza, null);
    _router.registerResponseHandler(iqStanza.id!, _handleRosterResponse);
    _connection.writeStanza(iqStanza);
  }

  List<Buddy> getRoster() {
    return _rosterMap.values.toList();
  }

  String? get rosterVersion => _rosterVersion;

  void setRosterVersion(String? version) {
    _rosterVersion = version;
  }

  Future<IqStanzaResult> updateRosterItem(Buddy rosterItem) {
    return addRosterItem(rosterItem);
  }

  Future<IqStanzaResult> addRosterItem(Buddy rosterItem) {
    var completer = Completer<IqStanzaResult>();
    var iqStanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.SET);
    var queryElement = XmppElement();
    queryElement.name = 'query';
    queryElement.addAttribute(XmppAttribute('xmlns', 'jabber:iq:roster'));
    iqStanza.addChild(queryElement);
    var itemElement = XmppElement();
    itemElement.name = 'item';
    queryElement.addChild(itemElement);
    itemElement.addAttribute(XmppAttribute('jid', rosterItem.jid!.userAtDomain));
    if (rosterItem.name != null) {
      itemElement.addAttribute(XmppAttribute('name', rosterItem.name));
    }
    if (rosterItem.groups.isNotEmpty) {
      for (final group in rosterItem.groups) {
        if (group.trim().isEmpty) {
          continue;
        }
        final groupElement = XmppElement()
          ..name = 'group'
          ..textValue = group.trim();
        itemElement.addChild(groupElement);
      }
    }
    _myUnrespondedIqStanzas[iqStanza.id!] = Tuple2(iqStanza, completer);
    _router.registerResponseHandler(iqStanza.id!, _handleRosterResponse);
    _connection.writeStanza(iqStanza);
    return completer.future;
  }

  Future<IqStanzaResult> removeRosterItem(Buddy rosterItem) {
    var completer = Completer<IqStanzaResult>();
    var iqStanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.SET);
    var queryElement = XmppElement();
    queryElement.name = 'query';
    queryElement.addAttribute(XmppAttribute('xmlns', 'jabber:iq:roster'));
    iqStanza.addChild(queryElement);
    var itemElement = XmppElement();
    itemElement.name = 'item';
    queryElement.addChild(itemElement);
    itemElement.addAttribute(XmppAttribute('jid', rosterItem.jid!.userAtDomain));
    itemElement.addAttribute(XmppAttribute('subscription', 'remove'));
    _myUnrespondedIqStanzas[iqStanza.id!] = Tuple2(iqStanza, completer);
    _router.registerResponseHandler(iqStanza.id!, _handleRosterResponse);
    _connection.writeStanza(iqStanza);
    return completer.future;
  }

  RosterManager(Connection connection) {
    _connection = connection;
    _xmppConnectionStateSubscription = connection.connectionStateStream.listen(_connectionStateProcessor);
    _router = IqRouter.getInstance(connection);
    _router.registerNamespaceHandler('jabber:iq:roster', _handleRosterRequest);
  }

  void _connectionStateProcessor(XmppConnectionState state) {
    if (state == XmppConnectionState.Ready) {
      queryForRoster();
    } else if (state == XmppConnectionState.Closed) {
      _rosterMap.clear();
      _rosterController.add([]);
    }
  }

  void _handleRosterResponse(IqStanza stanza) {
    var unrespondedStanza = _myUnrespondedIqStanzas[stanza.id];
    if (unrespondedStanza == null) {
      return;
    }
    if (stanza.type == IqStanzaType.RESULT) {
      if (_isFullJidRequest(unrespondedStanza.item1)) {
        _handleFullRosterResponse(stanza);
      } else if (_isRosterSet(unrespondedStanza.item1)) {
        _handleRosterSetSuccessResponse(unrespondedStanza);
      }
    } else if (stanza.type == IqStanzaType.ERROR) {
      //todo handle error cases
      _handleRosterSetErrorResponse(unrespondedStanza);
    }
  }

  IqStanza? _handleRosterRequest(IqStanza stanza) {
    if (stanza.type != IqStanzaType.SET) {
      return null;
    }
    final query = stanza.getChild('query');
    if (query == null ||
        query.getAttribute('xmlns')?.value != 'jabber:iq:roster') {
      return null;
    }
    final hasItems = query.children.any((element) => element.name == 'item');
    if (!hasItems) {
      return null;
    }
    _applyRosterPush(stanza);
    return _buildRosterPushResult(stanza);
  }

  bool _isFullJidRequest(IqStanza iqStanza) {
    return (iqStanza.type == IqStanzaType.GET && (iqStanza.getChild('query')?.children.isEmpty ?? false));
  }

  bool _isRosterSet(IqStanza iqStanza) {
    return (iqStanza.type == IqStanzaType.SET);
  }

  void _fireOnRosterListChanged() {
    var rosterList = _rosterMap.values.toList();
    _rosterController.add(rosterList);
  }

  void _handleFullRosterResponse(IqStanza stanza) {
    var xmppElement = stanza.getChild('query');
    if (xmppElement != null && xmppElement.getNameSpace() == 'jabber:iq:roster') {
      _rosterVersion = xmppElement.getAttribute('ver')?.value;
      _rosterMap.clear();
      xmppElement.children.forEach((child) {
        if (child.name == 'item') {
          var jid = Jid.fromFullJid(child.getAttribute('jid')!.value!);
          var name = child.getAttribute('name')?.value;
          var subscriptionString = child.getAttribute('subscription')?.value;
          var buddy = Buddy(jid);
          buddy.name = name;
          var groups = <String>[];
          child.children
              .where((element) => element.name == 'group')
              .forEach((groupElement) {
            var groupName = groupElement.textValue?.trim();
            if (groupName != null && groupName.isNotEmpty) {
              groups.add(groupName);
            }
          });
          buddy.groups = groups;
          buddy.accountJid = _connection.fullJid;
          buddy.subscriptionType = Buddy.typeFromString(subscriptionString);
          _rosterMap[jid] = buddy;
        }
      });
      _fireOnRosterListChanged();
    }
  }

  void _applyRosterPush(IqStanza stanza) {
    final query = stanza.getChild('query');
    if (query == null || query.getNameSpace() != 'jabber:iq:roster') {
      return;
    }
    _rosterVersion = query.getAttribute('ver')?.value ?? _rosterVersion;
    var updated = false;
    for (final child in query.children) {
      if (child.name != 'item') {
        continue;
      }
      final jidAttr = child.getAttribute('jid')?.value;
      if (jidAttr == null || jidAttr.isEmpty) {
        continue;
      }
      final jid = Jid.fromFullJid(jidAttr);
      final subscription = child.getAttribute('subscription')?.value;
      if (subscription == 'remove') {
        if (_rosterMap.remove(jid) != null) {
          updated = true;
        }
        continue;
      }
      final buddy = _rosterMap[jid] ?? Buddy(jid);
      buddy.name = child.getAttribute('name')?.value;
      final groups = <String>[];
      child.children
          .where((element) => element.name == 'group')
          .forEach((groupElement) {
        final groupName = groupElement.textValue?.trim();
        if (groupName != null && groupName.isNotEmpty) {
          groups.add(groupName);
        }
      });
      buddy.groups = groups;
      buddy.accountJid = _connection.fullJid;
      buddy.subscriptionType = Buddy.typeFromString(subscription);
      _rosterMap[jid] = buddy;
      updated = true;
    }
    if (updated) {
      _fireOnRosterListChanged();
    }
  }

  IqStanza _buildRosterPushResult(IqStanza stanza) {
    var iqStanza = IqStanza(stanza.id, IqStanzaType.RESULT);
    iqStanza.fromJid = _connection.fullJid;
    if (stanza.fromJid != null) {
      iqStanza.toJid = stanza.fromJid;
    }
    return iqStanza;
  }

  void _handleRosterSetSuccessResponse(Tuple2<IqStanza, Completer?> request) {
    request.item2!.complete(IqStanzaResult()..type = IqStanzaType.SET);
    _myUnrespondedIqStanzas.remove(request.item1.id);
  }

  //todo add error description
  void _handleRosterSetErrorResponse(Tuple2<IqStanza, Completer?> request) {
    request.item2!.complete(IqStanzaResult()
      ..type = IqStanzaType.ERROR
      ..description = '');
    _myUnrespondedIqStanzas.remove(request.item1.id);
  }
}
