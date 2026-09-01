import 'package:flutter/services.dart';

const MethodChannel _displayMetricsChannel = MethodChannel(
  'wimsy/display_metrics',
);

/// Returns the current display height in inches when the platform can report
/// its physical pixel density.
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
