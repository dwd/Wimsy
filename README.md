# Wimsy

Wimsy is a cross-platform XMPP client built with Flutter, focused on modern
server support and TLS-first connections.

## Features

- Connect to modern XMPP servers over StartTLS
- Login with full JID + resource
- Roster sync and manual JID chat creation
- One-to-one chat view with message history per contact
- Basic presence announcement on connect
- Console protocol traces for send/receive (when enabled)

## Platform Support

- Linux, macOS, Windows, Android, iOS
- Web is not supported (socket transport is required)

## Notes

- `xmpp_stone` is vendored locally in `vendor/xmpp_stone` to enforce StartTLS
  and surface XML traffic during debugging.
- macOS builds that use `flutter_secure_storage` require the `keychain-access-groups`
  entitlement (not `com.apple.security.keychain-access-groups`) to avoid `-34018`.
