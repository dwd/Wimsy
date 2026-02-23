import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/av/media_session.dart';

class _FakeStreamHandle implements MediaStreamHandle {
  _FakeStreamHandle(this.id);

  @override
  final String id;

  bool disposed = false;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  test('WebRtcMediaSession starts once and reuses active stream', () async {
    var createCount = 0;
    final session = WebRtcMediaSession(
      createStream: ({required bool audio, required bool video, String? audioDeviceId, String? videoDeviceId}) async {
        createCount += 1;
        return _FakeStreamHandle('stream-$createCount');
      },
    );

    final first = await session.start(audio: true, video: false);
    final second = await session.start(audio: true, video: true);

    expect(first.id, 'stream-1');
    expect(identical(first, second), isTrue);
    expect(createCount, 1);
    expect(session.isActive, isTrue);
  });

  test('WebRtcMediaSession stops and disposes stream', () async {
    final handle = _FakeStreamHandle('stream-1');
    final session = WebRtcMediaSession(
      createStream: ({required bool audio, required bool video, String? audioDeviceId, String? videoDeviceId}) async => handle,
    );

    await session.start(audio: true, video: false);
    await session.stop();

    expect(handle.disposed, isTrue);
    expect(session.isActive, isFalse);
    expect(session.activeStream, isNull);
  });
}
