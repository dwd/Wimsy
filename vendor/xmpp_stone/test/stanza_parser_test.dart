import 'package:test/test.dart';
import 'package:xml/xml.dart' as xml;
import 'package:xmpp_stone/src/parser/StanzaParser.dart';

/// Wraps [inner] in a dummy root element, since [StanzaParser.parseElement]
/// looks up `xmlElement.parent as xml.XmlElement?`, which throws if the
/// parsed element's parent is an [xml.XmlDocument] (i.e. it is itself the
/// document root) rather than simply treating it as having no parent.
xml.XmlElement _wrapped(String inner) {
  final doc = xml.XmlDocument.parse('<root>$inner</root>');
  return doc.rootElement.childElements.first;
}

void main() {
  group('StanzaParser xml:lang handling', () {
    test('parseElement preserves the xml: prefix on xml:lang attributes', () {
      final element = StanzaParser.parseElement(_wrapped(
        '<markingData xml:lang="fr">SANS CLASSIFICATION</markingData>',
      ));

      // The attribute must round-trip as "xml:lang", not be collapsed into
      // a plain "lang" attribute - otherwise it becomes indistinguishable
      // from an attribute with no language specified at all, which is the
      // bug this test guards against.
      expect(element.getAttribute('xml:lang')?.value, 'fr');
      expect(element.getAttribute('lang'), isNull);
    });

    test('parseElement does not add an xml: prefix to a plain lang attribute',
        () {
      final element = StanzaParser.parseElement(_wrapped(
        '<markingData lang="fr">Not actually xml:lang</markingData>',
      ));

      // A genuinely unprefixed "lang" attribute must stay unprefixed, so
      // the two remain distinguishable from each other.
      expect(element.getAttribute('lang')?.value, 'fr');
      expect(element.getAttribute('xml:lang'), isNull);
    });

    test('reserialized xml:lang survives a second parse round-trip', () {
      final element = StanzaParser.parseElement(_wrapped(
        '<markingData xml:lang="fr">SANS CLASSIFICATION</markingData>',
      ));

      final reparsed =
          StanzaParser.parseElement(_wrapped(element.buildXmlString()));

      expect(reparsed.getAttribute('xml:lang')?.value, 'fr');
      expect(reparsed.getAttribute('lang'), isNull);
    });

    test('parseStanza preserves xml:lang on the stanza element itself', () {
      final xmlDoc = xml.XmlDocument.parse(
        '<message xml:lang="fr" type="chat"/>',
      );
      final stanza = StanzaParser.parseStanza(xmlDoc.rootElement);

      expect(stanza!.getAttribute('xml:lang')?.value, 'fr');
      expect(stanza.getAttribute('lang'), isNull);
    });
  });
}
