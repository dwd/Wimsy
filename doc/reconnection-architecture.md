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
