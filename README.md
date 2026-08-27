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

The certificate hash is the base64 encoding of the certificate's raw SHA-256
digest. When `WIMSY_DEFAULT_WEBTRANSPORT_URL` is non-empty, it overrides saved
connection URLs and disables host-meta endpoint discovery for that web build.
