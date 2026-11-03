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
      createStream:
          ({
            required bool audio,
            required bool video,
            String? audioDeviceId,
            String? videoDeviceId,
          }) async {
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
      createStream:
          ({
            required bool audio,
            required bool video,
            String? audioDeviceId,
            String? videoDeviceId,
          }) async => handle,
    );

    await session.start(audio: true, video: false);
    await session.stop();

    expect(handle.disposed, isTrue);
    expect(session.isActive, isFalse);
    expect(session.activeStream, isNull);
  });

  test('additional stream does not replace the active stream', () async {
    var createCount = 0;
    final session = WebRtcMediaSession(
      createStream:
          ({
            required bool audio,
            required bool video,
            String? audioDeviceId,
            String? videoDeviceId,
          }) async => _FakeStreamHandle('stream-${++createCount}'),
    );

    final active = await session.start(audio: true, video: true);
    final additional = await session.createAdditionalStream(
      audio: false,
      video: true,
      videoDeviceId: 'rear-camera',
    );

    expect(active.id, 'stream-1');
    expect(additional.id, 'stream-2');
    expect(identical(session.activeStream, active), isTrue);
  });

  test('warmUp opens and immediately disposes a stream once', () async {
    var createCount = 0;
    final handles = <_FakeStreamHandle>[];
    final session = WebRtcMediaSession(
      createStream:
          ({
            required bool audio,
            required bool video,
            String? audioDeviceId,
            String? videoDeviceId,
          }) async {
            createCount += 1;
            final handle = _FakeStreamHandle('stream-$createCount');
            handles.add(handle);
            return handle;
          },
    );

    await session.warmUp(audio: true, video: true);

    expect(createCount, 1);
    expect(handles.single.disposed, isTrue);
    expect(session.isActive, isFalse);
    expect(session.activeStream, isNull);
  });

  test('warmUp only runs once per session', () async {
    var createCount = 0;
    final session = WebRtcMediaSession(
      createStream:
          ({
            required bool audio,
            required bool video,
            String? audioDeviceId,
            String? videoDeviceId,
          }) async {
            createCount += 1;
            return _FakeStreamHandle('stream-$createCount');
          },
    );

    await session.warmUp(audio: true, video: true);
    await session.warmUp(audio: true, video: true);

    expect(createCount, 1);
  });

  test('warmUp is a no-op while a real stream is already active', () async {
    var createCount = 0;
    final session = WebRtcMediaSession(
      createStream:
          ({
            required bool audio,
            required bool video,
            String? audioDeviceId,
            String? videoDeviceId,
          }) async {
            createCount += 1;
            return _FakeStreamHandle('stream-$createCount');
          },
    );

    await session.start(audio: true, video: true);
    expect(createCount, 1);

    await session.warmUp(audio: true, video: true);

    // warmUp must not touch/replace the active call's stream.
    expect(createCount, 1);
    expect(session.isActive, isTrue);
  });

  test('warmUp swallows errors from a failing capture', () async {
    final session = WebRtcMediaSession(
      createStream:
          ({
            required bool audio,
            required bool video,
            String? audioDeviceId,
            String? videoDeviceId,
          }) async => throw StateError('no camera available'),
    );

    await expectLater(
      session.warmUp(audio: true, video: true),
      completes,
    );
    expect(session.isActive, isFalse);
  });
}
