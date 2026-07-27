/// XEP-0484 FAST (Fast Authentication Streamlining Tokens) handler.
///
/// Implements both the **HT-*** and **HT2-*** SASL mechanisms that allow a
/// client to re-authenticate using a short-lived token previously issued by
/// the server, avoiding a full SCRAM exchange on every reconnection.
///
/// Mechanism name format:
///   `HT-<hash>-<cb>`   – original FAST token SASL mechanism
///   `HT2-<hash>-<cb>`  – updated FAST token SASL mechanism
///
/// Supported hash algorithms: SHA-256, SHA-512.
/// Supported channel-binding types: NONE (only, for now).
///
/// Both mechanisms are single-message: the client sends an initial response
/// and then awaits a `<success>` or `<failure>` from the server.
///
/// HT-*  initial response:  `authcid '\x00' token_bytes`
/// HT2-* initial response:  `HMAC-<hash>(token_bytes, "Initiator" || cb_data)`
/// where for NONE channel-binding cb_data is the empty byte string.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptoutils/utils.dart';
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/sasl/AbstractSaslHandler.dart';

import '../../logger/Log.dart';
import '../../elements/XmppElement.dart';

/// Identifies which variant of FAST is in use.
enum FastMechanismVariant {
  /// Original HT-* mechanism (token prepended with authcid + NUL).
  ht,

  /// Updated HT2-* mechanism (HMAC of token).
  ht2,
}

/// A SASL handler for XEP-0484 HT-* and HT2-* mechanisms used within the
/// SASL2 (urn:xmpp:sasl:2) profile.
///
/// After calling [start] the handler:
/// 1. Sends `<authenticate mechanism='HT…'><initial-response>…</initial-response></authenticate>`
/// 2. Awaits `<success>` or `<failure>`.
/// 3. On success, extracts any new FAST token from `<token>` children and
///    stores it back into [connection.account].
class FastAuthHandler implements AbstractSaslHandler {
  static const String TAG = 'FastAuthHandler';
  static const String sasl2Namespace = 'urn:xmpp:sasl:2';
  static const String fastNamespace = 'urn:xmpp:fast:0';
  static const String bind2Namespace = 'urn:xmpp:bind:0';
  static const String carbons2Namespace = 'urn:xmpp:carbons:2';

  final Connection _connection;

  /// The full wire-name of the mechanism, e.g. "HT2-SHA-256-NONE".
  final String _mechanismName;

  final FastMechanismVariant _variant;
  final crypto.Hash _hash;

  /// Base64-encoded token bytes as stored in the account.
  final String _tokenBase64;

  late StreamSubscription<Nonza> _subscription;
  final _completer = Completer<AuthenticationResult>();

  FastAuthHandler(
    this._connection,
    this._mechanismName,
    this._variant,
    this._hash,
    this._tokenBase64,
  );

  /// Creates a [FastAuthHandler] from a stored mechanism name such as
  /// "HT2-SHA-256-NONE". Returns `null` if the mechanism is not supported.
  static FastAuthHandler? fromMechanismName(
    Connection connection,
    String mechanismName,
    String tokenBase64,
  ) {
    final upper = mechanismName.toUpperCase();
    FastMechanismVariant? variant;
    String rest;
    if (upper.startsWith('HT2-')) {
      variant = FastMechanismVariant.ht2;
      rest = upper.substring(4);
    } else if (upper.startsWith('HT-')) {
      variant = FastMechanismVariant.ht;
      rest = upper.substring(3);
    } else {
      return null;
    }

    // rest is now "<hash>-<cb>", e.g. "SHA-256-NONE"
    // Channel binding comes last; hash may itself contain "-" (SHA-256, SHA-512).
    final lastDash = rest.lastIndexOf('-');
    if (lastDash < 0) {
      return null;
    }
    final hashPart = rest.substring(0, lastDash);  // e.g. "SHA-256"
    final cbPart = rest.substring(lastDash + 1);   // e.g. "NONE"

    // Only NONE channel-binding is currently supported.
    if (cbPart != 'NONE') {
      Log.w(TAG, 'Unsupported FAST channel-binding: $cbPart');
      return null;
    }

    crypto.Hash? hash;
    switch (hashPart) {
      case 'SHA-256':
        hash = crypto.sha256;
        break;
      case 'SHA-512':
        hash = crypto.sha512;
        break;
      default:
        Log.w(TAG, 'Unsupported FAST hash algorithm: $hashPart');
        return null;
    }

    return FastAuthHandler(
      connection,
      mechanismName,
      variant,
      hash,
      tokenBase64,
    );
  }

  @override
  Future<AuthenticationResult> start() {
    _subscription = _connection.inNonzasStream.listen(_parseAnswer);
    _sendAuthenticate();
    return _completer.future;
  }

  void _sendAuthenticate() {
    final initialResponse = _buildInitialResponse();
    if (initialResponse == null) {
      _fail('Failed to build FAST initial response');
      return;
    }

    final authenticate = Nonza()
      ..name = 'authenticate'
      ..addAttribute(XmppAttribute('xmlns', sasl2Namespace))
      ..addAttribute(XmppAttribute('mechanism', _mechanismName));

    authenticate.addChild(XmppElement()
      ..name = 'initial-response'
      ..textValue = initialResponse);

    if (_connection.account.sasl2SendUserAgent) {
      authenticate.addChild(_buildUserAgentElement());
    }

    // Include Bind 2 inline element if the server advertises it.
    if (_connection.account.useBind2 &&
        _connection.sasl2InlineFeatures.containsKey(bind2Namespace)) {
      authenticate.addChild(_buildBind2Element());
    }

    // Request a fresh FAST token so we stay authenticated on the next
    // reconnection. We ask for the same mechanism we are currently using.
    if (_connection.account.fastEnabled &&
        _connection.sasl2InlineFeatures.containsKey(fastNamespace)) {
      authenticate.addChild(_buildRequestTokenElement());
    }

    _connection.writeNonza(authenticate);
  }

  /// Builds the SASL initial-response payload for the chosen mechanism.
  ///
  /// HT-*:  `authcid || '\x00' || token_bytes`
  /// HT2-*: `HMAC-<hash>(token_bytes, "Initiator")`  (NONE channel-binding)
  String? _buildInitialResponse() {
    final List<int> tokenBytes;
    try {
      tokenBytes = base64.decode(_tokenBase64);
    } catch (e) {
      Log.e(TAG, 'Failed to decode FAST token: $e');
      return null;
    }

    // HT-*:  authcid || NUL || [ extra || NUL ] || initiator_hashed_token  // optional bit is HT2-*
    // authcid is the bare JID (local@domain) per XEP-0484 §4.
    final authcid = '${_connection.account.username}@${_connection.account.domain}';
    final List<int> payload = utf8.encode(authcid) + [0x00];
    // Message is "Initiator" || cbdata [ || extra ]
    final message = utf8.encode('Initiator');
    if (_variant == FastMechanismVariant.ht2) {
      payload.add(0x00); // Empty extra
    }
    payload.addAll(crypto.Hmac(_hash, tokenBytes).convert(message).bytes);
    return CryptoUtils.bytesToBase64(payload, false, false);
  }

  void _parseAnswer(Nonza nonza) {
    if (nonza.getNameSpace() != sasl2Namespace) {
      return;
    }
    switch (nonza.name) {
      case 'success':
        _handleSuccess(nonza);
        break;
      case 'failure':
        _fail(_extractFailureReason(nonza) ?? 'FAST authentication failed');
        break;
      case 'challenge':
        // FAST is single-message; challenges are unexpected.
        _fail('Unexpected SASL challenge during FAST authentication');
        break;
    }
  }

  void _handleSuccess(Nonza nonza) {
    final authorizationIdentifier =
        nonza.getChild('authorization-identifier')?.textValue?.trim();
    if (authorizationIdentifier != null && authorizationIdentifier.isNotEmpty) {
      _connection.setAuthorizationIdentifier(authorizationIdentifier);
    }

    final extensionElements = nonza.children
        .where((element) =>
            element.name != 'authorization-identifier' &&
            element.name != 'additional-data')
        .toList();
    _connection.setSasl2SuccessElements(extensionElements);

    // Extract any new FAST token the server chose to rotate.
    _extractAndStoreFastToken(extensionElements);

    _subscription.cancel();
    _completer.complete(AuthenticationResult(true, ''));
  }

  /// Looks for a `<token xmlns='urn:xmpp:fast:0'>` child in the SASL2
  /// success elements and, if found, stores the new token in the account.
  void _extractAndStoreFastToken(List<XmppElement> elements) {
    for (final el in elements) {
      if (el.getNameSpace() == fastNamespace && el.name == 'token') {
        final token = el.getAttribute('token')?.value;
        final expiry = el.getAttribute('expiry')?.value;
        if (token != null && token.isNotEmpty) {
          _connection.account.storeFastToken(token, expiry);
          Log.d(TAG, 'Stored new FAST token (expiry=$expiry)');
        }
        return;
      }
    }
  }

  String? _extractFailureReason(Nonza nonza) {
    if (nonza.children.isEmpty) {
      return nonza.textValue;
    }
    final first = nonza.children.first;
    return first.name == 'text' ? first.textValue : 'SASL2 ${first.name}';
  }

  void _fail(String message) {
    Log.e(TAG, message);
    // If FAST fails, clear the stored token so the next reconnect falls back
    // to SCRAM rather than retrying with an invalid/expired token.
    _connection.account.clearFastToken();

    if (!_completer.isCompleted) {
      _subscription.cancel();
      _completer.complete(AuthenticationResult(false, message));
    }
  }

  // ---------------------------------------------------------------------------
  // Helper element builders (duplicated from Sasl2AuthHandler for independence)
  // ---------------------------------------------------------------------------

  XmppElement _buildUserAgentElement() {
    final userAgentId =
        _connection.account.sasl2UserAgentId?.trim().isNotEmpty == true
            ? _connection.account.sasl2UserAgentId!.trim()
            : _generateUuidV4();
    final software = (_connection.account.sasl2Software ?? '').trim();
    final device =
        (_connection.account.sasl2Device ?? _connection.account.resource ?? '')
            .trim();
    final element = XmppElement()
      ..name = 'user-agent'
      ..addAttribute(XmppAttribute('id', userAgentId));
    if (software.isNotEmpty) {
      element.addChild(XmppElement()
        ..name = 'software'
        ..textValue = software);
    }
    if (device.isNotEmpty) {
      element.addChild(XmppElement()
        ..name = 'device'
        ..textValue = device);
    }
    return element;
  }

  XmppElement _buildBind2Element() {
    final bind = XmppElement()
      ..name = 'bind'
      ..addAttribute(XmppAttribute('xmlns', bind2Namespace));
    final resource = (_connection.account.resource ?? '').trim();
    if (resource.isNotEmpty) {
      bind.addChild(XmppElement()
        ..name = 'tag'
        ..textValue = resource);
    }
    final bind2Features = _connection.sasl2InlineFeatures[bind2Namespace];
    final bind2Inline = bind2Features?.getChild('inline');
    final bind2FeatureChildren =
        bind2Inline?.children.where((c) => c.name == 'feature') ?? [];
    final serverOffersCarbonsInline = bind2FeatureChildren.any(
      (c) => c.getAttribute('var')?.value == carbons2Namespace,
    );
    if (serverOffersCarbonsInline) {
      bind.addChild(XmppElement()
        ..name = 'enable'
        ..addAttribute(XmppAttribute('xmlns', carbons2Namespace)));
    }
    return bind;
  }

  /// Builds a `<request-token xmlns='urn:xmpp:fast:0' mechanism='HT2-…'/>`
  /// element to ask the server for a fresh FAST token.
  XmppElement _buildRequestTokenElement() {
    final mechanism =
        _connection.account.fastMechanism ?? _mechanismName;
    return XmppElement()
      ..name = 'request-token'
      ..addAttribute(XmppAttribute('xmlns', fastNamespace))
      ..addAttribute(XmppAttribute('mechanism', mechanism));
  }
}

String _generateUuidV4() {
  // Minimal UUID v4 generator (same as in Sasl2AuthHandler).
  final random = List<int>.generate(
      16, (_) => DateTime.now().microsecondsSinceEpoch & 0xff);
  random[6] = (random[6] & 0x0f) | 0x40;
  random[8] = (random[8] & 0x3f) | 0x80;
  final hex =
      random.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
