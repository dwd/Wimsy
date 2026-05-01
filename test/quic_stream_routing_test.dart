import 'package:flutter_quic/flutter_quic.dart' show connectionAcceptBi;
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/quic_xmpp_socket.dart';

void main() {
  group('extractToBareJidForRouting', () {
    test('extracts bare jid from full jid in to attribute', () {
      const stanza = '<message to="room@example.com/nick" id="m1"/>';
      expect(extractToBareJidForRouting(stanza), 'room@example.com');
    });

    test('returns null when no to attribute exists', () {
      const stanza = '<a xmlns="urn:xmpp:sm:3" h="10"/>';
      expect(extractToBareJidForRouting(stanza), isNull);
    });

    test('supports single-quoted to attribute', () {
      const stanza = "<presence to='romeo@example.net/resource'/>";
      expect(extractToBareJidForRouting(stanza), 'romeo@example.net');
    });
  });

  group('bareJidForRouting', () {
    test('strips resource', () {
      expect(
        bareJidForRouting('juliet@example.com/balcony'),
        'juliet@example.com',
      );
    });

    test('keeps bare jid unchanged', () {
      expect(
        bareJidForRouting('room@conference.example.org'),
        'room@conference.example.org',
      );
    });
  });

  group('isStanzaPayload', () {
    test('recognises message stanza', () {
      expect(isStanzaPayload('<message to="x@y"/>'), isTrue);
    });

    test('recognises presence stanza', () {
      expect(isStanzaPayload('<presence/>'), isTrue);
    });

    test('recognises iq stanza', () {
      expect(isStanzaPayload('<iq id="1" type="get"/>'), isTrue);
    });

    test('skips XML prolog before stanza', () {
      expect(
        isStanzaPayload("<?xml version='1.0'?><iq id='1' type='get'/>"),
        isTrue,
      );
    });

    test('rejects stream:stream opener', () {
      expect(
        isStanzaPayload(
          "<?xml version='1.0'?><stream:stream xmlns='jabber:client'/>",
        ),
        isFalse,
      );
    });

    test('rejects XEP-0198 r/a even if they ever carry a to attribute', () {
      expect(isStanzaPayload('<r xmlns="urn:xmpp:sm:3" to="x@y"/>'), isFalse);
      expect(isStanzaPayload('<a xmlns="urn:xmpp:sm:3" h="1"/>'), isFalse);
    });

    test('rejects CSI elements', () {
      expect(isStanzaPayload('<active xmlns="urn:xmpp:csi:0"/>'), isFalse);
      expect(isStanzaPayload('<inactive xmlns="urn:xmpp:csi:0"/>'), isFalse);
    });

    test('rejects SASL frames', () {
      expect(
        isStanzaPayload('<auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl"/>'),
        isFalse,
      );
    });

    test('rejects empty payload', () {
      expect(isStanzaPayload(''), isFalse);
      expect(isStanzaPayload('   '), isFalse);
    });
  });

  group('quicAuxSlotForBareJid', () {
    test('is deterministic for the same jid', () {
      final first = quicAuxSlotForBareJid('room@example.com', 20);
      final second = quicAuxSlotForBareJid('room@example.com', 20);
      expect(first, second);
    });

    test('stays within bounds', () {
      final slot = quicAuxSlotForBareJid('contact@example.com', 20);
      expect(slot, inInclusiveRange(0, 19));
    });
  });

  group('connectionAcceptBi bridge export', () {
    // connectionAcceptBi requires a live QUIC connection and cannot be called
    // in a unit test. These tests verify that the symbol is exported from the
    // flutter_quic bridge with the expected type so that compile-time regressions
    // are caught immediately.
    //
    // The function now takes a shared reference (&QuicConnection) so it does
    // NOT consume the arc and can run concurrently with connectionOpenBi.
    test('connectionAcceptBi is a Function', () {
      // If the codegen did not produce the symbol this line would not compile.
      expect(connectionAcceptBi, isA<Function>());
    });
  });
}
