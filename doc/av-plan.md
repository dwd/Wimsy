# A/V Calling Implementation Plan (XEP-0479)

This plan targets voice and video calling across all platforms using the XEP-0479 A/V Calling suite as the compliance checklist, and includes a staged path to Muji (XEP-0272) multi-party calls. It covers implementation and testing, with concrete deliverables and sequencing.

## Current Status
- Camera capture is already implemented for avatar updates (XEP-0054 workflow).
- Jingle file transfer over IBB is implemented (XEP-0166 + XEP-0234 + XEP-0261 + XEP-0047).

## Phase 0 — Architecture + Decisions
- Decide signaling flow: Jingle (XEP-0166) for session control + Jingle RTP (XEP-0167) for media.
- Decide Jingle Message Initiation (XEP-0353) usage: use JMI when supported, with IQ fallback.
- Decide transport priority: ICE-UDP (XEP-0176) as primary; no Raw-UDP fallback.
- Choose a WebRTC media stack per platform and expose a uniform abstraction for:
  - local media capture (audio/video)
  - codecs and payload mapping
  - ICE candidates
  - DTLS-SRTP parameters
  - stats and call quality metrics
- Security baseline: DTLS-SRTP (XEP-0320) required for all media.
- WebRTC stack decision: use `flutter_webrtc` across mobile, desktop, and web to provide a consistent MediaDevices/RTC API surface.
- Linux camera access: use the WebRTC camera stack on Linux for A/V and avatars (image_picker does not support ImageSource.camera).

Deliverables:
- Architecture doc outlining signaling flow, media abstraction, and platform-specific choices.
- Decision record: JMI usage and fallback rules.
- Reuse/extend the existing Jingle session flow from file transfer where practical.
- Document Linux camera capture approach and target WebRTC stack.

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
- [x] Jingle RTP description parsing/building (single-content audio or video).
- [x] Discovery/advertising for call support.
- [ ] JMI implementation (message-based invite + IQ fallback).
- [ ] Full session state machine for calls (timeouts, retries, errors).

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
- [x] ICE-UDP and DTLS transport parsing/building scaffolding.
- [x] ICE candidate exchange / trickle transport-info (basic).
- [x] DTLS fingerprint mapping from SDP (basic).
- [ ] STUN/TURN configuration via XEP-0215.

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
- [x] WebRTC media session start/stop scaffold.
- [x] Minimal in-chat call UI (incoming/outgoing/active + accept/decline/hang up).
- [x] Media pipeline (offer/answer + track wiring scaffolded).
- [x] Local preview and remote rendering (minimal).
- [x] Basic media controls (mute/camera toggle).
- [ ] Audio routing and device controls.

## Phase 4 — Advanced A/V (XEP-0479 Advanced Client)
- RTP feedback and header extensions (XEP-0293/XEP-0294) for QoS.
- RTP grouping and SSRC attributes (XEP-0338/XEP-0339) for multi-stream layouts.
- Optional: bandwidth estimation integration and adaptive bitrate.

Deliverables:
- [x] RTP feedback + header extension parsing/building scaffolding.
- [ ] RTP grouping / SSRC attributes.
- [ ] Adaptive bitrate integration.

## Phase 5 — Muji (XEP-0272) Roadmap
- Build multi-party coordination using MUC (XEP-0045) with Muji semantics:
  - join/leave handling
  - per-participant Jingle sessions
  - conference-level state
- Start with mesh P2P for small rooms.
- Plan for MCU/relay integration for larger rooms if needed.

Deliverables:
- [x] Muji session state scaffold.
- [ ] Muji join/leave and signaling coordination.
- [ ] Multi-party UX (participant list, mute states, speaker indication).

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
- When do we implement JMI (XEP-0353) and its fallback rules in production?
- SDP↔Jingle mapping is currently minimal (rtpmap + ICE + fingerprint only). Add full SDP attribute coverage (rtcp-fb, fmtp, extmaps, mid, msid).
- Do we require multi-content Jingle (audio + video in one session) from day one?
- For Muji, is mesh-only acceptable initially, or do we need early MCU/relay support?
