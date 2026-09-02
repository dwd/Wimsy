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

  test('call video tiles are square and width-limited in portrait', () {
    expect(callVideoTileExtent(availableWidth: 328, screenHeight: 800), 160);
  });

  test('call video tiles stay compact on short landscape phones', () {
    expect(callVideoTileExtent(availableWidth: 700, screenHeight: 412), 96);
  });

  test('call video stage uses available desktop height', () {
    expect(
      callVideoStageHeight(availableWidth: 1000, screenHeight: 900),
      closeTo(495, 0.001),
    );
  });

  test('call video stage leaves room on landscape phones', () {
    expect(callVideoStageHeight(availableWidth: 700, screenHeight: 400), 168);
  });

  test('call video stage follows the rendered video aspect ratio', () {
    expect(
      callVideoStageHeight(
        availableWidth: 640,
        screenHeight: 900,
        videoAspectRatio: 16 / 9,
      ),
      360,
    );
  });

  test('landscape phones use the full screen for video calls', () {
    expect(
      usesFullscreenLandscapeCall(isLandscapePhone: true, hasVideoCall: true),
      isTrue,
    );
    expect(
      usesFullscreenLandscapeCall(isLandscapePhone: true, hasVideoCall: false),
      isFalse,
    );
  });
}
