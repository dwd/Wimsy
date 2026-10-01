# Wimsy

Wimsy is a cross-platform XMPP client built with Flutter.

It's early days. This was built almost entirely by Codex.

## Platforms

Vaguely tested on:

- Linux
- Windows
- Android
- Web

Builds, but untested on:

- iOS
- macOS

## Features

- Direct TLS (XEP-0368) and StartTLS with SRV discovery
- Stream Management (XEP-0198) with resumable sessions and ack handling
- MAM history sync and paging (XEP-0313 + XEP-0059)
- MUC join/leave + bookmarks (XEP-0045 + XEP-0048/Bookmarks 2)
- Audio/video calling over WebRTC (Jingle XEP-0166/0167 + JMI XEP-0353)
- MUJI group calls (XEP-0272)
- Chat states, receipts, and chat markers (XEP-0085, XEP-0184, XEP-0333)
- Message carbons (XEP-0280)
- Message corrections (XEP-0308)
- Message reactions (XEP-0444)
- Roster versioning (XEP-0237)
- Client State Indication (XEP-0352)
- PEP avatars (XEP-0084) with +notify; vcard-temp fallback (XEP-0054)
- Message Displayed Sync (XEP-0490) for unread tracking and notifications
- Blocking via privacy lists (XEP-0016)
- File transfer via HTTP Upload (XEP-0363) and IBB (XEP-0047)
- XEP-0066 OOB image rendering (partial)
- Presence state + custom status message
- Native notifications for incoming messages (desktop + Android)
- Console protocol traces for send/receive (when enabled)

## Notes

- `xmpp_stone` is vendored locally in `vendor/xmpp_stone` to enforce StartTLS
  and surface XML traffic during debugging.
- macOS builds that use `flutter_secure_storage` require the `keychain-access-groups`
  entitlement (not `com.apple.security.keychain-access-groups`) to avoid `-34018`.

## Linux build dependencies

The WebXDC webview uses WPE WebKit. On Ubuntu 26.04, configure the WPE APT
repository used in `.github/workflows/ci.yml` (or build packages with
`linux/build-wpewebkit.sh`), then install the development dependencies:

```sh
sudo apt-get install libwpewebkit-1.0-dev libwpe-1.0-dev libwpebackend-fdo-1.0-dev libsoup-3.0-dev
pkg-config --print-errors --cflags --libs wpe-webkit-2.0 wpe-1.0 wpebackend-fdo-1.0
flutter build linux --release
```

`pkg-config --list-all` and `--modversion` can report WPE WebKit even when
dependencies listed in its `Requires` field are missing. Use the flags check
above to expose missing development packages behind CMake's "WPE WebKit
development files were not found" error. Older locally built WebKit development
packages do not declare all these dependencies, so install them explicitly.

## Android test login links

Android builds accept login links in either of these forms:

```text
wimsy://login?jid=user%40example.com&password=test123&display_name=Test%20User
https://wimsy.im/login?jid=user%40example.com&password=test123&display_name=Test%20User
```

The link opens Wimsy and fills the JID, password, and display-name fields. The
user must still tap **Connect**. Query parameter values must be URL-encoded.
The web build includes `/open-wimsy.html`, which performs this custom-scheme
handoff from a normal HTTPS URL. A connected web client can generate a
same-origin handoff QR code from **Export login to Android...** in the presence
menu.

## Web deployment defaults

A deployment can pre-fill and enforce its WebTransport endpoint at compile
time without changing the source:

```sh
flutter build web --release --no-web-resources-cdn \
  --dart-define=WIMSY_DEFAULT_JID=user@example.com \
  --dart-define=WIMSY_DEFAULT_WEBTRANSPORT_URL=https://xmpp.example.com/xmpp-webtransport \
  --dart-define=WIMSY_SERVER_CERTIFICATE_HASH=BASE64_SHA256_DIGEST
```

Always pass `--no-web-resources-cdn` when producing a deployable web build.
This packages the Flutter renderer assets with the application instead of
loading them from `www.gstatic.com`, so the deployed application is fully
self-hosted.

For local web deployments, use `tool/build_web.sh` rather than invoking
`flutter build web` directly. It assigns a build ID and creates `update.json`,
which lets already-running and installed clients offer a reload when a newer
build is deployed. An nginx configuration with appropriate cache headers and
SPA routing is provided in `deploy/nginx-wimsy.conf`.

The certificate hash is the base64 encoding of the certificate's raw SHA-256
digest. When `WIMSY_DEFAULT_WEBTRANSPORT_URL` is non-empty, it overrides saved
connection URLs and disables host-meta endpoint discovery for that web build.
