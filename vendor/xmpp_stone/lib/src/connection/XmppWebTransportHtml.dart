// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:universal_io/io.dart';
import 'package:web/web.dart' as web;
import 'XmppWebsocketApi.dart';

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

  web.WebTransport? _transport;
  web.WebTransportBidirectionalStream? _bidiStream;
  late String Function(String event) _map;

  // Controller that bridges the ReadableStream chunks to a Dart Stream<String>.
  final StreamController<String> _controller = StreamController<String>();

  XmppWebTransportHtml();

  /// Returns true if the current browser environment supports WebTransport.
  static bool isSupported() {
    return web.window.has('WebTransport');
  }

  @override
  Future<XmppWebSocket> connect<S>(
    String host,
    int port, {
    String Function(String event)? map,
    List<String>? wsProtocols,
    String? wsPath,
    Uri? wsUri,
    bool useWebSocket = true,
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

    final transport = web.WebTransport(url);
    _transport = transport;

    // Wait for the connection to be ready.
    await transport.ready.toDart;

    // Open a single bidirectional stream for the XMPP session.
    final bidiStream =
        await transport.createBidirectionalStream().toDart;
    _bidiStream = bidiStream;

    // Start pumping incoming bytes from the readable side into _controller.
    _pumpIncoming(bidiStream.readable);

    return this;
  }

  /// Reads chunks from the WebTransport readable stream and emits decoded
  /// UTF-8 strings into [_controller].
  void _pumpIncoming(web.ReadableStream readable) {
    final reader = readable.getReader() as web.ReadableStreamDefaultReader;
    Future<void> readNext() async {
      while (true) {
        final result = await reader.read().toDart;
        if (result.done) {
          if (!_controller.isClosed) {
            await _controller.close();
          }
          return;
        }
        final value = result.value;
        String chunk;
        if (value is Uint8List) {
          chunk = String.fromCharCodes(value);
        } else if (value.dartify() case final Uint8List bytes) {
          chunk = String.fromCharCodes(bytes);
        } else {
          chunk = value.toString();
        }
        if (!_controller.isClosed) {
          _controller.add(_map(chunk));
        }
      }
    }

    readNext().catchError((Object error) {
      if (!_controller.isClosed) {
        _controller.addError(error);
        _controller.close();
      }
    });
  }

  @override
  void write(Object? message) {
    if (_bidiStream == null) return;
    final writer = _bidiStream!.writable.getWriter();
    final List<int> bytes;
    if (message is String) {
      bytes = message.codeUnits;
    } else if (message is List<int>) {
      bytes = message;
    } else {
      bytes = message.toString().codeUnits;
    }
    final jsBytes = Uint8List.fromList(bytes).toJS;
    writer.write(jsBytes).toDart.then((_) => writer.releaseLock());
  }

  @override
  void close() {
    _transport?.close();
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
