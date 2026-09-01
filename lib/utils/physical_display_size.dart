import 'package:flutter/services.dart';

const MethodChannel _displayMetricsChannel = MethodChannel(
  'wimsy/display_metrics',
);

/// Returns the display's physical short edge in inches when the platform can
/// report its physical pixel density.
///
/// The short edge is the vertical edge in landscape and remains stable across
/// rotation. Call again after display metrics change to account for foldable
/// posture changes and switching between displays.
Future<double?> loadPhysicalDisplayHeightInches() async {
  try {
    return await _displayMetricsChannel.invokeMethod<double>(
      'getPhysicalHeightInches',
    );
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
