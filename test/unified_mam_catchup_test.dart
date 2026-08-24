import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart';
import 'package:wimsy/xmpp/mam_fin_page.dart';

/// Tests for R2.1: unified server-archive MAM catch-up.
///
/// The `_startUnifiedDmCatchUp` method in `xmpp_service.dart` builds a MAM
/// IQ manually and parses the `<fin>` IQ result to advance `_lastMamIdSeen`.
/// These tests verify the parsing logic using xmpp_stone's `XmppElement` API
/// directly, mirroring what the production code does.
void main() {
  group('R2.1: <fin> RSM <last> parsing', () {
    /// Build a fake MAM <fin> IQ result with the given RSM <last> value.
    IqStanza buildFinResult({
      String? lastId,
      bool includeRsm = true,
      bool complete = true,
    }) {
      final iq = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.RESULT);

      final fin = XmppElement()..name = 'fin';
      fin.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:mam:2'));
      fin.addAttribute(XmppAttribute('complete', complete ? 'true' : 'false'));

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

    test('extracts <last> id from a well-formed <fin> result', () {
      final iq = buildFinResult(lastId: 'mam-id-42');
      final page = MamFinPage.fromIq(iq);
      expect(page?.lastId, equals('mam-id-42'));
      expect(page?.complete, isTrue);
    });

    test('incomplete result exposes cursor for the next page', () {
      final iq = buildFinResult(lastId: 'mam-id-50', complete: false);
      final page = MamFinPage.fromIq(iq);
      expect(page?.lastId, equals('mam-id-50'));
      expect(page?.complete, isFalse);
    });

    test('returns null when IQ type is not RESULT', () {
      final iq = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.ERROR);
      final fin = XmppElement()..name = 'fin';
      fin.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:mam:2'));
      iq.addChild(fin);
      expect(MamFinPage.fromIq(iq), isNull);
    });

    test('returns null when <fin> element is absent', () {
      final iq = IqStanza(AbstractStanza.getRandomId(), IqStanzaType.RESULT);
      expect(MamFinPage.fromIq(iq), isNull);
    });

    test('returns null when RSM <set> is absent from <fin>', () {
      final iq = buildFinResult(lastId: 'mam-id-1', includeRsm: false);
      final page = MamFinPage.fromIq(iq);
      expect(page, isNotNull);
      expect(page?.lastId, isNull);
    });

    test('returns null when <last> is absent from RSM <set>', () {
      final iq = buildFinResult(lastId: null);
      final page = MamFinPage.fromIq(iq);
      expect(page, isNotNull);
      expect(page?.lastId, isNull);
    });

    test('trims whitespace from <last> text value', () {
      final iq = buildFinResult(lastId: '  mam-id-trimmed  ');
      expect(MamFinPage.fromIq(iq)?.lastId, equals('mam-id-trimmed'));
    });
  });
}
