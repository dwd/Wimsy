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
}
