import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/utils/display_layout.dart';

void main() {
  test('physically short high-resolution landscape uses phone layout', () {
    expect(
      usesLandscapePhoneLayout(
        logicalWidth: 1280,
        logicalHeight: 800,
        physicalHeightInches: 4.0,
      ),
      isTrue,
    );
  });

  test('physically tall landscape keeps desktop layout', () {
    expect(
      usesLandscapePhoneLayout(
        logicalWidth: 1280,
        logicalHeight: 800,
        physicalHeightInches: 7.0,
      ),
      isFalse,
    );
  });

  test('logical height remains the fallback without physical metrics', () {
    expect(
      usesLandscapePhoneLayout(logicalWidth: 915, logicalHeight: 412),
      isTrue,
    );
  });

  test('logical phone height wins over stale portrait physical height', () {
    expect(
      usesLandscapePhoneLayout(
        logicalWidth: 915,
        logicalHeight: 412,
        physicalHeightInches: 6.0,
      ),
      isTrue,
    );
  });

  test('small tablet keeps the regular composer when keyboard opens', () {
    expect(
      usesFullscreenLandscapeComposer(
        logicalWidth: 1280,
        logicalHeight: 800,
        physicalHeightInches: 4.0,
      ),
      isFalse,
    );
  });

  test('physical phone height uses the full-screen composer', () {
    expect(
      usesFullscreenLandscapeComposer(
        logicalWidth: 915,
        logicalHeight: 412,
        physicalHeightInches: 2.8,
      ),
      isTrue,
    );
  });

  test('logical phone height keeps composer compact after rotation', () {
    expect(
      usesFullscreenLandscapeComposer(
        logicalWidth: 915,
        logicalHeight: 412,
        physicalHeightInches: 6.0,
      ),
      isTrue,
    );
  });
}
