# Reconnection Architecture Contract

## Scope
This document defines ownership boundaries for reconnection after consolidating reconnect behavior into `xmpp_stone`.

## Ownership
- `xmpp_stone` is the single owner of:
  - reconnect scheduling and retry timers
  - resume-first behavior (XEP-0198)
  - retry backoff, cap, and jitter
  - reconnect state transitions
- `xmpp_service` is responsible for:
  - supplying runtime context (`networkOnline`, app policy, explicit user disconnect)
  - projecting reconnect state to UI/status
  - explicit user-driven `connect()` and `disconnect()` entry points

## Trigger Model
All reconnect-worthy events must flow through one reconnect controller path in `xmpp_stone`.

Recoverable triggers:
- forceful transport close
- keepalive timeout
- stream-level recoverable error
- network transition from offline to online

Terminal stop triggers:
- authentication failure
- authentication not supported

## Policy
- auto reconnect is enabled in foreground and background
- retries are unbounded
- backoff cap is 10 minutes
- jitter is approximately ±25%
- network offline suspends scheduled retries
- network offline -> online triggers immediate retry

## Invariants
- exactly one reconnect scheduler timer may be active at a time
- duplicate reconnect triggers must deduplicate while a reconnect is already scheduled
- explicit user disconnect must prevent auto-reconnect
- reconnect reason and delay should be observable via reconnect state reporting

## Hard reset after failed acquisition

Ordinary transport loss still uses the library's resume-first reconnect path.
When all endpoints fail, negotiation fails, or the login deadline expires,
`XmppService` disposes the connection and schedules a new login using the saved
attempt parameters. This recovery boundary discards DNS/SRV answers, refresh
work, endpoint health, stream state, IAP negotiation hints, and library singleton
instances. Generation
checks prevent cancelled discovery and transport results from reviving an old
attempt or repopulating a cleared DNS cache. Network changes also invalidate DNS.

On Android, reset awaits foreground-service shutdown. Automatic recovery then
starts a fresh service before the retry delay; platform start/stop operations are serialized. The foreground
service does not own the XMPP connection, so service restart alone is insufficient.
Stop and Exit perform the same reset without scheduling a retry, and Exit awaits
cleanup before closing the application window.

The login screen's **Connection recovery → Empty Cache & Retry** also removes
cached messages, roster, bookmarks, avatars, capabilities, FAST tokens, and IAP
negotiation hints. It retains saved account settings and passwords and retries
with the current form values. **Clear Cache & Exit** uses the same cache reset.
Automatic recovery and ordinary Stop/Exit preserve cached chat history.
