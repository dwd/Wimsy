import 'package:xmpp_stone/xmpp_stone.dart';

const String extDiscoNamespace = 'urn:xmpp:extdisco:2';

class ExternalService {
  const ExternalService({
    required this.type,
    required this.host,
    required this.port,
    required this.transport,
    this.username,
    this.password,
  });

  final String type;
  final String host;
  final int port;
  final String transport;
  final String? username;
  final String? password;

  String toUriString() {
    final scheme = type.toLowerCase();
    final transportPart = transport.isNotEmpty ? '?transport=$transport' : '';
    return '$scheme:$host:$port$transportPart';
  }
}

List<ExternalService> parseExternalServices(XmppElement? servicesElement) {
  if (servicesElement == null ||
      servicesElement.getAttribute('xmlns')?.value != extDiscoNamespace) {
    return const [];
  }
  final result = <ExternalService>[];
  for (final child in servicesElement.children) {
    if (child.name != 'service') {
      continue;
    }
    final type = child.getAttribute('type')?.value ?? '';
    final host = child.getAttribute('host')?.value ?? '';
    final portValue = child.getAttribute('port')?.value ?? '';
    final transport = child.getAttribute('transport')?.value ?? '';
    final port = int.tryParse(portValue) ?? 0;
    if (type.isEmpty || host.isEmpty || port <= 0) {
      continue;
    }
    final username = child.getAttribute('username')?.value;
    final password = child.getAttribute('password')?.value;
    result.add(ExternalService(
      type: type,
      host: host,
      port: port,
      transport: transport,
      username: username,
      password: password,
    ));
  }
  return result;
}
