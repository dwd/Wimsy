# Maestro end-to-end tests

This directory contains everything needed to run [Maestro](https://maestro.mobile.dev/)
UI flows against Wimsy running in an Android emulator, talking to an Openfire
server that starts in a known, reproducible state.

## Layout

```text
maestro/
  openfire/openfire.xml   Openfire "autosetup" config: seeds the server with
                           two accounts (alice/bob) already in each other's
                           rosters, using the embedded database.
  docker-compose.yml       Brings up that Openfire instance in a container.
  flows/                    Maestro flow YAML files.
```

## 1. Start Openfire in a known state

```sh
cd maestro
docker compose up -d
```

The `openfire-seed` service copies `openfire/openfire.xml` into the
`openfire-data` volume only if it isn't already there, so the server is
auto-configured exactly once per fresh volume. Wait for the container to
report healthy before running any flows:

```sh
docker compose ps
# "openfire" should show (healthy)
```

To fully reset the server state (e.g. after changing `openfire.xml`, or to
get back to a pristine state between test runs):

```sh
docker compose down -v
docker compose up -d
```

Seeded accounts (domain `localhost`, see `openfire/openfire.xml`):

| JID              | Password  |
|------------------|-----------|
| alice@localhost  | alice123  |
| bob@localhost    | bob123    |

Both accounts already have each other in their roster.

## 2. Point the emulator at Openfire

Openfire's XMPP port is published on the host as `localhost:5222`. An Android
emulator does not share the host's network namespace, so forward the port
with `adb reverse` once the emulator has booted:

```sh
adb reverse tcp:5222 tcp:5222
```

With that in place, the Wimsy app running inside the emulator can reach
Openfire by connecting to `localhost:5222`, matching the domain configured
in `openfire.xml`. (If you also want to reach the admin console from the
emulator's browser, add `adb reverse tcp:9090 tcp:9090` as well.)

## 3. Install Wimsy and run a flow

Build and install a debug APK, then run a flow with the Maestro CLI
(see https://maestro.mobile.dev/getting-started/installing-maestro for
installation instructions):

```sh
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk

maestro test maestro/flows/login_alice.yaml
maestro test maestro/flows/send_message.yaml
```

## Flows

- `login_alice.yaml` — logs in as `alice@localhost` via the manual-connection
  fields (host `localhost`, port `5222`) and asserts the home screen's
  "Signed in as ..." app bar title is shown.
- `send_message.yaml` — logs in as `alice@localhost`, opens the chat with
  `Bob` (pre-seeded in alice's roster) and sends a message, asserting it
  appears in the conversation.

## Notes

- The manual-connection host/port fields are used instead of relying on SRV
  discovery because the `localhost` domain configured for the test Openfire
  instance does not publish `_xmpp-client._tcp` records.
- `login_screen.dart` and `main.dart` expose stable widget keys (e.g.
  `login-jid-field`, `login-password-field`, `manual-connection-toggle`,
  `login-host-field`, `login-port-field`, `login-connect-button`,
  `message-composer-input`, `message-send-button`) specifically so Maestro
  flows can target them with `id:` selectors instead of brittle text
  matching.
