import 'package:collection/collection.dart' show IterableExtension;
import 'package:xmpp_stone/src/Connection.dart';
import 'package:xmpp_stone/src/elements/XmppElement.dart';
import 'package:xmpp_stone/src/elements/nonzas/Nonza.dart';
import 'package:xmpp_stone/src/features/Negotiator.dart';
import 'package:xmpp_stone/src/features/sasl/AbstractSaslHandler.dart';
import 'package:xmpp_stone/src/features/sasl/AnonymousHandler.dart';
import 'package:xmpp_stone/src/features/sasl/PlainSaslHandler.dart';
import 'package:xmpp_stone/src/features/sasl/Sasl2AuthHandler.dart';
import 'package:xmpp_stone/src/features/sasl/SaslMechanism.dart';
import 'package:xmpp_stone/src/features/sasl/ScramSaslHandler.dart';

class SaslAuthenticationFeature extends Negotiator {
  static const String sasl1Namespace = 'urn:ietf:params:xml:ns:xmpp-sasl';
  static const String sasl2Namespace = 'urn:xmpp:sasl:2';
  static const String iapNamespace = 'urn:xmpp:iap:0';

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
          _connection
            ..setState(XmppConnectionState.AuthenticatedSasl2AwaitingFeatures);
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

  static void applyIapConfigVersion(Connection connection, Nonza nonza) {
    final scheme = nonza.getAttribute('scheme')?.value?.trim() ?? '';
    final value = nonza.getAttribute('value')?.value?.trim() ??
        (nonza.textValue ?? '').trim();
    if (scheme.isEmpty || value.isEmpty) {
      connection.clearIapConfigVersion();
      return;
    }
    connection.setIapConfigVersion(scheme: scheme, value: value);
  }

  SaslMechanism _handleAuthNotSupported() {
    _connection.setState(XmppConnectionState.AuthenticationNotSupported);
    _connection.close();
    state = NegotiatorState.DONE;
    return SaslMechanism.NOT_SUPPORTED;
  }
}
