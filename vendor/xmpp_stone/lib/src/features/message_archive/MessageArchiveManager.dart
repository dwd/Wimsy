import 'package:xmpp_stone/src/elements/forms/QueryElement.dart';
import 'package:xmpp_stone/src/elements/forms/XElement.dart';
import 'package:xmpp_stone/src/features/servicediscovery/MAMNegotiator.dart';
import '../../Connection.dart';
import '../../data/Jid.dart';
import '../../elements/stanzas/AbstractStanza.dart';
import '../../elements/stanzas/IqStanza.dart';
import '../../elements/forms/FieldElement.dart';
import '../../elements/XmppAttribute.dart';
import '../../elements/XmppElement.dart';

class MessageArchiveManager {
  static const TAG = 'MessageArchiveManager';

  static final Map<Connection, MessageArchiveManager> _instances = {};

  static MessageArchiveManager getInstance(Connection connection) {
    var instance = _instances[connection];
    if (instance == null) {
      instance = MessageArchiveManager(connection);
      _instances[connection] = instance;
    }
    return instance;
  }

  final Connection _connection;

  bool get enabled => MAMNegotiator.getInstance(_connection).enabled;

  bool? get hasExtended => MAMNegotiator.getInstance(_connection).hasExtended;

  bool get isQueryByDateSupported => MAMNegotiator.getInstance(_connection).isQueryByDateSupported;

  bool get isQueryByIdSupported => MAMNegotiator.getInstance(_connection).isQueryByIdSupported;

  bool get isQueryByJidSupported => MAMNegotiator.getInstance(_connection).isQueryByJidSupported;

  MessageArchiveManager(this._connection);

  void queryAll({int? max, String? before, String? after, Jid? toJid}) {
    var iqStanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.SET);
    if (toJid != null) {
      iqStanza.toJid = toJid;
    }
    var query = QueryElement();
    query.setXmlns('urn:xmpp:mam:2');
    query.setQueryId(AbstractStanza.getRandomId());
    _addRsm(query, max: max, before: before, after: after);
    iqStanza.addChild(query);
    _connection.writeStanza(iqStanza);
  }

  void queryByTime({
    DateTime? start,
    DateTime? end,
    Jid? jid,
    int? max,
    String? before,
    String? after,
    Jid? toJid,
  }) {
    if (start == null && end == null && jid == null) {
      queryAll(max: max, before: before, after: after, toJid: toJid);
    } else {
      var iqStanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.SET);
      if (toJid != null) {
        iqStanza.toJid = toJid;
      }
      var query = QueryElement();
      query.setXmlns('urn:xmpp:mam:2');
      query.setQueryId(AbstractStanza.getRandomId());
      iqStanza.addChild(query);
      var x = XElement.build();
      x.setType(FormType.SUBMIT);
      query.addChild(x);
      x.addField(FieldElement.build(
          varAttr: 'FORM_TYPE', typeAttr: 'hidden', value: 'urn:xmpp:mam:2'));
      if (start != null) {
        final iso8601 = start.toUtc().toIso8601String();
        final startStr = iso8601.substring(0, iso8601.length - 4) + 'Z';
        x.addField(FieldElement.build(varAttr: 'start', value: startStr));
      }
      if (end != null) {
        final iso8601 = end.toUtc().toIso8601String();
        final endStr = iso8601.substring(0, iso8601.length - 4) + 'Z';
        x.addField(FieldElement.build(varAttr: 'end', value: endStr));
      }
      if (jid != null) {
        x.addField(FieldElement.build(varAttr: 'with', value: jid.userAtDomain));
      }
      _addRsm(query, max: max, before: before, after: after);
      _connection.writeStanza(iqStanza);
    }
  }

  void queryById({
    String? beforeId,
    String? afterId,
    Jid? jid,
    int? max,
    String? before,
    String? after,
    Jid? toJid,
  }) {
    if (beforeId == null && afterId == null && jid == null) {
      queryAll(max: max, before: before, after: after, toJid: toJid);
    } else {
      var iqStanza = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.SET);
      if (toJid != null) {
        iqStanza.toJid = toJid;
      }
      var query = QueryElement();
      query.setXmlns('urn:xmpp:mam:2');
      query.setQueryId(AbstractStanza.getRandomId());
      iqStanza.addChild(query);
      var x = XElement.build();
      x.setType(FormType.SUBMIT);
      query.addChild(x);
      x.addField(FieldElement.build(
          varAttr: 'FORM_TYPE', typeAttr: 'hidden', value: 'urn:xmpp:mam:2'));
      if (beforeId != null) {
        x.addField(FieldElement.build(varAttr: 'beforeId', value: beforeId));
      }
      if (afterId != null) {
        x.addField(FieldElement.build(varAttr: 'afterId', value: afterId));
      }
      if (jid != null) {
        x.addField(FieldElement.build(varAttr: 'with', value: jid.userAtDomain));
      }
      _addRsm(query, max: max, before: before, after: after);
      _connection.writeStanza(iqStanza);
    }
  }

  void _addRsm(QueryElement query, {int? max, String? before, String? after}) {
    if (max == null && before == null && after == null) {
      return;
    }
    var set = XmppElement();
    set.name = 'set';
    set.addAttribute(XmppAttribute('xmlns', 'http://jabber.org/protocol/rsm'));
    if (max != null) {
      var maxElement = XmppElement();
      maxElement.name = 'max';
      maxElement.textValue = max.toString();
      set.addChild(maxElement);
    }
    if (before != null) {
      var beforeElement = XmppElement();
      beforeElement.name = 'before';
      beforeElement.textValue = before;
      set.addChild(beforeElement);
    }
    if (after != null) {
      var afterElement = XmppElement();
      afterElement.name = 'after';
      afterElement.textValue = after;
      set.addChild(afterElement);
    }
    query.addChild(set);
  }
}

//method for getting module
extension MamModuleGetter on Connection {
  MessageArchiveManager getMamModule() {
    return MessageArchiveManager.getInstance(this);
  }
}
