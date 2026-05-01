import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

/// Tests for R2.1: unified server-archive MAM catch-up.
///
/// The `_startUnifiedDmCatchUp` method in `xmpp_service.dart` builds a MAM
/// IQ manually and parses the `<fin>` IQ result to advance `_lastMamIdSeen`.
/// These tests verify the parsing logic using xmpp_stone's `XmppElement` API
/// directly, mirroring what the production code does.
void main() {
  group('R2.1: <fin> RSM <last> parsing', () {
    /// Build a fake MAM <fin> IQ result with the given RSM <last> value.
    IqStanza _buildFinResult({String? lastId, bool includeRsm = true}) {
      final iq = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.RESULT);

      final fin = XmppElement()..name = 'fin';
      fin.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:mam:2'));

      if (includeRsm) {
        final set = XmppElement()..name = 'set';
        set.addAttribute(
          XmppAttribute('xmlns', 'http://jabber.org/protocol/rsm'),
        );
        if (lastId != null) {
          final last = XmppElement()
            ..name = 'last'
            ..textValue = lastId;
          set.addChild(last);
        }
        fin.addChild(set);
      }

      iq.addChild(fin);
      return iq;
    }

    /// Replicate the parsing logic from `_startUnifiedDmCatchUp`.
    String? _parseFinLastId(IqStanza response) {
      if (response.type != IqStanzaType.RESULT) {
        return null;
      }
      final fin = response.children.firstWhere(
        (child) =>
            child.name == 'fin' &&
            child.getAttribute('xmlns')?.value == 'urn:xmpp:mam:2',
        orElse: () => XmppElement(),
      );
      if (fin.name != 'fin') {
        return null;
      }
      final rsmSet = fin.children.firstWhere(
        (child) =>
            child.name == 'set' &&
            child.getAttribute('xmlns')?.value ==
                'http://jabber.org/protocol/rsm',
        orElse: () => XmppElement(),
      );
      if (rsmSet.name != 'set') {
        return null;
      }
      final lastEl = rsmSet.children.firstWhere(
        (child) => child.name == 'last',
        orElse: () => XmppElement(),
      );
      final lastId =
          lastEl.name == 'last' ? lastEl.textValue?.trim() : null;
      return (lastId != null && lastId.isNotEmpty) ? lastId : null;
    }

    test('extracts <last> id from a well-formed <fin> result', () {
      final iq = _buildFinResult(lastId: 'mam-id-42');
      expect(_parseFinLastId(iq), equals('mam-id-42'));
    });

    test('returns null when IQ type is not RESULT', () {
      final iq = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.ERROR);
      final fin = XmppElement()..name = 'fin';
      fin.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:mam:2'));
      iq.addChild(fin);
      expect(_parseFinLastId(iq), isNull);
    });

    test('returns null when <fin> element is absent', () {
      final iq = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.RESULT);
      expect(_parseFinLastId(iq), isNull);
    });

    test('returns null when RSM <set> is absent from <fin>', () {
      final iq = _buildFinResult(lastId: 'mam-id-1', includeRsm: false);
      expect(_parseFinLastId(iq), isNull);
    });

    test('returns null when <last> is absent from RSM <set>', () {
      final iq = _buildFinResult(lastId: null);
      expect(_parseFinLastId(iq), isNull);
    });

    test('trims whitespace from <last> text value', () {
      final iq = _buildFinResult(lastId: '  mam-id-trimmed  ');
      expect(_parseFinLastId(iq), equals('mam-id-trimmed'));
    });
  });
}
