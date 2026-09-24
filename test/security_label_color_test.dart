import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/main.dart';

void main() {
  group('parseCssColorForSecurityLabel', () {
    test('returns null for null or empty input', () {
      expect(parseCssColorForSecurityLabel(null), isNull);
      expect(parseCssColorForSecurityLabel(''), isNull);
      expect(parseCssColorForSecurityLabel('   '), isNull);
    });

    test('parses common CSS named colours', () {
      expect(parseCssColorForSecurityLabel('red'), const Color(0xFFFF0000));
      expect(parseCssColorForSecurityLabel('black'), const Color(0xFF000000));
      expect(parseCssColorForSecurityLabel('Navy'), const Color(0xFF000080));
      expect(parseCssColorForSecurityLabel('AQUA'), const Color(0xFF00FFFF));
    });

    test('parses 6-digit hex colours', () {
      expect(
        parseCssColorForSecurityLabel('#336699'),
        const Color(0xFF336699),
      );
    });

    test('parses 3-digit shorthand hex colours', () {
      expect(parseCssColorForSecurityLabel('#369'), const Color(0xFF336699));
    });

    test('parses rgb(...) colours', () {
      expect(
        parseCssColorForSecurityLabel('rgb(51, 102, 153)'),
        const Color(0xFF336699),
      );
    });

    test('returns null for unrecognised colour syntax', () {
      expect(parseCssColorForSecurityLabel('not-a-colour'), isNull);
      expect(parseCssColorForSecurityLabel('#zzzzzz'), isNull);
      expect(parseCssColorForSecurityLabel('rgb(1,2)'), isNull);
    });
  });
}
