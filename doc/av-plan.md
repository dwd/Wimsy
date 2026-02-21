# A/V Calling Implementation Plan (XEP-0479)

This plan targets voice and video calling across all platforms using the XEP-0479 A/V Calling suite as the compliance checklist, and includes a staged path to Muji (XEP-0272) multi-party calls. It covers implementation and testing, with concrete deliverables and sequencing.

## Current Status
- Camera capture is already implemented for avatar updates (XEP-0054 workflow).
- Jingle file transfer over IBB is implemented (XEP-0166 + XEP-0234 + XEP-0261 + XEP-0047).

## Phase 0 — Architecture + Decisions
- Decide signaling flow: Jingle (XEP-0166) for session control + Jingle RTP (XEP-0167) for media.
- Decide whether to require Jingle Message Initiation (XEP-0353) or use it opportunistically with IQ fallback.
- Decide transport priority: ICE-UDP (XEP-0176) as primary; optional Raw-UDP fallback if needed.
- Choose a WebRTC media stack per platform and expose a uniform abstraction for:
  - local media capture (audio/video)
  - codecs and payload mapping
  - ICE candidates
  - DTLS-SRTP parameters
  - stats and call quality metrics
- Security baseline: DTLS-SRTP (XEP-0320) for all media.

Deliverables:
- Architecture doc outlining signaling flow, media abstraction, and platform-specific choices.
- Decision record: JMI usage and fallback rules.
- Reuse/extend the existing Jingle session flow from file transfer where practical.

## Phase 1 — Core Signaling + Discovery
- Implement Jingle session state machine:
  - session-initiate
  - session-accept
  - session-terminate
  - error handling and timeouts
- Implement Jingle RTP content negotiation:
  - audio and video contents
  - payload types, clock rates, channels
  - codec preferences
- Advertise and discover capabilities with disco#info and caps (XEP-0030/XEP-0115).
- Implement JMI if required/desired:
  - message-based invite
  - fallback to IQ-based Jingle if peer lacks support

Deliverables:
- Jingle session module with full state transitions.
- Discovery/advertising for call support.
- JMI (optional, behind feature flag).

## Phase 2 — Transport + Security
- ICE-UDP transport mapping:
  - candidate generation and exchange
  - connectivity checks and ICE state mapping to Jingle
- External Service Discovery (XEP-0215):
  - fetch STUN/TURN services
  - fallback to static configuration
- DTLS-SRTP (XEP-0320):
  - negotiate fingerprints
  - verify DTLS role
  - bind SRTP to negotiated parameters

Deliverables:
- ICE transport module integrated with Jingle.
- STUN/TURN configuration via XEP-0215.
- DTLS-SRTP negotiation and validation.

## Phase 3 — Media Pipeline + UX
- Audio-only calls first:
  - capture, encode, send/receive
  - audio routing (speaker/earpiece/Bluetooth)
  - echo cancellation and gain control
- Add video:
  - camera capture, encode, send/receive (camera capture already used for avatars; extend for live streams)
  - dynamic resolution/bitrate adaptation
  - UI for local preview and remote video
- In-call UI:
  - ringing/answer/decline
  - mute/unmute audio
  - camera on/off
  - call timer and connection status
- Background/foreground behavior:
  - call persistence
  - notifications for incoming calls
  - platform-appropriate audio focus handling

Deliverables:
- Audio call UI and media flow.
- Video call UI and media flow.
- Cross-platform call UX parity.

## Phase 4 — Advanced A/V (XEP-0479 Advanced Client)
- RTP feedback and header extensions (XEP-0293/XEP-0294) for QoS.
- RTP grouping and SSRC attributes (XEP-0338/XEP-0339) for multi-stream layouts.
- Optional: bandwidth estimation integration and adaptive bitrate.

Deliverables:
- Improved call quality and stability.
- Advanced feature flags for opt-in rollout.

## Phase 5 — Muji (XEP-0272) Roadmap
- Build multi-party coordination using MUC (XEP-0045) with Muji semantics:
  - join/leave handling
  - per-participant Jingle sessions
  - conference-level state
- Start with mesh P2P for small rooms.
- Plan for MCU/relay integration for larger rooms if needed.

Deliverables:
- Muji join/leave and signaling coordination.
- Multi-party UX (participant list, mute states, speaker indication).

## Testing Plan
### Unit Tests
- Jingle stanza parsing/building and state transitions.
- RTP parameter negotiation and codec selection.
- ICE candidate mapping and DTLS fingerprint handling.
- XEP-0215 service discovery parsing.
- JMI invite parsing and fallback logic if enabled.

### Integration Tests
- End-to-end call flows:
  - initiate → accept → terminate
  - decline
  - timeout
  - error paths
- ICE success/failure simulations.
- DTLS-SRTP handshake failure handling.

### Interop Tests
- Test with at least one reference XMPP client that supports Jingle RTP.
- Validate codec negotiation, ICE success, DTLS-SRTP setup, and re-invite flows.

### Platform Tests
- Audio routing tests for each platform.
- Camera switching and background behavior on mobile.
- Desktop audio devices and camera permissions.

## Work Breakdown (Suggested Order)
1) Jingle session state machine + RTP negotiation
2) ICE-UDP transport mapping + candidate exchange
3) DTLS-SRTP negotiation and validation
4) Basic audio-only UI and media flow
5) Video support and UI
6) JMI (if required) and improved discovery logic
7) Advanced RTP features (XEP-0293/0294/0338/0339)
8) Muji roadmap

## Open Questions
- Is JMI (XEP-0353) required for outbound calls or optional with IQ fallback?
- Enforce DTLS-SRTP for all calls, or allow legacy fallback?
- For Muji, is mesh-only acceptable initially, or do we need early MCU/relay support?
