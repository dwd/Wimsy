// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:universal_io/io.dart';
import 'package:web/web.dart' as web;
import 'package:xmpp_stone/src/connection/XmppStreamRouting.dart';
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
    this.openBidirectionalStream,
    this.incomingBidirectionalStreams,
  });

  final web.ReadableStream readable;
  final web.WritableStream writable;
  final void Function() close;
  final Future<WebTransportStreamChannel> Function()? openBidirectionalStream;
  final web.ReadableStream? incomingBidirectionalStreams;
}

class WebTransportStreamChannel {
  WebTransportStreamChannel({required this.readable, required this.writable});

  final web.ReadableStream readable;
  final web.WritableStream writable;
}

/// WebTransport-based XMPP socket for the web platform.
///
/// Opens a reliable control stream over WebTransport (HTTP/3 / QUIC), then
/// routes post-bind stanzas across auxiliary bidirectional streams using the
/// same bare-JID policy as native XMPP over QUIC. Server-initiated streams are
/// accepted immediately and can also be reused for outbound stanzas.
///
/// If the browser does not support WebTransport, or if the connection attempt
/// fails, this class throws so the caller can fall back to WebSocket.
class XmppWebTransportHtml extends XmppWebSocket {
  static const String TAG = 'XmppWebTransportHtml';

  static const int _auxStreamSlots = 20;
  static const int _maxControlBufferChars = 16 * 1024;

  WebTransportStreamChannel? _controlStream;
  Future<WebTransportStreamChannel> Function()? _openBidirectionalStream;
  late String Function(String event) _map;
  String Function(String) Function()? _makeAuxMapper;
  final WebTransportStreamFactory? _streamFactory;
  void Function()? _closeStream;
  Future<void> _writeQueue = Future<void>.value();
  bool _closed = false;
  bool _postBindReady = false;
  String? _accountBareJid;
  String _controlBuffer = '';
  final Map<int, WebTransportStreamChannel> _auxStreamsBySlot = {};
  final Map<int, Future<WebTransportStreamChannel>> _auxStreamOpening = {};
  final Map<int, List<String>> _auxStreamPendingQueue = {};
  final List<WebTransportStreamChannel> _serverStreamPool = [];

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
    _closed = false;

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
    late WebTransportStreamChannel controlStream;
    web.ReadableStream? incomingStreams;
    if (streamFactory != null) {
      Log.d(TAG, 'Creating injected WebTransport streams url=$url');
      final streams = await streamFactory(url);
      controlStream = WebTransportStreamChannel(
        readable: streams.readable,
        writable: streams.writable,
      );
      _openBidirectionalStream = streams.openBidirectionalStream;
      incomingStreams = streams.incomingBidirectionalStreams;
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
      controlStream = _channelFromBrowserStream(bidiStream);
      _openBidirectionalStream = () async => _channelFromBrowserStream(
            await transport.createBidirectionalStream().toDart,
          );
      incomingStreams = transport.incomingBidirectionalStreams;
      _closeStream = () => transport.close();
    }

    _controlStream = controlStream;
    _pumpIncoming(
      controlStream.readable,
      channel: 'webtransport-control',
      isControl: true,
      mapper: _map,
    );
    if (incomingStreams != null) {
      _startIncomingStreamAcceptLoop(incomingStreams);
    }

    return this;
  }

  /// Reads chunks from the WebTransport readable stream and emits decoded
  /// UTF-8 strings into [_controller].
  void _pumpIncoming(
    web.ReadableStream readable, {
    required String channel,
    required bool isControl,
    required String Function(String) mapper,
  }) {
    final reader = web.ReadableStreamDefaultReader(readable);
    final decoder = web.TextDecoder();
    Future<void> readNext() async {
      while (true) {
        final result = await reader.read().toDart;
        if (result.done) {
          Log.i(TAG, 'WebTransport XMPP receive stream ended channel=$channel');
          final trailing = decoder.decode();
          if (trailing.isNotEmpty && !_controller.isClosed) {
            _controller.add(mapper(trailing));
          }
          if (isControl && !_controller.isClosed) {
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
            Log.xmppp_receiving(chunk, channel: channel);
            if (isControl) _captureBindResult(chunk);
          }
          _controller.add(mapper(chunk));
        }
      }
    }

    readNext().catchError((Object error) {
      Log.e(TAG, 'WebTransport receive failed: $error');
      if (!_controller.isClosed) {
        _controller.addError(error);
        if (isControl) _controller.close();
      }
    });
  }

  WebTransportStreamChannel _channelFromBrowserStream(
    web.WebTransportBidirectionalStream stream,
  ) {
    return WebTransportStreamChannel(
      readable: stream.readable as web.ReadableStream,
      writable: stream.writable as web.WritableStream,
    );
  }

  void _startIncomingStreamAcceptLoop(web.ReadableStream incoming) {
    final reader = web.ReadableStreamDefaultReader(incoming);
    unawaited(Future<void>(() async {
      var index = 0;
      while (!_closed) {
        try {
          final result = await reader.read().toDart;
          if (result.done) break;
          final browserStream =
              result.value as web.WebTransportBidirectionalStream;
          final stream = _channelFromBrowserStream(browserStream);
          final channel = 'webtransport-server-${index++}';
          Log.i(TAG, 'Accepted server-initiated stream channel=$channel');
          _pumpIncoming(
            stream.readable,
            channel: channel,
            isControl: false,
            mapper: _makeAuxMapper?.call() ?? _map,
          );
          _serverStreamPool.add(stream);
        } catch (error) {
          if (!_closed) Log.e(TAG, 'Server stream accept failed: $error');
          break;
        }
      }
    }));
  }

  @override
  void write(Object? message) {
    final payload = message?.toString() ?? '';
    if (payload.isEmpty || _controlStream == null) return;
    if (!_postBindReady || !isStanzaPayload(payload)) {
      _queueWrite(_controlStream!, payload, 'webtransport-control');
      return;
    }
    final toBare = extractToBareJidForRouting(payload);
    final accountDomain = _accountBareJid?.split('@').last;
    if (toBare == null ||
        toBare == _accountBareJid ||
        toBare == accountDomain) {
      _queueWrite(_controlStream!, payload, 'webtransport-control');
      return;
    }
    final slot = xmppAuxSlotForBareJid(toBare, _auxStreamSlots);
    final existing = _auxStreamsBySlot[slot];
    if (existing != null) {
      _queueWrite(existing, payload, 'webtransport-aux-$slot');
      return;
    }
    _auxStreamPendingQueue.putIfAbsent(slot, () => []).add(payload);
    _ensureAuxStream(slot).then(
      (stream) => _flushAuxPendingQueue(slot, stream),
      onError: (Object error) {
        Log.w(TAG,
            'Aux stream open failed slot=$slot error=$error; using control');
        final queued = _auxStreamPendingQueue.remove(slot) ?? [];
        for (final stanza in queued) {
          _queueWrite(
            _controlStream!,
            stanza,
            'webtransport-control-fallback',
          );
        }
      },
    );
  }

  void _queueWrite(
    WebTransportStreamChannel stream,
    String payload,
    String channel,
  ) {
    final bytes = utf8.encode(payload);
    Log.d(TAG,
        'WebTransport write queued channel=$channel bytes=${bytes.length}');
    _writeQueue = _writeQueue.then((_) async {
      final writer = stream.writable.getWriter();
      try {
        Log.xmppp_sending(payload, channel: channel);
        await writer.write(Uint8List.fromList(bytes).toJS).toDart;
        Log.d(TAG,
            'WebTransport write completed channel=$channel bytes=${bytes.length}');
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

  Future<WebTransportStreamChannel> _ensureAuxStream(int slot) {
    final existing = _auxStreamsBySlot[slot];
    if (existing != null) return Future.value(existing);
    return _auxStreamOpening.putIfAbsent(slot, () => _openAuxStream(slot));
  }

  Future<WebTransportStreamChannel> _openAuxStream(int slot) async {
    try {
      if (_serverStreamPool.isNotEmpty) {
        final pooled = _serverStreamPool.removeAt(0);
        _auxStreamsBySlot[slot] = pooled;
        Log.i(TAG, 'Assigned server-initiated stream to aux slot=$slot');
        return pooled;
      }
      final open = _openBidirectionalStream;
      if (open == null) {
        throw StateError('Bidirectional stream opener unavailable');
      }
      final stream = await open();
      if (_closed) {
        throw StateError('WebTransport closed during aux stream open');
      }
      _auxStreamsBySlot[slot] = stream;
      Log.i(TAG, 'Opened client-initiated auxiliary stream slot=$slot');
      _pumpIncoming(
        stream.readable,
        channel: 'webtransport-aux-$slot',
        isControl: false,
        mapper: _makeAuxMapper?.call() ?? _map,
      );
      return stream;
    } finally {
      _auxStreamOpening.remove(slot);
    }
  }

  void _flushAuxPendingQueue(int slot, WebTransportStreamChannel stream) {
    final queued = _auxStreamPendingQueue.remove(slot) ?? [];
    for (final stanza in queued) {
      _queueWrite(stream, stanza, 'webtransport-aux-$slot');
    }
  }

  void _captureBindResult(String chunk) {
    if (_postBindReady) return;
    _controlBuffer += chunk;
    if (_controlBuffer.length > _maxControlBufferChars) {
      _controlBuffer = _controlBuffer.substring(
        _controlBuffer.length - _maxControlBufferChars,
      );
    }
    final bare = extractBoundBareJid(_controlBuffer);
    if (bare == null) return;
    _accountBareJid = bare;
    _postBindReady = true;
    Log.i(TAG, 'WebTransport multi-stream routing enabled account=$bare');
  }

  @override
  void close() {
    _closed = true;
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
    // XMPP over WebTransport uses the native XML stream framing used by
    // XMPP-over-QUIC, not the RFC 7395 <open/> WebSocket framing element.
    return "<?xml version='1.0'?><stream:stream xmlns='jabber:client' "
        "version='1.0' xmlns:stream='http://etherx.jabber.org/streams' "
        "to='$domain' xml:lang='en'>";
  }

  /// True for callers that need to distinguish WebTransport from WebSocket.
  bool get isWebTransport => true;

  bool get isMultiplexed => true;

  void setAuxMapperFactory(String Function(String) Function() factory) {
    _makeAuxMapper = factory;
  }
}
