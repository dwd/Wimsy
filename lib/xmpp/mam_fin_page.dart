import 'package:xmpp_stone/xmpp_stone.dart';

/// Paging information returned by a MAM `<fin/>` result.
class MamFinPage {
  const MamFinPage({required this.complete, this.lastId});

  final bool complete;
  final String? lastId;

  /// Extracts the RSM cursor and completion flag from a successful MAM IQ.
  ///
  /// Returns `null` for error or malformed responses so callers do not advance
  /// their archive cursor based on an incomplete exchange.
  static MamFinPage? fromIq(IqStanza response) {
    if (response.type != IqStanzaType.RESULT) {
      return null;
    }
    final fin = response.children.cast<XmppElement?>().firstWhere(
      (child) =>
          child?.name == 'fin' &&
          child?.getAttribute('xmlns')?.value == 'urn:xmpp:mam:2',
      orElse: () => null,
    );
    if (fin == null) {
      return null;
    }
    final completeValue = fin.getAttribute('complete')?.value;
    final complete = completeValue == 'true' || completeValue == '1';
    final rsmSet = fin.children.cast<XmppElement?>().firstWhere(
      (child) =>
          child?.name == 'set' &&
          child?.getAttribute('xmlns')?.value ==
              'http://jabber.org/protocol/rsm',
      orElse: () => null,
    );
    final last = rsmSet?.children.cast<XmppElement?>().firstWhere(
      (child) => child?.name == 'last',
      orElse: () => null,
    );
    final lastId = last?.textValue?.trim();
    return MamFinPage(
      complete: complete,
      lastId: lastId == null || lastId.isEmpty ? null : lastId,
    );
  }
}
