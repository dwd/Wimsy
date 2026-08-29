import 'package:quiver/core.dart';

class Jid {
  String _local = '';
  String _domain = '';
  String? _resource = '';

  Jid(String local, String domain, String? resource) {
    // XMPP nodeprep/nameprep case mapping makes the localpart and domain
    // case-insensitive. Dart does not currently provide Stringprep/PRECIS,
    // so apply the essential case normalization here. Resources are opaque
    // and case-sensitive and must therefore be preserved verbatim.
    _local = local.toLowerCase();
    _domain = domain.toLowerCase();
    _resource = resource;
  }

  @override
  bool operator ==(other) {
    return other is Jid &&
        local == other.local &&
        domain == other.domain &&
        resource == other.resource;
  }

  String get local => _local;

  String get domain => _domain;

  String? get resource => _resource;

  String? get fullJid {
    if (resource != null &&
        local.isNotEmpty &&
        domain.isNotEmpty &&
        resource!.isNotEmpty) {
      return '$_local@$_domain/$_resource';
    }
    if (local.isEmpty) {
      return _domain;
    }
    if (resource == null || resource!.isEmpty) {
      return '$_local@$_domain';
    }
    return '';
  }

  String get userAtDomain {
    if (local.isNotEmpty) return '$_local@$_domain';
    return _domain;
  }

  bool isValid() {
    return local.isNotEmpty && domain.isNotEmpty;
  }

  static Jid fromFullJid(String fullJid) {
    var exp = RegExp('^(?:([^@/<>\'"]*)@)?([^@/<>\'"]+)(?:/([^<>\'"]*))?\$');
    var match = exp.firstMatch(fullJid);
    if (match != null) {
      return Jid(match.group(1) ?? '', match.group(2) ?? '', match.group(3));
    } else {
      return InvalidJid();
    }
  }

  @override
  int get hashCode {
    return hash3(_local, _domain, _resource);
  }
}

class InvalidJid extends Jid {
  InvalidJid() : super('', '', '');
}
