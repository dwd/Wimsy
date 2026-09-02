import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wimsy/av/camera_device.dart';

void main() {
  MediaDeviceInfo camera(String id, String label) => MediaDeviceInfo(
    deviceId: id,
    label: label,
    kind: 'videoinput',
    groupId: 'camera',
  );

  test('recognizes Android camera facing and mirror defaults', () {
    final front = camera('1', 'Camera 1, Facing front, Orientation 270');
    final back = camera('0', 'Camera 0, Facing back, Orientation 90');

    expect(cameraFacing(front), CameraFacing.front);
    expect(defaultCameraPreviewMirrored(front), isTrue);
    expect(cameraFacing(back), CameraFacing.back);
    expect(defaultCameraPreviewMirrored(back), isFalse);
  });

  test('uses concise numbered labels for multiple cameras on one side', () {
    final labels = cameraDeviceLabels([
      camera('0', 'Camera 0, Facing back, Orientation 90'),
      camera('1', 'Camera 1, Facing front, Orientation 270'),
      camera('2', 'Camera 2, Facing back, Orientation 90'),
    ], useFacingLabels: true);

    expect(labels, ['Back 1', 'Front', 'Back 2']);
  });

  test('retains non-Android labels and supplies a fallback', () {
    final labels = cameraDeviceLabels([
      camera('a', 'USB Camera'),
      camera('b', ''),
    ], useFacingLabels: false);

    expect(labels, ['USB Camera', 'Camera 2']);
  });
}
