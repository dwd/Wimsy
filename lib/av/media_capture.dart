class MediaCaptureCapabilities {
  const MediaCaptureCapabilities({
    required this.hasAudio,
    required this.hasVideo,
    required this.hasCamera,
  });

  final bool hasAudio;
  final bool hasVideo;
  final bool hasCamera;
}

abstract class MediaCaptureService {
  Future<MediaCaptureCapabilities> getCapabilities();
}

class NoopMediaCaptureService implements MediaCaptureService {
  @override
  Future<MediaCaptureCapabilities> getCapabilities() async {
    return const MediaCaptureCapabilities(
      hasAudio: false,
      hasVideo: false,
      hasCamera: false,
    );
  }
}
