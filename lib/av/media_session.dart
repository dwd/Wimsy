import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

abstract class MediaStreamHandle {
  String get id;
  Future<void> dispose();
}

typedef MediaStreamFactory =
    Future<MediaStreamHandle> Function({
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
  bool _warmedUp = false;
  bool _warmingUp = false;

  MediaStreamHandle? get activeStream => _activeStream;
  bool get isActive => _activeStream != null;

  /// Performs a one-time, best-effort "warm-up" of the camera/microphone
  /// capture pipeline by briefly opening and immediately releasing a stream.
  ///
  /// On some platforms (notably Linux/V4L2), the first time a given camera
  /// is opened in a process it has to negotiate supported formats/resolutions
  /// with the driver, which can take several seconds. That cost previously
  /// landed on the critical path of accepting/placing the very first call,
  /// visibly delaying ICE/SDP negotiation. Calling this once, early in the
  /// app session (e.g. right after the XMPP connection is established),
  /// pays that cost up front instead.
  ///
  /// This intentionally releases the camera/mic immediately afterward so it
  /// never holds the device open, avoiding any lasting conflict with other
  /// applications (Slack, a browser, etc.) that may want to use the same
  /// camera between warm-up and the next real call. It is a no-op if a real
  /// call/stream is already active, if it already ran once this session, or
  /// if capture isn't available/permitted yet (e.g. permissions not yet
  /// granted) - in all of those cases it silently does nothing.
  Future<void> warmUp({
    required bool audio,
    required bool video,
    String? audioDeviceId,
    String? videoDeviceId,
  }) async {
    if (_warmedUp || _warmingUp || _activeStream != null) {
      return;
    }
    _warmingUp = true;
    try {
      final stream = await _createStream(
        audio: audio,
        video: video,
        audioDeviceId: audioDeviceId,
        videoDeviceId: videoDeviceId,
      );
      _warmedUp = true;
      await stream.dispose();
    } catch (_) {
      // Best-effort only: a failure here (e.g. missing permissions, no
      // device present) just means the real call will pay the full cost
      // later, exactly as it did before this warm-up existed.
    } finally {
      _warmingUp = false;
    }
  }

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

  /// Captures a stream without replacing the session's primary stream.
  ///
  /// This is used to acquire a new camera track during an active call; the
  /// caller owns and must dispose the returned handle.
  Future<MediaStreamHandle> createAdditionalStream({
    required bool audio,
    required bool video,
    String? audioDeviceId,
    String? videoDeviceId,
  }) => _createStream(
    audio: audio,
    video: video,
    audioDeviceId: audioDeviceId,
    videoDeviceId: videoDeviceId,
  );

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
        ? _buildVideoConstraint(videoDeviceId)
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
    final supportsPermissions =
        platform == TargetPlatform.android ||
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
    return {'deviceId': deviceId};
  }

  static dynamic _buildVideoConstraint(String? deviceId) {
    final constraint = <String, dynamic>{};
    if (deviceId != null && deviceId.isNotEmpty) {
      constraint['deviceId'] = deviceId;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      // Most UVC cameras expose this mode natively. Avoiding an unconstrained
      // high-resolution capture substantially reduces Linux startup time and
      // encoder pressure while retaining a useful call resolution.
      constraint
        ..['width'] = {'ideal': 640}
        ..['height'] = {'ideal': 480}
        ..['frameRate'] = {'ideal': 24, 'max': 30};
    }
    return constraint.isEmpty ? true : constraint;
  }
}
