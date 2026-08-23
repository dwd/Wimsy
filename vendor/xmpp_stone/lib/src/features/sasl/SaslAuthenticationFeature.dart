import 'package:collection/collection.dart' show IterableExtension;
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/Negotiator.dart';
import 'package:xmpp_stone/src/features/sasl/AbstractSaslHandler.dart';
import 'package:xmpp_stone/src/features/sasl/AnonymousHandler.dart';
import 'package:xmpp_stone/src/features/sasl/FastAuthHandler.dart';
import 'package:xmpp_stone/src/features/sasl/PlainSaslHandler.dart';
import 'package:xmpp_stone/src/features/sasl/Sasl2AuthHandler.dart';
import 'package:xmpp_stone/src/features/sasl/SaslMechanism.dart';
import 'package:xmpp_stone/src/features/sasl/ScramSaslHandler.dart';

class SaslAuthenticationFeature extends Negotiator {
  static const String sasl1Namespace = 'urn:ietf:params:xml:ns:xmpp-sasl';
  static const String sasl2Namespace = 'urn:xmpp:sasl:2';
  static const String iapNamespace = 'urn:xmpp:iap:0';
  static const String fastNamespace = 'urn:xmpp:fast:0';

  final Connection _connection;
  final String _password;

  final Set<SaslMechanism> _supportedMechanisms = {};
  final Set<SaslMechanism> _offeredSasl1Mechanisms = {};
  final Set<SaslMechanism> _offeredSasl2Mechanisms = {};
  final Map<String, XmppElement> _sasl2InlineFeatures = {};

  SaslAuthenticationFeature(this._connection, this._password) {
    _supportedMechanisms.add(SaslMechanism.SCRAM_SHA_1);
    _supportedMechanisms.add(SaslMechanism.SCRAM_SHA_256);
    _supportedMechanisms.add(SaslMechanism.PLAIN);
    _supportedMechanisms.add(SaslMechanism.ANONYMOUS);
    expectedName = 'SaslAuthenticationFeature';
  }

  @override
  List<Nonza> match(List<Nonza> requests) {
    final out = <Nonza>[];
    final sasl2 = requests.firstWhereOrNull(
      (element) =>
          element.name == 'authentication' &&
          element.getNameSpace() == sasl2Namespace,
    );
    if (sasl2 != null) {
      out.add(sasl2);
    }
    final sasl1 = requests.firstWhereOrNull(
      (element) =>
          element.name == 'mechanisms' &&
          element.getNameSpace() == sasl1Namespace,
    );
    if (sasl1 != null) {
      out.add(sasl1);
    }
    final iapConfigVersion = requests.firstWhereOrNull(
      (element) =>
          element.name == 'config-version' &&
          element.getNameSpace() == iapNamespace,
    );
    if (iapConfigVersion != null) {
      out.add(iapConfigVersion);
    }
    return out;
  }

  @override
  void negotiate(List<Nonza> nonzas) {
    if (nonzas.isEmpty) {
      return;
    }
    _offeredSasl1Mechanisms.clear();
    _offeredSasl2Mechanisms.clear();
    _sasl2InlineFeatures.clear();

    for (final nonza in nonzas) {
      if (nonza.name == 'authentication' &&
          nonza.getNameSpace() == sasl2Namespace) {
        _connection.account.sasl2CachedMechanisms = parseMechanismNames(nonza);
        _offeredSasl2Mechanisms.addAll(parseMechanisms(nonza));
        _sasl2InlineFeatures.addAll(parseInlineFeatures(nonza));
        cacheInlineFeatureNames(_connection, _sasl2InlineFeatures);
      } else if (nonza.name == 'mechanisms' &&
          nonza.getNameSpace() == sasl1Namespace) {
        _offeredSasl1Mechanisms.addAll(parseMechanisms(nonza));
      } else if (nonza.name == 'config-version' &&
          nonza.getNameSpace() == iapNamespace) {
        applyIapConfigVersion(_connection, nonza);
      }
    }

    if (_connection.sasl2PipelinedAuthInFlight) {
      return;
    }

    _connection.setSasl2InlineFeatures(_sasl2InlineFeatures);
    _process();
  }

  void _process() {
    // Attempt FAST authentication (XEP-0484) if we have a stored token and the
    // server offers the matching mechanism inside the SASL2 <fast> feature.
    final fastHandler = _tryCreateFastHandler();
    if (fastHandler != null) {
      state = NegotiatorState.NEGOTIATING;
      fastHandler.start().then((result) {
        if (result.successful) {
          _connection.completeSasl2Authentication();
          state = NegotiatorState.DONE;
          return;
        }
        // FAST failed (expired / invalid / revoked token). The handler has
        // already cleared the stored token, so rather than dropping the
        // connection we simply retry authentication on the same stream with
        // the regular password-based mechanism (SCRAM). XEP-0388 allows a
        // client to send another <authenticate/> after a <failure/>.
        print('XMPP FAST: authentication failed (${result.message}); '
            'falling back to password authentication');
        _processPasswordSasl();
      });
      return;
    }

    _processPasswordSasl();
  }

  /// Runs the regular password-based SASL flow (SASL2 when available and
  /// preferred, otherwise SASL1), picking the best mechanism offered by the
  /// server. This is also the fallback path when FAST authentication fails.
  void _processPasswordSasl() {
    var useSasl2 = _shouldUseSasl2();
    var offered = useSasl2 ? _offeredSasl2Mechanisms : _offeredSasl1Mechanisms;
    var mechanism = _pickSupportedMechanism(offered);
    if (mechanism == SaslMechanism.NOT_SUPPORTED && useSasl2) {
      // Fallback before handshake if SASL2 has no supported mechanism.
      useSasl2 = false;
      offered = _offeredSasl1Mechanisms;
      mechanism = _pickSupportedMechanism(offered);
    }
    if (mechanism == SaslMechanism.NOT_SUPPORTED) {
      _handleAuthNotSupported();
      return;
    }
    print(
      'XMPP SASL: profile=${useSasl2 ? 'sasl2' : 'sasl1'} selected $mechanism '
      '(offered=$offered)',
    );
    if (useSasl2) {
      _connection.account.sasl2LastMechanism = mechanismToWireName(mechanism);
    }

    final saslHandler = _createHandler(mechanism, useSasl2);
    if (saslHandler == null) {
      _handleAuthNotSupported();
      return;
    }

    state = NegotiatorState.NEGOTIATING;
    saslHandler.start().then((result) {
      if (result.successful) {
        if (useSasl2) {
          _connection.completeSasl2Authentication();
        } else {
          _connection.setState(XmppConnectionState.Authenticated);
        }
      } else {
        _connection.setState(XmppConnectionState.AuthenticationFailure);
        _connection.errorMessage = result.message;
        _connection.close();
      }
      state = NegotiatorState.DONE;
    });
  }

  /// Returns a [FastAuthHandler] ready to use if all conditions are met:
  ///   - FAST is enabled in the account,
  ///   - A valid non-expired token is stored,
  ///   - The server is advertising SASL2 with a `<fast>` inline feature,
  ///   - The stored mechanism name is offered by the server.
  FastAuthHandler? _tryCreateFastHandler() {
    final account = _connection.account;
    if (!account.fastEnabled) return null;

    final token = account.fastToken;
    if (token == null || token.isEmpty) return null;

    // Check token expiry if present.
    final expiryStr = account.fastTokenExpiry;
    if (expiryStr != null && expiryStr.isNotEmpty) {
      try {
        final expiry = DateTime.parse(expiryStr);
        if (DateTime.now().isAfter(expiry)) {
          // Token has expired; clear it and fall back to SCRAM.
          account.clearFastToken();
          return null;
        }
      } catch (_) {
        // Unparseable expiry; ignore and continue.
      }
    }

    // Need SASL2 and the server to offer a <fast> inline feature.
    if (_offeredSasl2Mechanisms.isEmpty) return null;
    final fastFeature = _sasl2InlineFeatures[fastNamespace];
    if (fastFeature == null) return null;

    // Find a mechanism that both we support and the server lists in <fast>.
    final fastMechanismName = account.fastMechanism;
    if (fastMechanismName == null || fastMechanismName.isEmpty) return null;
    // HT2 is intentionally not negotiated yet. Existing cached HT2 tokens
    // are discarded so the next password authentication requests HT instead.
    if (fastMechanismName.startsWith('HT2-')) {
      account.clearFastToken();
      return null;
    }

    // Verify the server still offers this specific mechanism.
    final offeredMechanisms = fastFeature.children
        .where((c) => c.name == 'mechanism')
        .map((c) => (c.textValue ?? '').trim())
        .where((m) => m.isNotEmpty)
        .toSet();
    if (!offeredMechanisms.contains(fastMechanismName)) {
      // The server no longer offers the stored mechanism; clear the whole
      // credential set (including any persisted copy) and fall back.
      account.clearFastToken();
      return null;
    }

    print('XMPP FAST: attempting $fastMechanismName');
    return FastAuthHandler.fromMechanismName(
      _connection,
      fastMechanismName,
      token,
    );
  }

  bool _shouldUseSasl2() {
    final hasSasl2 = _offeredSasl2Mechanisms.isNotEmpty;
    final hasSasl1 = _offeredSasl1Mechanisms.isNotEmpty;
    if (!hasSasl2 && !hasSasl1) {
      return false;
    }
    if (hasSasl2 && !hasSasl1) {
      return true;
    }
    if (!hasSasl2 && hasSasl1) {
      return false;
    }
    return _connection.account.preferSasl2;
  }

  AbstractSaslHandler? _createHandler(SaslMechanism mechanism, bool useSasl2) {
    if (mechanism == SaslMechanism.NOT_SUPPORTED) {
      return null;
    }
    if (useSasl2) {
      return Sasl2AuthHandler(_connection, _password, mechanism);
    }
    switch (mechanism) {
      case SaslMechanism.PLAIN:
        return PlainSaslHandler(_connection, _password);
      case SaslMechanism.SCRAM_SHA_256:
      case SaslMechanism.SCRAM_SHA_1:
        return ScramSaslHandler(_connection, _password, mechanism);
      case SaslMechanism.ANONYMOUS:
        return AnonymousHandler(_connection, mechanism);
      default:
        return null;
    }
  }

  SaslMechanism _pickSupportedMechanism(Set<SaslMechanism> offered) {
    return _supportedMechanisms.firstWhere(
      (mch) => offered.contains(mch),
      orElse: () => SaslMechanism.NOT_SUPPORTED,
    );
  }

  static Set<SaslMechanism> parseMechanisms(Nonza nonza) {
    final offered = <SaslMechanism>{};
    nonza.children
        .where((element) => element.name == 'mechanism')
        .forEach((mechanism) {
      switch (mechanism.textValue) {
        case 'EXTERNAL':
          offered.add(SaslMechanism.EXTERNAL);
          break;
        case 'SCRAM-SHA-1-PLUS':
          offered.add(SaslMechanism.SCRAM_SHA_1_PLUS);
          break;
        case 'SCRAM-SHA-256':
          offered.add(SaslMechanism.SCRAM_SHA_256);
          break;
        case 'SCRAM-SHA-1':
          offered.add(SaslMechanism.SCRAM_SHA_1);
          break;
        case 'ANONYMOUS':
          offered.add(SaslMechanism.ANONYMOUS);
          break;
        case 'PLAIN':
          offered.add(SaslMechanism.PLAIN);
          break;
      }
    });
    return offered;
  }

  static List<String> parseMechanismNames(Nonza nonza) {
    return nonza.children
        .where((element) => element.name == 'mechanism')
        .map((element) => (element.textValue ?? '').trim())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  static String? mechanismToWireName(SaslMechanism mechanism) {
    switch (mechanism) {
      case SaslMechanism.PLAIN:
        return 'PLAIN';
      case SaslMechanism.SCRAM_SHA_1:
        return 'SCRAM-SHA-1';
      case SaslMechanism.SCRAM_SHA_256:
        return 'SCRAM-SHA-256';
      case SaslMechanism.ANONYMOUS:
        return 'ANONYMOUS';
      case SaslMechanism.EXTERNAL:
        return 'EXTERNAL';
      case SaslMechanism.SCRAM_SHA_1_PLUS:
        return 'SCRAM-SHA-1-PLUS';
      case SaslMechanism.NOT_SUPPORTED:
        return null;
    }
  }

  static SaslMechanism? mechanismFromWireName(String? wireName) {
    switch (wireName) {
      case 'PLAIN':
        return SaslMechanism.PLAIN;
      case 'SCRAM-SHA-1':
        return SaslMechanism.SCRAM_SHA_1;
      case 'SCRAM-SHA-256':
        return SaslMechanism.SCRAM_SHA_256;
      case 'ANONYMOUS':
        return SaslMechanism.ANONYMOUS;
      case 'EXTERNAL':
        return SaslMechanism.EXTERNAL;
      case 'SCRAM-SHA-1-PLUS':
        return SaslMechanism.SCRAM_SHA_1_PLUS;
      default:
        return null;
    }
  }

  static Map<String, XmppElement> parseInlineFeatures(Nonza authentication) {
    final parsed = <String, XmppElement>{};
    final inline = authentication.getChild('inline');
    if (inline == null) {
      return parsed;
    }
    for (final child in inline.children) {
      final key = (child.getNameSpace() ?? '').isNotEmpty
          ? child.getNameSpace()!
          : child.name ?? '';
      if (key.isEmpty) {
        continue;
      }
      parsed[key] = child;
    }
    return parsed;
  }

  static void cacheInlineFeatureNames(
    Connection connection,
    Map<String, XmppElement> features,
  ) {
    final bind = features['urn:xmpp:bind:0'];
    connection.account.sasl2CachedBind2Features = bind == null
        ? null
        : bind
                .getChild('inline')
                ?.children
                .where((child) => child.name == 'feature')
                .map((child) => child.getAttribute('var')?.value ?? '')
                .where((value) => value.isNotEmpty)
                .toList() ??
            <String>[];
    final fast = features[fastNamespace];
    connection.account.sasl2CachedFastMechanisms = fast == null
        ? null
        : fast.children
            .where((child) => child.name == 'mechanism')
            .map((child) => (child.textValue ?? '').trim())
            .where((value) => value.isNotEmpty)
            .toList();
  }

  static void applyIapConfigVersion(Connection connection, Nonza nonza) {
    final scheme = nonza.getAttribute('scheme')?.value?.trim() ?? '';
    final value = nonza.getAttribute('value')?.value?.trim() ??
        (nonza.textValue ?? '').trim();
    if (value.isEmpty) {
      connection.clearIapConfigVersion();
      return;
    }
    connection.setIapConfigVersion(
      scheme: scheme.isEmpty ? null : scheme,
      value: value,
    );
  }

  SaslMechanism _handleAuthNotSupported() {
    _connection.setState(XmppConnectionState.AuthenticationNotSupported);
    _connection.close();
    state = NegotiatorState.DONE;
    return SaslMechanism.NOT_SUPPORTED;
  }
}
