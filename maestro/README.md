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
  openfire/security.xml   Pre-seeded conf/security.xml (see that file for why
                           this is needed alongside openfire.xml).
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

Openfire's client-facing ports are published on the host as `localhost:15222`
(StartTLS), `localhost:15223` (Direct TLS, XEP-0368) and `localhost:15224/udp`
(QUIC, XEP-0467) — `docker-compose.yml` deliberately avoids Openfire's
conventional 5222-5224 ports so this stack doesn't collide with unrelated
local services/containers that may already be bound to those well-known
ports. An Android emulator does not share the host's network namespace, so
forward both TCP ports with `adb reverse` once the emulator has booted:

```sh
adb reverse tcp:15222 tcp:15222
adb reverse tcp:15223 tcp:15223
```

With that in place, the Wimsy app running inside the emulator can reach
Openfire by connecting to `localhost:15222`/`localhost:15223` (the domain
configured in `openfire.xml` is still `localhost`; only the port differs).
(If you also want to reach the admin console from the emulator's browser,
add `adb reverse tcp:9090 tcp:9090` as well.)

Openfire's QUIC port (`15224/udp`) is UDP, which `adb reverse` cannot
forward. `login_alice_quic.yaml` instead connects directly to the
emulator's host-loopback alias `10.0.2.2`, which reaches the port published
on the host without any port-forwarding step.

## 3. Install Wimsy and run a flow

Build and install a debug APK, then run a flow with the Maestro CLI
(see https://maestro.mobile.dev/getting-started/installing-maestro for
installation instructions):

```sh
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk

# --debug-output keeps screenshots/logs inside the project directory
# instead of the default ~/.maestro/tests.
maestro test --debug-output .maestro-output maestro/flows/login_alice.yaml
maestro test --debug-output .maestro-output maestro/flows/send_message.yaml
```

## Flows

- `login_alice.yaml` — logs in as `alice@localhost` via the manual-connection
  fields (host `localhost`, port `15222`, StartTLS) and asserts the home
  screen's "Signed in as ..." app bar title is shown. StartTLS presents
  Openfire's self-signed test certificate, so the flow also clicks "Trust"
  on the resulting untrusted-certificate dialog (`certificate-trust-trust-button`).
- `login_alice_directtls.yaml` — same as `login_alice.yaml` but selects
  Direct TLS (XEP-0368) and connects to `localhost:15223`. Requires
  `adb reverse tcp:15223 tcp:15223` (see above).
- `login_alice_quic.yaml` — same as `login_alice.yaml` but selects QUIC
  (XEP-0467) and connects to `10.0.2.2:15224`. Since QUIC has no interactive
  "untrusted certificate" dialog, the flow pins the test server's
  self-signed certificate up front by typing its base64 SHA-256 fingerprint
  into the "Server certificate hash" field (`login-server-certificate-hash-field`).
  If `openfire/openfire.xml`'s keystore ever changes, that fingerprint must
  be regenerated and the flow updated, e.g.:
  ```sh
  openssl s_client -connect localhost:15223 -servername localhost </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 \
    | sed 's/^sha256 Fingerprint=//; s/://g' \
    | xxd -r -p | base64
  ```
  (Direct TLS and QUIC share the same Openfire keystore, so the Direct TLS
  port can be used to read the fingerprint.)
- `send_message.yaml` — logs in as `alice@localhost`, opens the chat with
  `Bob` (pre-seeded in alice's roster) and sends a message, asserting it
  appears in the conversation. Also clicks through the untrusted-certificate
  dialog, same as `login_alice.yaml`.

## Running in CI

These flows run automatically in the `maestro-e2e` job of
`.github/workflows/ci.yml`, on every push and pull request (skipped for
release tags, since those don't build a debug APK). The job:

1. Downloads the debug APK produced by the `build-android` job.
2. Starts Openfire with this directory's `docker-compose.yml` and waits for
   its health check to pass.
3. Boots a hardware-accelerated Android emulator on the GitHub-hosted
   Ubuntu runner (via `reactivecircus/android-emulator-runner`) and installs
   the Maestro CLI.
4. Runs `adb reverse tcp:15222 tcp:15222`, installs the APK, and runs
   `login_alice.yaml` then `send_message.yaml` on the emulator.
5. Tears down the Openfire container (and its volume) afterwards.

To reproduce the CI job locally, follow steps 1-3 above manually (start
Openfire, `adb reverse`, install the APK on your own emulator) and then run
`maestro test maestro/flows/<flow>.yaml` as in step 4.

## Notes

- The manual-connection host/port fields are used instead of relying on SRV
  discovery because the `localhost` domain configured for the test Openfire
  instance does not publish `_xmpp-client._tcp` records.
- The port field pre-fills `5222` by default, so flows must `eraseText`
  before typing into it, or the typed value gets appended to the existing
  one instead of replacing it (e.g. `522215222` instead of `15222`).
- A fresh install always shows a one-time "Set a PIN" screen before login;
  flows tap its `pin-setup-continue-without-pin-button` right after
  `launchApp` to skip it.
- `login_screen.dart` and `main.dart` wrap the relevant widgets in both a
  `Semantics(identifier: ...)` (e.g. `login-jid-field`, `login-password-field`,
  `manual-connection-toggle`, `login-host-field`, `login-port-field`,
  `manual-transport-selector`, `login-server-certificate-hash-field`,
  `login-connect-button`, `certificate-trust-trust-button`,
  `certificate-trust-reject-button`, `message-composer-input`,
  `message-send-button`, `pin-setup-continue-without-pin-button`) and a
  matching `Key`. Maestro reads the Semantics tree (not Flutter `Key`s, which
  aren't exposed to it) for its `id:` selectors, while the `Key`s remain for
  the existing Flutter widget tests.
- Roster entries merge the contact's name and presence into a single
  accessibility node (e.g. `"Bob\noffline"`), and Maestro's text selector
  requires a full match against that whole node rather than a substring.
  `send_message.yaml` therefore matches it with `"(?s)Bob.*"` instead of
  plain `"Bob"`.
