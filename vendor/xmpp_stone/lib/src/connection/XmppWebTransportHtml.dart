// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:universal_io/io.dart';
import 'package:web/web.dart' as web;
import 'package:xmpp_stone/src/logger/Log.dart';
import 'XmppWebsocketApi.dart';

typedef WebTransportStreamFactory = Future<WebTransportStreams> Function(
  String url,
);

/// Browser stream handles used by the WebTransport adapter.
///
/// Exposed separately from [web.WebTransport] so browser tests can exercise
/// the same byte-stream code without opening an external network connection.
class WebTransportStreams {
  WebTransportStreams({
    required this.readable,
    required this.writable,
    required this.close,
  });

  final web.ReadableStream readable;
  final web.WritableStream writable;
  final void Function() close;
}

/// WebTransport-based XMPP socket for the web platform.
///
/// Opens a single reliable bidirectional stream over WebTransport (HTTP/3 /
/// QUIC) and uses it to carry the full XMPP XML stream, matching Phase 1 of
/// the WebTransport plan (one channel first).
///
/// If the browser does not support WebTransport, or if the connection attempt
/// fails, this class throws so the caller can fall back to WebSocket.
class XmppWebTransportHtml extends XmppWebSocket {
  static const String TAG = 'XmppWebTransportHtml';

  web.WritableStream? _writable;
  late String Function(String event) _map;
  final WebTransportStreamFactory? _streamFactory;
  void Function()? _closeStream;
  Future<void> _writeQueue = Future<void>.value();

  // Controller that bridges the ReadableStream chunks to a Dart Stream<String>.
  final StreamController<String> _controller = StreamController<String>();

  XmppWebTransportHtml({WebTransportStreamFactory? streamFactory})
      : _streamFactory = streamFactory;

  /// Returns true if the current browser environment supports WebTransport.
  static bool isSupported() {
    // Use globalContext from dart:js_interop_unsafe to check for WebTransport.
    return globalContext.hasProperty('WebTransport'.toJS).toDart;
  }

  @override
  Future<XmppWebSocket> connect<S>(
    String host,
    int port, {
    String Function(String event)? map,
    String? wsPath,
    Uri? wsUri,
    bool useWebSocket = false,
    bool useWebTransport = false,
    bool useQuic = false,
    bool directTls = false,
    String? tlsHost,
  }) async {
    _map = map ?? (e) => e;

    // Derive the WebTransport URL from wsUri or construct from host/port/path.
    // WebTransport uses https:// (not wss://).
    final Uri rawUri = wsUri ??
        Uri(
          scheme: 'https',
          host: host,
          port: port,
          path: wsPath,
        );

    // Rewrite wss:// → https:// if the caller passed a WebSocket-style URI.
    final String url = rawUri.scheme == 'wss'
        ? rawUri.replace(scheme: 'https').toString()
        : rawUri.toString();

    final streamFactory = _streamFactory;
    late web.ReadableStream readable;
    if (streamFactory != null) {
      Log.d(TAG, 'Creating injected WebTransport streams url=$url');
      final streams = await streamFactory(url);
      readable = streams.readable;
      _writable = streams.writable;
      _closeStream = streams.close;
    } else {
      Log.i(TAG, 'Creating WebTransport session url=$url');
      final transport = web.WebTransport(url);
      unawaited(
        transport.closed.toDart.then(
          (info) => Log.i(
            TAG,
            'WebTransport session closed code=${info.closeCode} '
            'reason=${info.reason.isEmpty ? '(none)' : info.reason}',
          ),
          onError: (Object error, StackTrace stackTrace) {
            Log.e(TAG, 'WebTransport session failed: $error');
          },
        ),
      );

      // Wait for the connection to be ready.
      Log.d(TAG, 'Waiting for WebTransport session readiness');
      try {
        await transport.ready.toDart;
      } catch (error) {
        Log.e(TAG, 'WebTransport readiness failed: $error');
        rethrow;
      }
      Log.i(TAG, 'WebTransport session ready');

      // Open a single bidirectional stream for the XMPP session.
      Log.d(TAG, 'Opening WebTransport bidirectional XMPP stream');
      late web.WebTransportBidirectionalStream bidiStream;
      try {
        bidiStream = await transport.createBidirectionalStream().toDart;
      } catch (error) {
        Log.e(TAG, 'WebTransport bidirectional stream failed: $error');
        rethrow;
      }
      Log.i(TAG, 'WebTransport bidirectional XMPP stream opened');
      readable = bidiStream.readable as web.ReadableStream;
      _writable = bidiStream.writable as web.WritableStream;
      _closeStream = () => transport.close();
    }

    // Start pumping incoming bytes from the readable side into _controller.
    // readable is typed as JSObject in the web package; cast to ReadableStream.
    _pumpIncoming(readable);

    return this;
  }

  /// Reads chunks from the WebTransport readable stream and emits decoded
  /// UTF-8 strings into [_controller].
  void _pumpIncoming(web.ReadableStream readable) {
    final reader = web.ReadableStreamDefaultReader(readable);
    final decoder = web.TextDecoder();
    Future<void> readNext() async {
      while (true) {
        final result = await reader.read().toDart;
        if (result.done) {
          Log.i(TAG, 'WebTransport XMPP receive stream ended');
          final trailing = decoder.decode();
          if (trailing.isNotEmpty && !_controller.isClosed) {
            _controller.add(_map(trailing));
          }
          if (!_controller.isClosed) {
            await _controller.close();
          }
          return;
        }
        final value = result.value;
        final dartValue = value?.dartify();
        final bytes = dartValue is Uint8List
            ? dartValue
            : Uint8List.fromList((dartValue as List).cast<int>());
        final chunk = decoder.decode(
          bytes.toJS,
          web.TextDecodeOptions(stream: true),
        );
        if (!_controller.isClosed) {
          Log.d(
            TAG,
            'WebTransport received bytes=${bytes.length} '
            'decodedCharacters=${chunk.length}',
          );
          if (chunk.isNotEmpty) {
            Log.xmppp_receiving(chunk, channel: 'webtransport');
          }
          _controller.add(_map(chunk));
        }
      }
    }

    readNext().catchError((Object error) {
      Log.e(TAG, 'WebTransport receive failed: $error');
      if (!_controller.isClosed) {
        _controller.addError(error);
        _controller.close();
      }
    });
  }

  @override
  void write(Object? message) {
    final writable = _writable;
    if (writable == null) return;
    final bytes =
        message is List<int> ? message : utf8.encode(message?.toString() ?? '');
    final payload = message?.toString() ?? '';
    Log.d(TAG, 'WebTransport write queued bytes=${bytes.length}');
    _writeQueue = _writeQueue.then((_) async {
      final writer = writable.getWriter();
      try {
        if (payload.isNotEmpty) {
          Log.xmppp_sending(payload, channel: 'webtransport');
        }
        await writer.write(Uint8List.fromList(bytes).toJS).toDart;
        Log.d(TAG, 'WebTransport write completed bytes=${bytes.length}');
      } finally {
        writer.releaseLock();
      }
    }).catchError((Object error, StackTrace stackTrace) {
      Log.e(TAG, 'WebTransport write failed: $error');
      if (!_controller.isClosed) {
        _controller.addError(error, stackTrace);
      }
    });
  }

  @override
  void close() {
    Log.i(TAG, 'Closing WebTransport session');
    _closeStream?.call();
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  @override
  StreamSubscription<String> listen(
    void Function(String event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future<SecureSocket?> secure({
    host,
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    List<String>? supportedProtocols,
  }) {
    // WebTransport is always encrypted (QUIC/TLS 1.3).
    return Future.value(null);
  }

  @override
  String getStreamOpeningElement(String domain) {
    return "<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' to='$domain' version='1.0'/>";
  }

  /// True for callers that need to distinguish WebTransport from WebSocket.
  bool get isWebTransport => true;
}
