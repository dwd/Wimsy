import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

abstract class MediaStreamHandle {
  String get id;
  Future<void> dispose();
}

typedef MediaStreamFactory = Future<MediaStreamHandle> Function({
  required bool audio,
  required bool video,
  String? audioDeviceId,
  String? videoDeviceId,
});

class WebRtcMediaStreamHandle implements MediaStreamHandle {
  WebRtcMediaStreamHandle(this._stream);

  final MediaStream _stream;

  MediaStream get stream => _stream;

  @override
  String get id => _stream.id;

  @override
  Future<void> dispose() async {
    await _stream.dispose();
  }
}

class WebRtcMediaSession {
  WebRtcMediaSession({MediaStreamFactory? createStream})
      : _createStream = createStream ?? _defaultCreateStream;

  final MediaStreamFactory _createStream;
  MediaStreamHandle? _activeStream;

  MediaStreamHandle? get activeStream => _activeStream;
  bool get isActive => _activeStream != null;

  Future<MediaStreamHandle> start({
    required bool audio,
    required bool video,
    String? audioDeviceId,
    String? videoDeviceId,
  }) async {
    if (_activeStream != null) {
      return _activeStream!;
    }
    final stream = await _createStream(
      audio: audio,
      video: video,
      audioDeviceId: audioDeviceId,
      videoDeviceId: videoDeviceId,
    );
    _activeStream = stream;
    return stream;
  }

  Future<void> stop() async {
    final stream = _activeStream;
    if (stream == null) {
      return;
    }
    _activeStream = null;
    await stream.dispose();
  }

  static Future<MediaStreamHandle> _defaultCreateStream({
    required bool audio,
    required bool video,
    String? audioDeviceId,
    String? videoDeviceId,
  }) async {
    await _ensurePermissions(audio: audio, video: video);
    final audioConstraints = audio
        ? _buildDeviceConstraint(audioDeviceId)
        : false;
    final videoConstraints = video
        ? _buildDeviceConstraint(videoDeviceId)
        : false;
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': audioConstraints,
      'video': videoConstraints,
    });
    return WebRtcMediaStreamHandle(stream);
  }

  static Future<void> _ensurePermissions({
    required bool audio,
    required bool video,
  }) async {
    if (kIsWeb) {
      return;
    }
    final platform = defaultTargetPlatform;
    final supportsPermissions = platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS ||
        platform == TargetPlatform.macOS;
    if (!supportsPermissions) {
      return;
    }
    final permissions = <Permission>[];
    if (audio) {
      permissions.add(Permission.microphone);
    }
    if (video) {
      permissions.add(Permission.camera);
    }
    if (permissions.isEmpty) {
      return;
    }
    final statuses = await permissions.request();
    final denied = statuses.values.any((status) => !status.isGranted);
    if (denied) {
      throw StateError('Media permissions denied');
    }
  }

  static dynamic _buildDeviceConstraint(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) {
      return true;
    }
    return {
      'deviceId': deviceId,
    };
  }
}
