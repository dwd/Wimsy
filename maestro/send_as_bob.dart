// Connects to the Openfire test server (see maestro/README.md) as the
// "bob" account seeded by maestro/openfire/openfire.xml, sends a single
// chat message to "alice", then disconnects.
//
// This is used to exercise Wimsy's handling of an *incoming* message while
// Alice's app is connected/foregrounded, from the Maestro flows in
// maestro/flows/: run maestro/flows/login_alice.yaml first to get Alice's
// session connected and foregrounded, then run this script, then run
// maestro/flows/receive_message.yaml to assert the message arrived and is
// visible. See maestro/README.md for the full sequence.
//
// Usage (from the repository root, so the "wimsy" package's pubspec/
// package_config can resolve the vendored xmpp_stone dependency):
//   dart run maestro/send_as_bob.dart ["message text"]
//
// Requires, same as the Maestro flows:
//   - The Openfire container is up and healthy (see maestro/README.md).
//   - This script talks to "localhost:15222" directly from the host (the
//     StartTLS port docker-compose.yml publishes), so no `adb reverse` is
//     needed for it specifically - only for the emulator-side flows.
import 'dart:async';
import 'dart:io';

import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

const _host = 'localhost';
const _port = 15222;
const _senderJid = 'bob@localhost';
const _senderPassword = 'bob123';
const _recipientJid = 'alice@localhost';
const _defaultMessage = 'Hello from Bob via Maestro';

Future<void> main(List<String> arguments) async {
  final message = arguments.isNotEmpty ? arguments.first : _defaultMessage;

  final senderJid = xmpp.Jid.fromFullJid(_senderJid);
  final account = xmpp.XmppAccountSettings(
    _senderJid,
    senderJid.local,
    senderJid.domain,
    _senderPassword,
    _port,
    host: _host,
    resource: 'maestro-send-as-bob',
  )
    // Openfire presents a self-signed test certificate on the StartTLS
    // port (see maestro/openfire/openfire.xml); trust it unconditionally
    // since this script only ever talks to the known, local test server.
    ..isCertificateTrusted = (host, port, certificate) => true;

  final connection = xmpp.Connection(account);
  final readyCompleter = Completer<void>();
  late final StreamSubscription<xmpp.XmppConnectionState> subscription;
  subscription = connection.connectionStateStream.listen((state) {
    if (readyCompleter.isCompleted) return;
    if (state == xmpp.XmppConnectionState.Ready) {
      readyCompleter.complete();
    } else if (state == xmpp.XmppConnectionState.Closed ||
        state == xmpp.XmppConnectionState.ForcefullyClosed ||
        state == xmpp.XmppConnectionState.AuthenticationFailure ||
        state == xmpp.XmppConnectionState.StartTlsFailed) {
      readyCompleter.completeError(
        StateError('Connection failed before reaching Ready (state: $state)'),
      );
    }
  });

  connection.connect();

  try {
    await readyCompleter.future.timeout(const Duration(seconds: 20));
    final messageHandler = xmpp.MessageHandler.getInstance(connection);
    messageHandler.sendMessage(xmpp.Jid.fromFullJid(_recipientJid), message);
    // Give the write a moment to flush to the socket before tearing the
    // connection down.
    await Future<void>.delayed(const Duration(seconds: 1));
    stdout.writeln('Sent "$message" from $_senderJid to $_recipientJid.');
  } catch (error) {
    stderr.writeln('Failed to send message as $_senderJid: $error');
    exitCode = 1;
  } finally {
    await subscription.cancel();
    connection.dispose();
  }
  // The xmpp_stone Connection keeps internal timers/listeners alive after
  // dispose(), so explicitly exit rather than relying on the event loop to
  // drain naturally once this function returns.
  exit(exitCode);
}
