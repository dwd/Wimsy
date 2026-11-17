import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/utils/xep0392_color.dart';

void main() {
  test('xep0392ColorForLabel returns deterministic color', () {
    final first = xep0392ColorForLabel('Alice');
    final second = xep0392ColorForLabel('Alice');
    expect(first.toARGB32(), second.toARGB32());
  });

  test('xep0392ColorForLabel returns default for empty label', () {
    final color = xep0392ColorForLabel('  ');
    expect(color, const Color(0xFF9E9E9E));
  });
}
