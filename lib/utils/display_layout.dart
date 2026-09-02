const double compactLandscapePhysicalHeightInches = 5.0;
const double fullscreenComposerPhysicalHeightInches = 3.5;

double callVideoTileExtent({
  required double availableWidth,
  required double screenHeight,
}) {
  const spacing = 8.0;
  final widthLimited = (availableWidth - spacing) / 2;
  final heightLimit = screenHeight < 500 ? 96.0 : 180.0;
  return widthLimited.clamp(0.0, heightLimit);
}

double callVideoStageHeight({
  required double availableWidth,
  required double screenHeight,
  double? videoAspectRatio,
}) {
  final heightFraction = screenHeight < 500 ? 0.42 : 0.55;
  final maximumHeight = screenHeight * heightFraction;
  final aspectRatio = videoAspectRatio;
  if (aspectRatio != null && aspectRatio > 0) {
    return (availableWidth / aspectRatio).clamp(0.0, maximumHeight);
  }
  return availableWidth.clamp(0.0, maximumHeight);
}

bool usesFullscreenLandscapeCall({
  required bool isLandscapePhone,
  required bool hasVideoCall,
}) => isLandscapePhone && hasVideoCall;

/// Whether a landscape display should use the phone-style, single-pane UI.
///
/// Logical pixels are useful for allocating widgets, but they do not describe
/// how large a high-density display is in the user's hand. On platforms that
/// report physical dimensions, use the display's actual height so small
/// tablets do not accidentally receive the desktop layout.
bool usesLandscapePhoneLayout({
  required double logicalWidth,
  required double logicalHeight,
  double? physicalHeightInches,
}) {
  if (logicalWidth <= logicalHeight) {
    return false;
  }
  return logicalHeight < 600 ||
      (physicalHeightInches != null &&
          physicalHeightInches < compactLandscapePhysicalHeightInches);
}

/// Whether the keyboard should replace the chat with a full-screen composer.
///
/// The larger compact-layout threshold includes small tablets. Those have
/// enough usable height for the normal bottom composer, so reserve the more
/// aggressive full-screen editor for phone-sized displays.
bool usesFullscreenLandscapeComposer({
  required double logicalWidth,
  required double logicalHeight,
  double? physicalHeightInches,
}) {
  if (logicalWidth <= logicalHeight) {
    return false;
  }
  return logicalHeight < 600 ||
      (physicalHeightInches != null &&
          physicalHeightInches < fullscreenComposerPhysicalHeightInches);
}
