# Maestro end-to-end tests

This directory contains everything needed to run [Maestro](https://maestro.mobile.dev/)
UI flows against Wimsy running in an Android emulator, talking to an Openfire
server that starts in a known, reproducible state.

## Layout

```text
maestro/
  openfire/openfire.xml        Openfire "autosetup" config: seeds the server
                                 with two accounts (alice/bob) already in each
                                 other's rosters, using the embedded database.
  openfire/security.xml        Pre-seeded conf/security.xml (see that file for
                                 why this is needed alongside openfire.xml).
  openfire/spiffing-policy.xml  A small, made-up XEP-0258/SPIF security-label
                                 policy, loaded automatically by the Spiffing
                                 plugin on first startup (see "Security label
                                 policy bootstrap" below).
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

Both accounts already have each other in their roster, and `alice@localhost`
also has herself as a second roster item (for self-chat flows, e.g.
`security_label_self_message.yaml`).

### Security label policy bootstrap

The `openfire` service's `OPENFIRE_OPTS` environment variable (see
`docker-compose.yml`) points the bundled Spiffing plugin at
`openfire/spiffing-policy.xml` via the `-Dspiffing.bootstrapPolicyFile=...`
JVM system property. On a fresh install, if no security-label policy has
been configured yet, the plugin loads that file automatically and saves it
as the server's default policy - with a server clearance and default
outgoing-message label both set to the policy's lowest classification
(`PUBLIC`) - so `security_label_self_message.yaml` has a working policy to
exercise without any manual Admin Console setup. It never overrides a
policy that's already configured, so it's a no-op on a volume that's been
reset or reused with its own policy already in place.

`spiffing-policy.xml` is a small example policy written for Wimsy's own
tests (four classifications: `PUBLIC`, `INTERNAL`, `CONFIDENTIAL`,
`SECRET`), not one of the real-world example policies shipped with the
Spiffing plugin/library - see that file's header comment for why.

This bootstrap support (`SpiffingProperties.BOOTSTRAP_POLICY_FILE` /
`SpiffingPlugin.bootstrapPolicyIfConfigured()`) lives in the Spiffing plugin
itself (`~/src/openfire-spiffing-plugin`), not in this repository, so the
`docker.cridland.io/openfire:dwd-deploy` image needs to be rebuilt from an
up-to-date plugin build for it to take effect.

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

## 4. Receiving a message (Bob → Alice)

`receive_message.yaml` doesn't log in by itself - it asserts that a message
sent by `bob@localhost` shows up for Alice while her session is already
connected/foregrounded, so it has to run as the third step of a short
sequence: log Alice in (or reuse an already-connected session), send a
message as Bob from the host with `send_as_bob.dart`, then assert it
arrived:

```sh
maestro test --debug-output .maestro-output maestro/flows/login_alice.yaml
dart run maestro/send_as_bob.dart
maestro test --debug-output .maestro-output maestro/flows/receive_message.yaml
```

`send_as_bob.dart` is a small standalone script (not a Maestro flow) that
connects directly to Openfire as `bob@localhost` using the vendored
`xmpp_stone` package and sends a single chat message to `alice@localhost`,
then disconnects. It talks to `localhost:15222` straight from the host
running `maestro test` (not through the emulator), so it needs the Openfire
container up but no `adb reverse`. It optionally takes the message text as
its first argument (`dart run maestro/send_as_bob.dart "some text"`),
defaulting to `"Hello from Bob via Maestro"` - used by the read/unread
flows below to send a distinct message per scenario. See that file's header
comment for details.

## 5. Checking read/unread state

`receive_message_unread_state.yaml`, `receive_message_while_chat_open.yaml`
and `receive_message_while_app_not_running.yaml` each check the full
read/unread lifecycle of a message from Bob - that it shows up as unread
(except when the chat is already open), that opening the chat marks it
read, and that it stays read across both a "warm" restart (app relaunched,
storage kept) and a "cold" restart (storage wiped, logged back in from
scratch) - for one of the three ways a message can arrive: while the
roster is foregrounded, while Bob's chat is already open, or while the app
isn't running at all. Each needs a specific setup sequence, using the same
helper flows as the CI job (see `.github/workflows/ci.yml`):

```sh
# While the roster is foregrounded:
maestro test --debug-output .maestro-output maestro/flows/login_alice_remember.yaml
dart run maestro/send_as_bob.dart "Read-state check: roster message"
maestro test --debug-output .maestro-output maestro/flows/receive_message_unread_state.yaml

# While Bob's chat is already open:
maestro test --debug-output .maestro-output maestro/flows/open_bob_chat.yaml
dart run maestro/send_as_bob.dart "Read-state check: chat-open message"
maestro test --debug-output .maestro-output maestro/flows/receive_message_while_chat_open.yaml

# While the app isn't running:
maestro test --debug-output .maestro-output maestro/flows/login_alice_remember.yaml
maestro test --debug-output .maestro-output maestro/flows/stop_app.yaml
dart run maestro/send_as_bob.dart "Read-state check: app-not-running message"
maestro test --debug-output .maestro-output maestro/flows/receive_message_while_app_not_running.yaml
```

`login_alice_remember.yaml` is used instead of `login_alice.yaml` for these
flows specifically so that each scenario's warm-restart check can
reconnect with just "Connect" (see `warm_restart_reconnect.yaml`) instead
of retyping the password, which isn't otherwise remembered across restarts.

## 6. Bookmarks surviving a data wipe

`add_bookmark.yaml` and `bookmark_survives_data_wipe.yaml` together verify
that a room bookmark isn't just local app state: it's published to the
user's private PEP bookmarks node (XEP-0402), so it comes back even after
every local trace of it has been wiped. Chain them directly after
`login_alice.yaml`:

```sh
maestro test --debug-output .maestro-output maestro/flows/login_alice.yaml
maestro test --debug-output .maestro-output maestro/flows/add_bookmark.yaml
maestro test --debug-output .maestro-output maestro/flows/bookmark_survives_data_wipe.yaml
```

`add_bookmark.yaml` uses the "New Chat" dialog (Add by JID) to bookmark
`maestro-bookmark@conference.localhost` - Openfire's default conference
service for the `localhost` domain - under the room name
"Maestro Bookmark Room", and asserts it shows up in the roster right away
(bookmarks auto-join by default). `bookmark_survives_data_wipe.yaml` then
force-stops the app, relaunches it with `clearState: true` (wiping all
local storage - a harsher reset than `warm_restart_reconnect.yaml`'s warm
restart), logs back in from scratch, and asserts the same bookmark
reappears and is already joined (its chat opens straight to a usable
message composer, rather than showing an unjoined room with a "Join"
button).

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
- `security_label_self_message.yaml` — logs in as `alice@localhost`, opens a
  self-chat with herself (also pre-seeded in her own roster). First sends a
  message without touching the label picker at all, asserting the server's
  bootstrapped *default* label (see "Security label policy bootstrap" above)
  is still applied and displayed automatically. Then explicitly builds and
  applies a XEP-0258 security label for a different classification and
  sends a second message, asserting that display marking renders correctly
  too.
- `receive_message.yaml` — does *not* `launchApp`; it continues from
  whatever state Alice's app is already in (see "4. Receiving a message"
  above) and asserts that a message sent by `bob@localhost` via
  `send_as_bob.dart` is visible in her chat with Bob.
- `login_alice_remember.yaml` — same as `login_alice.yaml`, but also ticks
  "Remember password on this device" before connecting, so that
  `warm_restart_reconnect.yaml` can reconnect afterwards with just
  "Connect" instead of retyping the password.
- `warm_restart_reconnect.yaml` — a small reusable flow (meant to be
  `runFlow`'d from other flows) that stops and relaunches the app without
  wiping storage, then reconnects by tapping "Connect" again. Requires the
  account to have been logged in via `login_alice_remember.yaml` first.
- `stop_app.yaml` — force-stops Wimsy, simulating the app not running at
  all (as opposed to merely backgrounded), for
  `receive_message_while_app_not_running.yaml`.
- `open_bob_chat.yaml` — does *not* `launchApp`; it continues from
  whatever state Alice's app is already in, taps into her chat with Bob,
  and leaves it open/foregrounded, for
  `receive_message_while_chat_open.yaml`.
- `receive_message_unread_state.yaml`, `receive_message_while_chat_open.yaml`,
  `receive_message_while_app_not_running.yaml` — check the full
  read/unread lifecycle of a message from Bob for each of the three ways it
  can arrive (roster foregrounded, Bob's chat already open, app not
  running), including surviving a warm and a cold restart - see "5.
  Checking read/unread state" above. All three assert the roster's unread
  badge/preview appears *before* the chat is opened, including
  `receive_message_while_app_not_running.yaml`'s message, which arrives
  entirely while the app process is dead.
- `add_bookmark.yaml` — does *not* `launchApp`; it continues from whatever
  state Alice's app is already in (same style as `open_bob_chat.yaml`) and
  adds a room bookmark named "Maestro Bookmark Room" via the "New Chat"
  dialog, for `bookmark_survives_data_wipe.yaml` - see "6. Bookmarks
  surviving a data wipe" above.
- `bookmark_survives_data_wipe.yaml` — force-stops the app, wipes its
  storage, logs back in from scratch, and asserts the bookmark created by
  `add_bookmark.yaml` reappears and is already joined, proving bookmarks
  are durable server-side state rather than cached app state - see "6.
  Bookmarks surviving a data wipe" above.

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
   `login_alice.yaml`, then `dart run maestro/send_as_bob.dart` followed by
   `receive_message.yaml` (see "4. Receiving a message" above, this relies
   on Alice's session still being connected/foregrounded from
   `login_alice.yaml`), then the three read/unread scenarios (see "5.
   Checking read/unread state" above), then `send_message.yaml`,
   `security_label_self_message.yaml`, and the bookmark data-wipe scenario
   (see "6. Bookmarks surviving a data wipe" above) on the emulator.
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
  `message-send-button`, `pin-setup-continue-without-pin-button`,
  `chat-back-button`, `new-chat-button`, `add-by-jid-jid-field`,
  `add-by-jid-nick-field`, `add-by-jid-password-field`,
  `add-by-jid-room-name-field`, `add-by-jid-submit-button`) and a
  matching `Key`. Maestro reads the Semantics tree (not Flutter `Key`s, which
  aren't exposed to it) for its `id:` selectors, while the `Key`s remain for
  the existing Flutter widget tests.
- Unlike `login-connect-button` and the other fields on the login screen,
  the "New Chat" dialog's room/person type toggle (`add-by-jid-type-toggle`)
  auto-selects itself once JID-kind detection finishes (see
  `_AddByJidDialogState`'s discovery callback in `lib/main.dart`) - flows
  should wait for the "Detected: ..." message instead of tapping the
  toggle directly, since `SegmentedButton` deselects on a second tap of an
  already-selected segment.
- Roster entries merge the contact's name, presence and last-message
  preview into a single accessibility node (e.g. `"Bob\noffline"`, or
  `"Bob\noffline\n<preview>"` once there's a message), with the unread
  count appended as a trailing line when there is one (e.g.
  `"Bob\noffline\n<preview>\n1"`) and omitted entirely once read. Maestro's
  text selector requires a full match against that whole node rather than
  a substring, so flows match it with a DOTALL regex (`"(?s)Bob.*"` to just
  find the row, or anchored forms like
  `"(?s)Bob\\n(online|offline)\\n.*<preview>$"` to assert a specific
  read/unread state) instead of plain `"Bob"`.
- Previously, a contact's roster preview/unread badge only populated once
  that contact's chat had been opened at least once, because the MAM
  archive catch-up performed on connect only fanned out to chats that
  already had at least one locally cached message. `XmppService._primeMamSync`
  now also requests an initial archive page for every roster contact with
  no local messages yet, so the badge/preview appears as soon as the
  archive (and any synced MDS read marker) resolves, without requiring the
  chat to be opened first - this is what `receive_message_while_app_not_running.yaml`
  and the other two read/unread scenarios assert.
