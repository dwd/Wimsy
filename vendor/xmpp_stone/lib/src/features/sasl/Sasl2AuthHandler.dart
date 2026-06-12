import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptoutils/utils.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/sasl/AbstractSaslHandler.dart';
import 'package:xmpp_stone/src/features/sasl/SaslMechanism.dart';

import '../../logger/Log.dart';

class Sasl2AuthHandler implements AbstractSaslHandler {
  static const String TAG = 'Sasl2AuthHandler';
  static const String sasl2Namespace = 'urn:xmpp:sasl:2';
  static const String iapNamespace = 'urn:xmpp:iap:0';
  static const String bind2Namespace = 'urn:xmpp:bind:0';
  static const String carbons2Namespace = 'urn:xmpp:carbons:2';
  static const int clientNonceLength = 48;

  final Connection _connection;
  final String? _password;
  final SaslMechanism _mechanism;
  final String _mechanismString;
  final bool _allowCachedIapConfigVersion;

  late StreamSubscription<Nonza> _subscription;
  final _completer = Completer<AuthenticationResult>();
  _Sasl2State _state = _Sasl2State.initial;

  // SCRAM state
  late Hash _hash;
  late String _clientNonce;
  String? _initialMessage;
  List<int>? _serverSignature;
  bool _retryWithFreshFeatures = false;

  Sasl2AuthHandler(
    this._connection,
    this._password,
    this._mechanism, {
    bool allowCachedIapConfigVersion = false,
  })  : _allowCachedIapConfigVersion = allowCachedIapConfigVersion,
        _mechanismString = _mapMechanism(_mechanism) {
    if (_mechanism == SaslMechanism.SCRAM_SHA_1) {
      _hash = sha1;
    } else if (_mechanism == SaslMechanism.SCRAM_SHA_256) {
      _hash = sha256;
    }
  }

  @override
  Future<AuthenticationResult> start() {
    _subscription = _connection.inNonzasStream.listen(_parseAnswer);
    _sendAuthenticate();
    return _completer.future;
  }

  static String _mapMechanism(SaslMechanism mechanism) {
    switch (mechanism) {
      case SaslMechanism.PLAIN:
        return 'PLAIN';
      case SaslMechanism.SCRAM_SHA_1:
        return 'SCRAM-SHA-1';
      case SaslMechanism.SCRAM_SHA_256:
        return 'SCRAM-SHA-256';
      case SaslMechanism.ANONYMOUS:
        return 'ANONYMOUS';
      default:
        return '';
    }
  }

  void _sendAuthenticate() {
    final authenticate = Nonza()
      ..name = 'authenticate'
      ..addAttribute(XmppAttribute('xmlns', sasl2Namespace))
      ..addAttribute(XmppAttribute('mechanism', _mechanismString));

    final initialResponse = _buildInitialResponse();
    if (initialResponse != null) {
      final initialResponseElement = XmppElement()
        ..name = 'initial-response'
        ..textValue = initialResponse;
      authenticate.addChild(initialResponseElement);
    }

    if (_connection.account.sasl2SendUserAgent) {
      authenticate.addChild(_buildUserAgentElement());
    }
    // Include Bind 2 inline element if the server advertises it and the
    // account has Bind 2 enabled (XEP-0386).
    if (_connection.account.useBind2 &&
        _connection.sasl2InlineFeatures.containsKey(bind2Namespace)) {
      authenticate.addChild(_buildBind2Element());
    }

    if (_connection.account.iapEnabled &&
        _connection.account.iapIncludeConfigVersion &&
        (_connection.iapAdvertisedInCurrentStream ||
            _allowCachedIapConfigVersion) &&
        _connection.iapConfigVersion != null) {
      authenticate.addChild(_connection.iapConfigVersion!);
    }

    _state = _Sasl2State.authSent;
    _connection.writeNonza(authenticate);
  }

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

  /// Builds the Bind 2 inline element for inclusion in the SASL2
  /// <authenticate> stanza (XEP-0386). The <tag> child carries the
  /// requested resource name so the server can use it when assigning the JID.
  /// If the server also advertises carbons as a Bind 2 inline feature, an
  /// <enable xmlns='urn:xmpp:carbons:2'/> child is included so that carbons
  /// are activated atomically with binding, saving a round-trip.
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
    // Request carbons inline if the server advertises it as a Bind 2 feature.
    final bind2Features = _connection.sasl2InlineFeatures[bind2Namespace];
    final bind2FeatureChildren = bind2Features?.children.where((c) => c.name == 'feature') ?? [];
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

  String? _buildInitialResponse() {
    switch (_mechanism) {
      case SaslMechanism.PLAIN:
        final authString =
            '\u0000${_connection.fullJid.local}\u0000${_password ?? ''}';
        return CryptoUtils.bytesToBase64(utf8.encode(authString));
      case SaslMechanism.SCRAM_SHA_1:
      case SaslMechanism.SCRAM_SHA_256:
        _clientNonce = _generateNonce();
        _initialMessage =
            'n=${_saslEscape(_normalize(_connection.fullJid.local))},r=$_clientNonce';
        return CryptoUtils.bytesToBase64(
          utf8.encode('n,,$_initialMessage'),
          false,
          false,
        );
      case SaslMechanism.ANONYMOUS:
        return null;
      default:
        return null;
    }
  }

  void _parseAnswer(Nonza nonza) {
    if (nonza.getNameSpace() != sasl2Namespace) {
      return;
    }
    switch (nonza.name) {
      case 'challenge':
        _handleChallenge(nonza);
        break;
      case 'success':
        _handleSuccess(nonza);
        break;
      case 'failure':
        _fail(_extractFailureReason(nonza) ?? 'SASL2 authentication failed');
        break;
      case 'continue':
        _fail('SASL2 task flow not yet supported');
        break;
    }
  }

  void _handleChallenge(Nonza nonza) {
    if (_state != _Sasl2State.authSent && _state != _Sasl2State.responseSent) {
      _fail('Unexpected SASL2 challenge state');
      return;
    }
    if (_mechanism != SaslMechanism.SCRAM_SHA_1 &&
        _mechanism != SaslMechanism.SCRAM_SHA_256) {
      _fail('Unexpected SASL2 challenge for $_mechanismString');
      return;
    }
    final challenge = nonza.textValue ?? '';
    final responseValue = _scramChallengeFirst(challenge);
    if (responseValue == null) {
      return;
    }
    final response = Nonza()
      ..name = 'response'
      ..addAttribute(XmppAttribute('xmlns', sasl2Namespace))
      ..textValue = responseValue;
    _state = _Sasl2State.responseSent;
    _connection.writeNonza(response);
  }

  void _handleSuccess(Nonza nonza) {
    final authorizationIdentifier =
        nonza.getChild('authorization-identifier')?.textValue?.trim();
    if (authorizationIdentifier != null && authorizationIdentifier.isNotEmpty) {
      _connection.setAuthorizationIdentifier(authorizationIdentifier);
    }

    final additionalData = nonza.getChild('additional-data')?.textValue;
    if (_mechanism == SaslMechanism.SCRAM_SHA_1 ||
        _mechanism == SaslMechanism.SCRAM_SHA_256) {
      if (additionalData == null || additionalData.isEmpty) {
        _fail('Missing SASL2 SCRAM additional-data');
        return;
      }
      if (!_verifyScramServerSignature(additionalData)) {
        return;
      }
    }

    final extensionElements = nonza.children
        .where((element) =>
            element.name != 'authorization-identifier' &&
            element.name != 'additional-data')
        .toList();
    _connection.setSasl2SuccessElements(extensionElements);

    _subscription.cancel();
    _completer.complete(AuthenticationResult(true, ''));
  }

  String? _scramChallengeFirst(String content) {
    final serverFirstMessage = base64.decode(content);
    final tokens = _tokenizeGs2Header(serverFirstMessage);
    var serverNonce = '';
    var iterations = -1;
    var salt = '';
    for (final token in tokens) {
      if (token.length < 3 || token[1] != '=') {
        continue;
      }
      switch (token[0]) {
        case 'i':
          try {
            iterations = int.parse(token.substring(2));
          } catch (_) {
            _fail('Unable to parse iteration count ${token.substring(2)}');
            return null;
          }
          break;
        case 's':
          salt = token.substring(2);
          break;
        case 'r':
          serverNonce = token.substring(2);
          break;
        case 'm':
          _fail('Server sent reserved SCRAM m token');
          return null;
      }
    }
    if (iterations < 0) {
      _fail('No SCRAM iteration count');
      return null;
    }
    if (serverNonce.isEmpty || !serverNonce.startsWith(_clientNonce)) {
      _fail('SCRAM server nonce mismatch');
      return null;
    }
    if (salt.isEmpty) {
      _fail('No SCRAM salt');
      return null;
    }

    final clientFinalMessageBare = 'c=biws,r=$serverNonce';
    final authMessage = utf8.encode(
      '$_initialMessage,${utf8.decode(serverFirstMessage)},$clientFinalMessageBare',
    );
    final saltedPassword = _pbkdf2(
      utf8.encode(_password ?? ''),
      base64.decode(salt),
      iterations,
    );
    final serverKey = _hmac(saltedPassword, utf8.encode('Server Key'));
    final clientKey = _hmac(saltedPassword, utf8.encode('Client Key'));
    final storedKey = _hash.convert(clientKey).bytes;
    _serverSignature = _hmac(serverKey, authMessage);
    final clientSignature = _hmac(storedKey, authMessage);
    final clientProof = List<int>.generate(
      clientKey.length,
      (i) => clientKey[i] ^ clientSignature[i],
    );
    final clientFinalMessage =
        '$clientFinalMessageBare,p=${base64.encode(clientProof)}';
    return base64.encode(utf8.encode(clientFinalMessage));
  }

  bool _verifyScramServerSignature(String additionalData) {
    final signature = _serverSignature;
    if (signature == null) {
      _fail('SCRAM server signature not initialised');
      return false;
    }
    final expected = 'v=${base64.encode(signature)}';
    final received = utf8.decode(base64.decode(additionalData));
    if (received != expected) {
      _fail('SCRAM server final message mismatch');
      return false;
    }
    return true;
  }

  List<int> _hmac(List<int> key, List<int> input) {
    final hmac = crypto.Hmac(_hash, key);
    return hmac.convert(input).bytes;
  }

  List<int> _pbkdf2(List<int> password, List<int> salt, int iterations) {
    var u = _hmac(password, salt + [0, 0, 0, 1]);
    final out = List<int>.from(u);
    for (var i = 1; i < iterations; i++) {
      u = _hmac(password, u);
      for (var j = 0; j < u.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }

  static String _saslEscape(String input) {
    return input.replaceAll('=', '=2C').replaceAll(',', '=3D');
  }

  static String _normalize(String input) {
    return unorm.nfkd(input);
  }

  static List<String> _tokenizeGs2Header(List<int> list) {
    return utf8.decode(list).split(',').map((i) => i.trim()).toList();
  }

  String _generateNonce() {
    final bytes = List<int>.generate(
      clientNonceLength,
      (_) => Random.secure().nextInt(256),
    );
    return base64.encode(bytes);
  }

  String? _extractFailureReason(Nonza nonza) {
    if (nonza.children.isEmpty) {
      return nonza.textValue;
    }
    final iapMismatch = nonza.children.firstWhere(
      (child) =>
          child.name == 'config-version-mismatch' &&
          child.getNameSpace() == iapNamespace,
      orElse: () => XmppElement(),
    );
    if (iapMismatch.name == 'config-version-mismatch') {
      _retryWithFreshFeatures = true;
      return 'IAP config-version mismatch';
    }
    final first = nonza.children.first;
    if (first.name == 'text') {
      return first.textValue;
    }
    return 'SASL2 ${first.name}';
  }

  void _fail(String message) {
    Log.e(TAG, message);
    if (!_completer.isCompleted) {
      _subscription.cancel();
      _completer.complete(
        AuthenticationResult(
          false,
          message,
          retryWithFreshFeatures: _retryWithFreshFeatures,
        ),
      );
    }
  }
}

enum _Sasl2State { initial, authSent, responseSent }

String _generateUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
