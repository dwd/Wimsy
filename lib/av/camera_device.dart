import 'package:flutter_webrtc/flutter_webrtc.dart';

enum CameraFacing { front, back, unknown }

CameraFacing cameraFacing(MediaDeviceInfo device) {
  final description = '${device.label} ${device.deviceId}'.toLowerCase();
  if (RegExp(r'\b(front|user)\b').hasMatch(description)) {
    return CameraFacing.front;
  }
  if (RegExp(r'\b(back|rear|environment)\b').hasMatch(description)) {
    return CameraFacing.back;
  }
  return CameraFacing.unknown;
}

bool defaultCameraPreviewMirrored(MediaDeviceInfo device) =>
    cameraFacing(device) != CameraFacing.back;

/// Returns concise Android camera names while retaining every physical camera
/// exposed by WebRTC. Multiple cameras on the same side are numbered because
/// Android's WebRTC API does not expose lens type or focal-length metadata.
List<String> cameraDeviceLabels(
  List<MediaDeviceInfo> devices, {
  required bool useFacingLabels,
}) {
  final totals = <CameraFacing, int>{};
  for (final device in devices) {
    final facing = cameraFacing(device);
    totals[facing] = (totals[facing] ?? 0) + 1;
  }

  final seen = <CameraFacing, int>{};
  final labels = [
    for (var i = 0; i < devices.length; i++)
      _cameraDeviceLabel(devices[i], i, useFacingLabels, totals, seen),
  ];

  // Some webcams (notably IR-capable ones used for face unlock) expose
  // multiple distinct device nodes/ids that share the exact same plain
  // label, e.g. two "HD Camera" entries. Disambiguate those with a trailing
  // counter so the picker never shows indistinguishable duplicate entries.
  final labelCounts = <String, int>{};
  for (final label in labels) {
    labelCounts[label] = (labelCounts[label] ?? 0) + 1;
  }
  final labelSeen = <String, int>{};
  return [
    for (final label in labels)
      if ((labelCounts[label] ?? 0) > 1)
        '$label (${(labelSeen[label] = (labelSeen[label] ?? 0) + 1)})'
      else
        label,
  ];
}

String _cameraDeviceLabel(
  MediaDeviceInfo device,
  int index,
  bool useFacingLabels,
  Map<CameraFacing, int> totals,
  Map<CameraFacing, int> seen,
) {
  final facing = cameraFacing(device);
  seen[facing] = (seen[facing] ?? 0) + 1;
  if (useFacingLabels && facing != CameraFacing.unknown) {
    final base = facing == CameraFacing.front ? 'Front' : 'Back';
    return (totals[facing] ?? 0) > 1 ? '$base ${seen[facing]}' : base;
  }
  final label = device.label.trim();
  return label.isNotEmpty ? label : 'Camera ${index + 1}';
}
