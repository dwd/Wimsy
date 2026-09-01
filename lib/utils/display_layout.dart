const double compactLandscapePhysicalHeightInches = 5.0;

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
  return physicalHeightInches != null
      ? physicalHeightInches < compactLandscapePhysicalHeightInches
      : logicalHeight < 600;
}
