# Web Support Plan

This document outlines what is required to make Zimpy run in the browser in addition to the existing desktop/mobile targets.

## Transport

XMPP over TCP is not available in browsers. We must support WebSocket transport (XEP‑0206) and configure it per server.

Required work:
- Add WebSocket connection support in the XMPP layer for `dart:html`.
- Ensure StartTLS logic is bypassed for WebSocket mode (TLS is negotiated by WSS at the HTTP layer).
- Configure ws endpoint input (host/path/protocol) in the UI or via SRV‑like defaults.

## xmpp_stone changes

- The existing `XmppWebsocketHtml` implementation is present, but we need:
  - A clean, documented selection of socket type based on `kIsWeb` and account config.
  - Support for `wss://` endpoints (host + path) and optional subprotocols.
  - Verification that the WebSocket path is used correctly in the HTML implementation.
- Ensure XML logging works for WebSocket traffic.
- Make sure `AbstractStanza.toJid` retains resource for MUC join (already fixed for other platforms).

## Flutter Web constraints

- `flutter_secure_storage` is not supported on web. We need a web‑compatible secure store or a graceful fallback.
- Hive web storage uses IndexedDB; encryption is supported but key storage must be handled safely.

Options:
- Use `flutter_secure_storage_web` if it meets requirements (note: storage is not hardware‑backed).
- Use `cryptography` to derive an encryption key from a PIN/password and store only a salt/metadata in IndexedDB or localStorage.

## Authentication & storage

- Web should avoid storing raw XMPP password unless explicitly allowed.
- Provide a “remember me” option that derives the key from a user PIN per session.
- Consider using session storage for sensitive items to avoid persistence.

## UI/UX additions

- Add a server WebSocket endpoint field (wss://host/path).
- Validate the endpoint and show clear errors when the server does not provide WebSocket service.
- Provide a per‑server “use WebSocket” toggle for non‑web targets (useful for testing).

## Testing

Automated:
- Unit tests for WebSocket URL parsing and configuration.
- Smoke test for web build (no runtime errors on startup).
- CI job that runs `flutter test` and a `flutter build web` (or equivalent) to catch regressions.

Manual:
- Connect to a server with WebSocket support.
- Verify login, roster, message send/receive, and MAM sync.
- Verify MUC join/leave over WebSocket.

## CI / Deployment

- Add a CI workflow to build/test the web target on each push/PR.
- Optional: publish web build artifacts for preview (CI artifacts).
- Optional: deploy `build/web` to GitHub Pages on main (or tagged) builds.
  - Use GitHub Actions with a `flutter build web --release` step.
  - Ensure `base-href` is set correctly if hosting under a subpath.
  - Keep secrets-free; deployment should use standard GHA permissions.

## Risks / Open Questions

- Server support varies; some servers do not expose WebSocket endpoints.
- Security posture on web is weaker than native secure storage.
- CORS and reverse-proxy configuration might be required.

## Sequencing

1) Add WebSocket config + connection selection in xmpp_stone.
2) Web-safe storage changes (PIN-derived key + IndexedDB).
3) UI support for ws endpoint and mode.
4) CI for web build/test + optional deploy to GitHub Pages.
5) Web build + manual verification.
