import 'dart:async';
import 'dart:convert';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:synchronized/synchronized.dart';
import 'package:universal_io/io.dart';
import 'package:xml/xml.dart' as xml;
import 'package:xmpp_stone/src/ReconnectionManager.dart';
import 'package:xmpp_stone/src/ReconnectionState.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/ConnectionNegotatiorManager.dart';
import 'package:xmpp_stone/src/features/sasl/Sasl2AuthHandler.dart';
import 'package:xmpp_stone/src/features/sasl/SaslAuthenticationFeature.dart';
import 'package:xmpp_stone/src/features/servicediscovery/CarbonsNegotiator.dart';
import 'package:xmpp_stone/src/features/servicediscovery/MAMNegotiator.dart';
import 'package:xmpp_stone/src/features/servicediscovery/ServiceDiscoveryNegotiator.dart';
import 'package:xmpp_stone/src/features/streammanagement/StreamManagmentModule.dart';
import 'package:xmpp_stone/src/features/streammanagement/KeepaliveState.dart';
import 'package:xmpp_stone/src/parser/StanzaParser.dart';
import 'package:xmpp_stone/src/extensions/iq_router/IqRouter.dart';
import 'package:xmpp_stone/xmpp_stone.dart';

import 'connection/XmppWebsocketApi.dart'
    if (dart.library.io) 'connection/XmppWebsocketIo.dart'
    if (dart.library.html) 'connection/XmppWebsocketHtml.dart' as xmppSocket;

enum XmppConnectionState {
  Idle,
  Closed,
  SocketOpening,
  SocketOpened,
  DoneParsingFeatures,
  StartTlsFailed,
  AuthenticationNotSupported,
  PlainAuthentication,
  Authenticating,
  Authenticated,
  AuthenticatedSasl2AwaitingFeatures,
  AuthenticationFailure,
  Resumed,
  SessionInitialized,
  Ready,
  Closing,
  ForcefullyClosed,
  Reconnecting,
  WouldLikeToOpen,
  WouldLikeToClose,
}

typedef XmppSocketFactory = xmppSocket.XmppWebSocket Function();

class Connection {
  var lock = Lock(reentrant: true);

  static String TAG = 'Connection';

  static Map<String, Connection> instances = {};
  static void Function(Object error, StackTrace stackTrace)? errorReporter;

  static void reportError(Object error, StackTrace stackTrace) {
    errorReporter?.call(error, stackTrace);
  }

  XmppAccountSettings account;

  StreamManagementModule? streamManagementModule;

  Jid get serverName {
    if (_serverName != null) {
      return Jid.fromFullJid(_serverName!);
    } else {
      return Jid.fromFullJid(fullJid.domain); //todo move to account.domain!
    }
  } //move this somewhere

  String? _serverName;

  static Connection getInstance(
    XmppAccountSettings account, {
    XmppSocketFactory? socketFactory,
  }) {
    var connection = instances[account.fullJid.userAtDomain];
    if (connection == null) {
      connection = Connection(account, socketFactory: socketFactory);
      instances[account.fullJid.userAtDomain] = connection;
    }
    return connection;
  }

  static void removeInstance(XmppAccountSettings account) {
    instances.removeWhere((key, value) => key == account.fullJid.userAtDomain);
  }

  String? errorMessage;
  String? _authorizationIdentifier;
  Jid? _authorizedBareJid;
  Map<String, XmppElement> _sasl2InlineFeatures = {};
  List<XmppElement> _sasl2SuccessElements = [];
  XmppElement? _iapConfigVersion;
  bool _iapAdvertisedInCurrentStream = false;
  bool _sasl2PipelinedAuthInFlight = false;
  bool _sasl2PipelinedRetryIssued = false;
  xml.XmlElement? _deferredFeatureElement;

  static const String _bind2Namespace = 'urn:xmpp:bind:0';
  static const String _carbons2Namespace = 'urn:xmpp:carbons:2';

  bool authenticated = false;

  /// Whether resource binding was completed inline via Bind 2 (XEP-0386)
  /// during SASL2 authentication. When true, the old <bind> negotiator
  /// should skip itself.
  bool get bind2Completed => _bind2Completed;
  bool _bind2Completed = false;

  /// Whether message carbons (XEP-0280) were enabled inline during Bind 2.
  /// When true, the CarbonsNegotiator should skip its IQ round-trip.
  bool get carbons2EnabledInline => _carbons2EnabledInline;
  bool _carbons2EnabledInline = false;

  /// The idle timeout in seconds advertised by the server in the
  /// `<limits xmlns="urn:xmpp:stream-limits:0"><idle-seconds>` stream feature
  /// (XEP-0478). Null if the server did not advertise a limit.
  int? xmppIdleSeconds;

  final StreamController<AbstractStanza?> _inStanzaStreamController =
      StreamController.broadcast();

  final StreamController<AbstractStanza> _outStanzaStreamController =
      StreamController.broadcast();

  final StreamController<Nonza> _inNonzaStreamController =
      StreamController.broadcast();

  final StreamController<Nonza> _outNonzaStreamController =
      StreamController.broadcast();

  final StreamController<XmppConnectionState> _connectionStateStreamController =
      StreamController.broadcast();

  Stream<AbstractStanza?> get inStanzasStream {
    return _inStanzaStreamController.stream;
  }

  Stream<Nonza> get inNonzasStream {
    return _inNonzaStreamController.stream;
  }

  Stream<Nonza> get outNonzasStream {
    return _inNonzaStreamController.stream;
  }

  Stream<AbstractStanza> get outStanzasStream {
    return _outStanzaStreamController.stream;
  }

  Stream<XmppConnectionState> get connectionStateStream {
    return _connectionStateStreamController.stream;
  }

  Jid get fullJid {
    final authorized = _authorizedBareJid;
    if (authorized == null) {
      return account.fullJid;
    }
    return Jid(authorized.local, authorized.domain, account.resource);
  }

  late ConnectionNegotiatorManager connectionNegotatiorManager;

  void fullJidRetrieved(Jid jid) {
    _authorizedBareJid = Jid(jid.local, jid.domain, '');
    _authorizationIdentifier = _authorizedBareJid!.userAtDomain;
    account.resource = jid.resource;
  }

  String? get authorizationIdentifier => _authorizationIdentifier;

  void setAuthorizationIdentifier(String bareJid) {
    final parsed = Jid.fromFullJid(bareJid);
    if (!parsed.isValid()) {
      return;
    }
    _authorizedBareJid = Jid(parsed.local, parsed.domain, '');
    _authorizationIdentifier = _authorizedBareJid!.userAtDomain;
  }

  Map<String, XmppElement> get sasl2InlineFeatures =>
      Map.unmodifiable(_sasl2InlineFeatures);

  void setSasl2InlineFeatures(Map<String, XmppElement> features) {
    _sasl2InlineFeatures = Map<String, XmppElement>.from(features);
  }

  List<XmppElement> get sasl2SuccessElements =>
      List.unmodifiable(_sasl2SuccessElements);

  void setSasl2SuccessElements(List<XmppElement> elements) {
    _sasl2SuccessElements = List<XmppElement>.from(elements);
    _processBind2SuccessElements(elements);
  }

  /// Checks the SASL2 success elements for a Bind 2 <bound> response
  /// (XEP-0386) and, if present, extracts the bound JID so that the old
  /// <bind> IQ negotiator can be skipped. Also detects whether carbons
  /// (XEP-0280) were enabled inline so CarbonsNegotiator can skip its IQ.
  void _processBind2SuccessElements(List<XmppElement> elements) {
    _bind2Completed = false;
    _carbons2EnabledInline = false;
    for (final element in elements) {
      if (element.getNameSpace() == _bind2Namespace) {
        _bind2Completed = true;
        // The <bound> element may carry a <jid> child with the full JID
        // assigned by the server.
        final jidText = element.getChild('jid')?.textValue?.trim();
        if (jidText != null && jidText.isNotEmpty) {
          fullJidRetrieved(Jid.fromFullJid(jidText));
        }
        // Check if carbons were enabled inline within the <bound> element.
        final enabledEl = element.getChild('enabled');
        if (enabledEl?.getNameSpace() == _carbons2Namespace) {
          _carbons2EnabledInline = true;
        }
        break;
      }
    }
  }

  XmppElement? get iapConfigVersion => _iapConfigVersion;

  void setIapConfigVersion({required String scheme, required String value}) {
    final element = XmppElement()
      ..name = 'config-version'
      ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:iap:0'))
      ..addAttribute(XmppAttribute('scheme', scheme))
      ..addAttribute(XmppAttribute('value', value));
    _iapConfigVersion = element;
    _iapAdvertisedInCurrentStream = true;
    account.iapConfigVersionScheme = scheme;
    account.iapConfigVersionValue = value;
  }

  void clearIapConfigVersion() {
    _iapConfigVersion = null;
    _iapAdvertisedInCurrentStream = false;
    account.iapConfigVersionScheme = null;
    account.iapConfigVersionValue = null;
  }

  bool get iapAdvertisedInCurrentStream => _iapAdvertisedInCurrentStream;
  bool get sasl2PipelinedAuthInFlight => _sasl2PipelinedAuthInFlight;
  bool get isQuic => _socket?.isQuic ?? false;

  xmppSocket.XmppWebSocket? _socket;
  StreamSubscription<String>? _socketSubscription;

  xmppSocket.XmppWebSocket? get socket => _socket;

  // for testing purpose
  set socket(xmppSocket.XmppWebSocket? value) {
    _socket = value;
  }

  XmppConnectionState _state = XmppConnectionState.Idle;

  ReconnectionManager? reconnectionManager;
  final XmppSocketFactory _socketFactory;
  final StringBuffer _pendingWriteBuffer = StringBuffer();
  bool _flushScheduled = false;
  int _inboundProcessingDepth = 0;

  Connection(this.account, {XmppSocketFactory? socketFactory})
      : _socketFactory = socketFactory ?? xmppSocket.createSocket {
    RosterManager.getInstance(this);
    PresenceManager.getInstance(this);
    MessageHandler.getInstance(this);
    PingManager.getInstance(this);
    IqRouter.getInstance(this);
    connectionNegotatiorManager = ConnectionNegotiatorManager(this, account);
    reconnectionManager = ReconnectionManager(this);
  }

  void _openStream() {
    var streamOpeningString = _socket?.getStreamOpeningElement(fullJid.domain);
    write(streamOpeningString);
    _tryStartSasl2IapPipeline();
  }

  String restOfResponse = '';

  /// Extracts all complete top-level XML elements from [input], returning them
  /// wrapped in `<xmpp_stone>…</xmpp_stone>` and leaving any trailing
  /// incomplete fragment in [remainder].
  ///
  /// This replaces the old "parse whole buffer, fail if incomplete" approach
  /// which would hold back all complete stanzas whenever a partial fragment
  /// was present at the end of the buffer — causing stanza starvation under
  /// high latency / burst conditions (e.g. a large MUC presence flood).
  ///
  /// The algorithm:
  ///  1. Strip any `<?xml … ?>` prolog.
  ///  2. Walk the string character-by-character tracking element depth.
  ///  3. Each time depth returns to 0 after opening at least one element,
  ///     we have a complete top-level element — record its end offset.
  ///  4. Emit all complete elements wrapped in `<xmpp_stone>`, keep the rest.
  ///
  /// Special cases:
  ///  • `</stream:stream>` — signals connection close; caller handles it.
  ///  • `<stream:stream …>` opener (depth never closes) — emitted as-is with
  ///    a synthetic `</stream:stream>` appended so the XML parser accepts it.
  static _ExtractResult _extractCompleteElements(
    String input,
  ) {
    // Strip XML prolog(s) for depth-counting purposes but keep them in the
    // output so the XML parser in handleResponse can strip them too.
    final stripped = input.replaceAll(RegExp(r'<\?(xml[^?]*)\?>'), '');

    int depth = 0;
    bool inTag = false;
    bool inClosingTag = false;
    bool inSelfClosing = false;
    bool inString = false;
    String stringChar = '';
    bool inComment = false;
    int i = 0;
    final len = stripped.length;
    // Offsets (in `stripped`) where complete top-level elements end.
    final List<int> completeEnds = [];
    // Whether we have seen a `<stream:stream` opener that was never closed.
    bool hasUnclosedStreamOpener = false;

    while (i < len) {
      final ch = stripped[i];

      // Handle XML comments <!-- … -->
      if (!inString && !inComment && i + 3 < len &&
          ch == '<' && stripped[i + 1] == '!' &&
          stripped[i + 2] == '-' && stripped[i + 3] == '-') {
        final end = stripped.indexOf('-->', i + 4);
        if (end < 0) break; // incomplete comment — stop
        i = end + 3;
        continue;
      }

      if (inComment) {
        // (handled above)
        i++;
        continue;
      }

      if (inString) {
        if (ch == stringChar) inString = false;
        i++;
        continue;
      }

      if (ch == '"' || ch == "'") {
        if (inTag) {
          inString = true;
          stringChar = ch;
        }
        i++;
        continue;
      }

      if (ch == '<') {
        inClosingTag = i + 1 < len && stripped[i + 1] == '/';
        inSelfClosing = false;
        if (!inClosingTag) {
          // Check for stream:stream opener — it never gets a closing tag in
          // the normal flow, so we handle it specially.
          if (depth == 0) {
            final tagEnd = stripped.indexOf('>', i);
            if (tagEnd >= 0) {
              final tagContent = stripped.substring(i + 1, tagEnd);
              if (tagContent.trimLeft().startsWith('stream:stream')) {
                // Emit the opener with a synthetic close so the XML parser
                // accepts it, then continue scanning after it.
                hasUnclosedStreamOpener = true;
                completeEnds.add(tagEnd + 1);
                i = tagEnd + 1;
                continue;
              }
            }
          }
          // Opening tag: increment depth now so self-closing can decrement it.
          depth++;
        }
        inTag = true;
        i++;
        continue;
      }

      if (ch == '/' && inTag) {
        // Could be self-closing `/>`
        if (i + 1 < len && stripped[i + 1] == '>') {
          inSelfClosing = true;
        }
        i++;
        continue;
      }

      if (ch == '>') {
        if (inTag) {
          inTag = false;
          if (inSelfClosing) {
            // Self-closing tag <foo/>: depth was incremented when we saw `<`
            // opening, so decrement it back. If depth returns to 0 this is a
            // complete top-level element.
            depth--;
            if (depth == 0) completeEnds.add(i + 1);
          } else if (inClosingTag) {
            // Closing tag </foo>: decrement depth.
            depth--;
            if (depth == 0) completeEnds.add(i + 1);
          }
          // Opening tag: depth was already incremented when we saw `<`.
          inSelfClosing = false;
          inClosingTag = false;
        }
        i++;
        continue;
      }

      i++;
    }

    if (completeEnds.isEmpty) {
      // Nothing complete yet — keep buffering.
      return _ExtractResult(emitted: '', remainder: input);
    }

    // The last complete element ends at completeEnds.last in `stripped`.
    // We need the corresponding offset in the original `input`. Since we only
    // stripped `<?xml…?>` prologs (which appear at the very start), the offset
    // in `stripped` equals the offset in `input` plus the length of any
    // stripped prologs that appeared before that position. For simplicity —
    // and because prologs only appear at the very start — we use the original
    // `input` string for slicing and just re-strip prologs in the output.
    // Find the end offset in the original input by scanning for the same
    // character position accounting for stripped prologs.
    final prologLength = input.length - stripped.length;
    final cutInStripped = completeEnds.last;
    final cutInInput = cutInStripped + prologLength;

    final completeRaw = input.substring(0, cutInInput);
    final remainder = input.substring(cutInInput);

    // Wrap complete elements for the XML parser in handleResponse.
    String wrapped = completeRaw;
    if (hasUnclosedStreamOpener) {
      wrapped = '$wrapped</stream:stream>';
    }
    wrapped = '<xmpp_stone>$wrapped</xmpp_stone>';

    return _ExtractResult(emitted: wrapped, remainder: remainder);
  }

  /// Returns a new independent stream-response mapper closure.
  /// Each QUIC aux stream must get its own mapper so that partial XML
  /// fragments from different streams are buffered independently and do not
  /// corrupt each other's parse state.
  String Function(String) makeStreamResponseMapper() {
    var buffer = '';
    return (String response) {
      final combined = buffer + response;
      if (combined.contains('</stream:stream>')) {
        buffer = '';
        close();
        return '';
      }
      final result = _extractCompleteElements(combined);
      buffer = result.remainder;
      return result.emitted;
    };
  }

  String prepareStreamResponse(String response) {
    // Accumulate with any previously incomplete data.
    // Receive logging (with channel label) is done at the transport layer
    // (XmppWebsocketIo.listen for TCP/WS, _startRecvLoop for QUIC) so that
    // the log line can identify which stream the data arrived on.
    final combined = restOfResponse + response;

    if (combined.contains('</stream:stream>')) {
      restOfResponse = '';
      close();
      return '';
    }

    final result = _extractCompleteElements(combined);
    restOfResponse = result.remainder;
    return result.emitted;
  }

  void reconnect() {
    if (_state == XmppConnectionState.ForcefullyClosed) {
      setState(XmppConnectionState.Reconnecting);
      openSocket();
    }
  }

  void connect() {
    if (_state == XmppConnectionState.Closing) {
      _state = XmppConnectionState.WouldLikeToOpen;
    }
    if (_state == XmppConnectionState.Closed) {
      _state = XmppConnectionState.Idle;
    }
    if (_state == XmppConnectionState.Idle) {
      openSocket();
    }
  }

  Future<void> openSocket() async {
    _sasl2InlineFeatures = {};
    _sasl2SuccessElements = [];
    _iapAdvertisedInCurrentStream = false;
    _sasl2PipelinedAuthInFlight = false;
    _sasl2PipelinedRetryIssued = false;
    _deferredFeatureElement = null;
    _bind2Completed = false;
    _carbons2EnabledInline = false;
    final iapScheme = account.iapConfigVersionScheme?.trim();
    final iapValue = account.iapConfigVersionValue?.trim();
    if (iapScheme != null &&
        iapScheme.isNotEmpty &&
        iapValue != null &&
        iapValue.isNotEmpty) {
      final element = XmppElement()
        ..name = 'config-version'
        ..addAttribute(XmppAttribute('xmlns', 'urn:xmpp:iap:0'))
        ..addAttribute(XmppAttribute('scheme', iapScheme))
        ..addAttribute(XmppAttribute('value', iapValue));
      _iapConfigVersion = element;
    } else {
      _iapConfigVersion = null;
    }
    connectionNegotatiorManager.init();
    setState(XmppConnectionState.SocketOpening);
    try {
      final useWebSocket = account.useWebSocket ||
          account.useWebTransport ||
          account.wsUrl != null ||
          account.wsHost != null ||
          account.wsPath != null;
      final socketHost = useWebSocket
          ? (account.wsHost ?? account.host ?? account.domain)
          : (account.host ?? account.domain);
      final socketPort =
          useWebSocket ? (account.wsPort ?? account.port) : account.port;
      final wsUri = account.wsUrl != null ? Uri.tryParse(account.wsUrl!) : null;
      final quicEndpoints = useWebSocket
          ? const <XmppQuicEndpoint>[]
          : (account.quicEndpoints != null && account.quicEndpoints!.isNotEmpty
              ? account.quicEndpoints!
              : const <XmppQuicEndpoint>[]);
      final endpoints = useWebSocket
          ? const <XmppTcpEndpoint>[]
          : (account.tcpEndpoints != null && account.tcpEndpoints!.isNotEmpty
              ? account.tcpEndpoints!
              : <XmppTcpEndpoint>[
                  XmppTcpEndpoint(
                    host: socketHost,
                    port: socketPort,
                    directTls: account.directTls,
                    tlsHost: account.domain,
                  ),
                ]);

      if (useWebSocket) {
        final socket = _socketFactory();
        await socket.connect(
          socketHost,
          socketPort,
          wsPath: account.wsPath,
          wsUri: wsUri,
          useWebSocket: !account.useWebTransport,
          useWebTransport: account.useWebTransport,
          directTls: account.directTls,
          tlsHost: account.domain,
          map: prepareStreamResponse,
        );
        _attachOpenedSocket(socket);
        return;
      }

      Object? lastError;
      for (final endpoint in quicEndpoints) {
        final socket = _socketFactory();
        try {
          Log.i(
            TAG,
            'QUIC endpoint attempt host=${endpoint.host} port=${endpoint.port}',
          );
          await socket.connect(
            endpoint.host,
            endpoint.port,
            useWebSocket: false,
            useQuic: true,
            directTls: false,
            tlsHost: endpoint.tlsHost ?? account.domain,
            map: prepareStreamResponse,
          );
          // Supply a per-aux-stream mapper factory so each QUIC aux stream
          // gets its own independent XML buffer. Without this, all streams
          // share the single restOfResponse field in prepareStreamResponse,
          // causing interleaved chunks from different streams to corrupt
          // each other's parse state and silently drop stanzas.
          if (socket.isQuic) {
            (socket as dynamic).setAuxMapperFactory(makeStreamResponseMapper);
          }
          _attachOpenedSocket(socket);
          return;
        } catch (error) {
          lastError = error;
          try {
            socket.close();
          } catch (_) {
            // ignore close errors while failing over endpoints
          }
          Log.w(
            TAG,
            'QUIC endpoint failed host=${endpoint.host} '
            'port=${endpoint.port} error=$error',
          );
        }
      }

      for (final endpoint in endpoints) {
        final socket = _socketFactory();
        try {
          Log.i(
            TAG,
            'TCP endpoint attempt host=${endpoint.host} '
            'port=${endpoint.port} directTls=${endpoint.directTls}',
          );
          await socket.connect(
            endpoint.host,
            endpoint.port,
            useWebSocket: false,
            useQuic: false,
            directTls: endpoint.directTls,
            tlsHost: endpoint.tlsHost ?? account.domain,
            map: prepareStreamResponse,
          );
          _attachOpenedSocket(socket);
          return;
        } catch (error) {
          lastError = error;
          try {
            socket.close();
          } catch (_) {
            // ignore close errors while failing over endpoints
          }
          Log.w(
            TAG,
            'TCP endpoint failed host=${endpoint.host} '
            'port=${endpoint.port} error=$error',
          );
        }
      }
      throw Exception('All TCP endpoints failed. lastError=$lastError');
    } catch (error) {
      Log.e(TAG, 'Socket Exception' + error.toString());
      print('XMPP socket error: $error');
      handleConnectionError(error.toString());
    }
  }

  void _attachOpenedSocket(xmppSocket.XmppWebSocket socket) {
    // if not closed in meantime
    if (_state != XmppConnectionState.Closed) {
      setState(XmppConnectionState.SocketOpened);
      _socket = socket;
      _socketSubscription?.cancel();
      _socketSubscription =
          socket.listen(handleResponse, onDone: handleConnectionDone);
      _pendingWriteBuffer.clear();
      _flushScheduled = false;
      _inboundProcessingDepth = 0;
      restOfResponse = '';
      _openStream();
    } else {
      Log.d(TAG, 'Closed in meantime');
      socket.close();
    }
  }

  void close() {
    if (state == XmppConnectionState.SocketOpening) {
      throw Exception('Closing is not possible during this state');
    }
    if (state != XmppConnectionState.Closed &&
        state != XmppConnectionState.ForcefullyClosed &&
        state != XmppConnectionState.Closing) {
      if (_socket != null) {
        try {
          setState(XmppConnectionState.Closing);
          _socketSubscription?.cancel();
          _pendingWriteBuffer.clear();
          _flushScheduled = false;
          _socket!.write('</stream:stream>');
        } on Exception {
          Log.d(TAG, 'Socket already closed');
        }
      }
      authenticated = false;
    }
  }

  /// Dispose of the connection so stops all activities and cannot be re-used.
  /// For the connection to be garbage collected.
  ///
  /// If the Connection instance was created with [getInstance],
  /// you must also call [Connection.removeInstance] after calling [dispose].
  ///
  /// If you intend to re-use the connection later, consider just calling [close] instead.
  void dispose() {
    close();
    RosterManager.removeInstance(this);
    PresenceManager.removeInstance(this);
    MessageHandler.removeInstance(this);
    PingManager.removeInstance(this);
    IqRouter.removeInstance(this);
    ServiceDiscoveryNegotiator.removeInstance(this);
    StreamManagementModule.removeInstance(this);
    CarbonsNegotiator.removeInstance(this);
    MAMNegotiator.removeInstance(this);
    reconnectionManager?.close();
    _socket?.close();
  }

  bool startMatcher(xml.XmlElement element) {
    var name = element.name.local;
    return name == 'stream';
  }

  bool stanzaMatcher(xml.XmlElement element) {
    var name = element.name.local;
    return name == 'iq' || name == 'message' || name == 'presence';
  }

  bool nonzaMatcher(xml.XmlElement element) {
    var name = element.name.local;
    return name != 'iq' && name != 'message' && name != 'presence';
  }

  bool featureMatcher(xml.XmlElement element) {
    var name = element.name.local;
    return (name == 'stream:features' || name == 'features');
  }

  /// Matches a SASL (1 or 2) `<success/>` element. Used to flip
  /// [authenticated] synchronously as soon as a success response is parsed,
  /// see the comment in [handleResponse] for why this matters.
  bool saslSuccessMatcher(xml.XmlElement element) {
    if (element.name.local != 'success') {
      return false;
    }
    final xmlns = element.getAttribute('xmlns');
    return xmlns == 'urn:xmpp:sasl:2' ||
        xmlns == 'urn:ietf:params:xml:ns:xmpp-sasl';
  }

  void handleResponse(String response) {
    _inboundProcessingDepth++;
    // prepareStreamResponse (the map function) already buffers incomplete
    // chunks and returns '' until a complete, parseable XML fragment is ready.
    final fullResponse = response;

    try {
      if (fullResponse.isNotEmpty) {
        xml.XmlNode? xmlResponse;
        xmlResponse = xml.XmlDocument.parse(
                fullResponse.replaceAll(RegExp(r'<\?(xml.+?)\>'), ''))
            .firstChild;

        //TODO: Improve parser for children only
        xmlResponse!.descendants
            .whereType<xml.XmlElement>()
            .where((element) => startMatcher(element))
            .forEach((element) => processInitialStream(element));

        xmlResponse.childElements
            .where((element) => stanzaMatcher(element))
            .map((xmlElement) => StanzaParser.parseStanza(xmlElement))
            .forEach((stanza) => _inStanzaStreamController.add(stanza));

        // SASL2's <success/> can carry a sibling <stream:features/> in the
        // very same response. The SASL handlers only flip `authenticated`
        // once their handshake Future resolves, which happens asynchronously
        // (via the stanza stream above), i.e. *after* this method returns.
        // Detecting <success/> here and setting `authenticated` immediately
        // ensures the feature negotiation below (which gates disco-based
        // negotiators, e.g. Service Discovery -> MAM, on `authenticated`)
        // sees the correct value instead of racing the async handshake.
        if (xmlResponse.descendants
            .whereType<xml.XmlElement>()
            .any(saslSuccessMatcher)) {
          authenticated = true;
        }

        xmlResponse.descendants
            .whereType<xml.XmlElement>()
            .where((element) => featureMatcher(element))
            .forEach((feature) {
          if (_sasl2PipelinedAuthInFlight) {
            _deferredFeatureElement = feature;
          } else {
            connectionNegotatiorManager.negotiateFeatureList(feature);
          }
        });

        //TODO: Probably will introduce bugs!!!
        xmlResponse.childElements
            .where((element) => nonzaMatcher(element))
            .map((xmlElement) => Nonza.parse(xmlElement))
            .forEach((nonza) => _inNonzaStreamController.add(nonza));
      }
    } finally {
      _inboundProcessingDepth--;
      if (_inboundProcessingDepth <= 0) {
        _inboundProcessingDepth = 0;
        _scheduleFlush();
      }
    }
  }

  void processInitialStream(xml.XmlElement initialStream) {
    Log.d(TAG, 'processInitialStream');
    var from = initialStream.getAttribute('from');
    if (from != null) {
      _serverName = from;
    }
  }

  bool isOpened() {
    return state != XmppConnectionState.Closed &&
        state != XmppConnectionState.ForcefullyClosed &&
        state != XmppConnectionState.Closing &&
        state != XmppConnectionState.SocketOpening;
  }

  void write(message) {
    // Note: the actual "Xmpp Sending" log entry is emitted by the socket at the
    // moment the data is handed to the transport (TCP/WS/QUIC). This gives an
    // accurate picture of what is on the wire and, for QUIC, which stream
    // (control vs aux slot) the data was written to. Logging here would only
    // record queueing, which can differ significantly from actual send time
    // when writes are buffered or routed to an aux QUIC stream that is still
    // being opened.
    if (!isOpened()) {
      return;
    }
    if (account.bufferedWritesEnabled) {
      _pendingWriteBuffer.write(message.toString());
      if (_inboundProcessingDepth <= 0) {
        _scheduleFlush();
      }
    } else {
      _safeSocketWrite(message);
    }
  }

  void _scheduleFlush() {
    if (_flushScheduled || !account.bufferedWritesEnabled) {
      return;
    }
    _flushScheduled = true;
    Timer.run(() {
      _flushScheduled = false;
      _flushPendingWrites();
    });
  }

  void _flushPendingWrites() {
    if (!isOpened()) {
      _pendingWriteBuffer.clear();
      return;
    }
    if (_pendingWriteBuffer.isEmpty) {
      return;
    }
    final payload = _pendingWriteBuffer.toString();
    _pendingWriteBuffer.clear();
    _safeSocketWrite(payload);
  }

  void _safeSocketWrite(Object? payload) {
    final socket = _socket;
    if (socket == null) {
      return;
    }
    try {
      socket.write(payload);
    } catch (error, stackTrace) {
      reportError(error, stackTrace);
      Log.e(TAG, 'Socket write failed: $error');
      handleConnectionError(error.toString());
    }
  }

  void _tryStartSasl2IapPipeline() {
    if (_sasl2PipelinedRetryIssued || _sasl2PipelinedAuthInFlight) {
      return;
    }
    if (!account.iapEnabled ||
        !account.iapPipeliningEnabled ||
        !account.iapIncludeConfigVersion) {
      return;
    }
    if (_iapConfigVersion == null) {
      return;
    }

    final mechanism = SaslAuthenticationFeature.mechanismFromWireName(
      account.sasl2LastMechanism,
    );
    if (mechanism == null) {
      return;
    }
    final cachedMechanisms = account.sasl2CachedMechanisms ?? const <String>[];
    final mechanismName = account.sasl2LastMechanism;
    if (mechanismName == null || !cachedMechanisms.contains(mechanismName)) {
      return;
    }

    _sasl2PipelinedAuthInFlight = true;
    authenticating();
    final handler = Sasl2AuthHandler(
      this,
      account.password,
      mechanism,
      allowCachedIapConfigVersion: true,
    );
    handler.start().then((result) {
      _sasl2PipelinedAuthInFlight = false;
      if (result.successful) {
        setState(XmppConnectionState.AuthenticatedSasl2AwaitingFeatures);
        _deferredFeatureElement = null;
        return;
      }

      if (result.retryWithFreshFeatures &&
          !_sasl2PipelinedRetryIssued &&
          _deferredFeatureElement != null) {
        _sasl2PipelinedRetryIssued = true;
        final features = _deferredFeatureElement!;
        _deferredFeatureElement = null;
        connectionNegotatiorManager.negotiateFeatureList(features);
        return;
      }

      setState(XmppConnectionState.AuthenticationFailure);
      errorMessage = result.message;
      close();
    });
  }

  void writeStanza(AbstractStanza stanza) {
    _outStanzaStreamController.add(stanza);
    write(stanza.buildXmlString());
  }

  void writeNonza(Nonza nonza) {
    _outNonzaStreamController.add(nonza);
    write(nonza.buildXmlString());
  }

  /// Emits keepalive state updates from Stream Management keepalive handling.
  Stream<KeepaliveState> get keepaliveStateStream {
    return streamManagementModule?.keepaliveStateStream ?? const Stream.empty();
  }

  /// Emits keepalive failures (SM ack timeout or ping timeout).
  Stream<KeepaliveFailure> get keepaliveFailureStream {
    return streamManagementModule?.keepaliveFailureStream ??
        const Stream.empty();
  }

  /// Most recent keepalive latency observed by the active keepalive strategy.
  Duration? get keepaliveLatency {
    return streamManagementModule?.lastKeepaliveLatency;
  }

  /// Updates keepalive cadence for foreground/background app state.
  void setKeepaliveBackgroundMode(bool enabled) {
    streamManagementModule?.setBackgroundMode(enabled);
  }

  /// Forces an immediate keepalive probe using SM-first, ping fallback logic.
  void probeKeepalive({bool shortTimeout = false}) {
    streamManagementModule?.probeKeepalive(shortTimeout: shortTimeout);
  }

  Stream<ReconnectionState> get reconnectStateStream {
    return reconnectionManager?.stateStream ?? const Stream.empty();
  }

  ReconnectionState get reconnectState {
    return reconnectionManager?.currentState ??
        ReconnectionState(
          phase: ReconnectionPhase.idle,
          updatedAt: DateTime.now(),
        );
  }

  void setReconnectPolicy(ReconnectionPolicy policy) {
    reconnectionManager?.setPolicy(policy);
  }

  void setReconnectContext({bool? networkOnline, bool? allowAutoReconnect}) {
    reconnectionManager?.setContext(
      networkOnline: networkOnline,
      allowAutoReconnect: allowAutoReconnect,
    );
  }

  void requestReconnect({
    required ReconnectionReason reason,
    bool immediate = false,
    bool shortTimeout = false,
  }) {
    reconnectionManager?.requestReconnect(
      reason: reason,
      immediate: immediate,
      shortTimeout: shortTimeout,
    );
  }

  void setReconnectTerminal(String message) {
    reconnectionManager?.setTerminalState(message);
  }

  void setState(XmppConnectionState state) {
    _state = state;
    _fireConnectionStateChangedEvent(state);
    _processState(state);
    Log.d(TAG, 'State: $_state');
  }

  XmppConnectionState get state {
    return _state;
  }

  void _processState(XmppConnectionState state) {
    if (state == XmppConnectionState.Authenticated) {
      authenticated = true;
      _openStream();
    } else if (state ==
        XmppConnectionState.AuthenticatedSasl2AwaitingFeatures) {
      authenticated = true;
    } else if (state == XmppConnectionState.Closed ||
        state == XmppConnectionState.ForcefullyClosed) {
      authenticated = false;
    }
  }

  void processError(xml.XmlDocument xmlResponse) {
    //todo find error stanzas
  }

  void startSecureSocket() {
    Log.d(TAG, 'startSecureSocket');
    print('XMPP StartTLS: securing socket');

    _socket!
        .secure(host: account.domain, onBadCertificate: _validateBadCertificate)
        .then((secureSocket) {
      if (secureSocket == null) return;

      _socketSubscription?.cancel();
      _socketSubscription = secureSocket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .map(prepareStreamResponse)
          .listen(handleResponse,
              onError: (error) =>
                  {handleSecuredConnectionError(error.toString())},
              onDone: handleSecuredConnectionDone);
      _openStream();
    });
  }

  void fireNewStanzaEvent(AbstractStanza stanza) {
    _inStanzaStreamController.add(stanza);
  }

  void _fireConnectionStateChangedEvent(XmppConnectionState state) {
    _connectionStateStreamController.add(state);
  }

  bool elementHasAttribute(xml.XmlElement element, xml.XmlAttribute attribute) {
    var list = element.attributes.firstWhereOrNull((attr) =>
        attr.name.local == attribute.name.local &&
        attr.value == attribute.value);
    return list != null;
  }

  void sessionReady() {
    setState(XmppConnectionState.SessionInitialized);
    //now we should send presence
  }

  void doneParsingFeatures() {
    if (state == XmppConnectionState.SessionInitialized) {
      setState(XmppConnectionState.Ready);
    }
  }

  void startTlsFailed() {
    setState(XmppConnectionState.StartTlsFailed);
    close();
  }

  void authenticating() {
    setState(XmppConnectionState.Authenticating);
  }

  bool _validateBadCertificate(X509Certificate certificate) {
    return true;
  }

  bool isTlsRequired() {
    if (account.useWebSocket ||
        account.directTls ||
        account.wsUrl != null ||
        account.wsHost != null ||
        account.wsPath != null) {
      return false;
    }
    return xmppSocket.isTlsRequired();
  }

  void handleConnectionDone() {
    Log.d(TAG, 'Handle connection done');
    handleCloseState();
  }

  void handleSecuredConnectionDone() {
    Log.d(TAG, 'Handle secured connection done');
    handleCloseState();
  }

  void handleConnectionError(String error) {
    handleCloseState();
  }

  void simulateForcefulClose() {
    try {
      _socketSubscription?.cancel();
      _socket?.close();
    } catch (_) {
      // Ignore socket close errors during simulation.
    }
    handleCloseState();
  }

  void handleCloseState() {
    if (state == XmppConnectionState.WouldLikeToOpen) {
      setState(XmppConnectionState.Closed);
      connect();
    } else if (state != XmppConnectionState.Closing) {
      setState(XmppConnectionState.ForcefullyClosed);
    } else {
      setState(XmppConnectionState.Closed);
    }
  }

  void handleSecuredConnectionError(String error) {
    Log.d(TAG, 'Handle Secured Error  $error');
    handleCloseState();
  }

  bool isAsyncSocketState() {
    return state == XmppConnectionState.SocketOpening ||
        state == XmppConnectionState.Closing;
  }
}

/// Result type for [Connection._extractCompleteElements].
class _ExtractResult {
  const _ExtractResult({required this.emitted, required this.remainder});
  final String emitted;
  final String remainder;
}
