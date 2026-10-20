# Jingle A/V Conferences (SFU) — Feasibility Notes

This is a review of the Goffi `av-conferences` ProtoXEP (draft 0.0.2,
2026-10-13), proposing a Selective Forwarding Unit (SFU) model for
multiparty Jingle calls. A local copy of the spec is kept at
[`doc/xeps/av_conferences.xml`](xeps/av_conferences.xml) for reference since
it is not yet an officially numbered XEP (number is still `xxxx`) and is not
guaranteed to stay reachable at its current URL.

See `doc/av-plan.md` for the existing A/V calling plan (XEP-0479 suite) and
the Muji (XEP-0272) mesh roadmap this spec complements.

## What the spec defines

- A **single Jingle session per participant**, not one session per remote
  peer as in Muji (XEP-0272) mesh calls. A client joins a "room" JID (the
  SFU service) the same way it starts a one-to-one call (XEP-0166/0167),
  sending its own stream(s) with `senders="initiator"`.
- The **SFU service** (not the client, not necessarily the XMPP server
  itself — just some XMPP entity with identity `conference`/`audio-video`)
  forwards other participants' streams into that same session via
  `content-add`, with `senders="responder"`.
- Every `content-add` that carries forwarded media MUST include an
  `<origin xmlns='urn:xmpp:jingle:av-conferences:0' entity='xmpp:user@host'/>`
  sibling of the `<content>` elements, identifying whose stream it is.
  `<origin>` is unauthenticated — the client trusts the SFU for this.
- Contents belonging to the same origin MUST share one BUNDLE group
  (XEP-0338); extra streams (e.g. screen share) can reuse or start a new
  BUNDLE group.
- Leaving/removal is via `content-remove`; a participant leaves by
  terminating its own session.
- Discovery: `urn:xmpp:jingle:av-conferences:0` disco#info feature on both
  clients and the SFU service; the SFU additionally exposes identity
  `category='conference' type='audio-video'`.
- Optional per-room configuration goes through XEP-0050 ad-hoc commands on
  the well-known node `urn:xmpp:av-conferences:config` (the options
  themselves, e.g. recording, are out of scope of this XEP).

## Server-side support required

This XEP is almost entirely a **server/service-side** protocol — the SFU
does the hard work, and the wire protocol toward each client is deliberately
kept close to a normal one-to-one Jingle call. Concretely, something needs
to run as an XMPP entity (a server plugin/component, not necessarily core
server code) that:

1. Accepts a `session-initiate` to a conference/room JID like a one-to-one
   Jingle callee, decodes the offered RTP media, and actually joins the
   underlying media infra (an SFU media engine — e.g. something like
   mediasoup/Janus/LiveKit — terminating ICE/DTLS-SRTP per participant and
   routing RTP between them).
2. Tracks per-room participants and, for each existing participant's
   session, emits `content-add` actions (with the `<origin>` element and a
   BUNDLE `<group>`) whenever a new participant's stream(s) should be
   forwarded to them, and `content-remove` when a participant leaves or a
   stream should stop being forwarded.
3. Never re-delivers a stream back to its own sender (Business Rules), and
   keeps content `name` values unique per session so BUNDLE grouping by
   name stays unambiguous.
4. Advertises disco#info identity `conference`/`audio-video` and feature
   `urn:xmpp:jingle:av-conferences:0` for the room JID (and ideally the
   parent "conference service" JID), so clients can discover it.
5. Optionally exposes an XEP-0050 ad-hoc command at node
   `urn:xmpp:av-conferences:config` for room settings (e.g. recording);
   this part is intentionally left unspecified by the XEP and is
   implementation-defined.

None of this exists yet in any widely deployed server or component — it is
a brand-new service type, comparable in scope to how MUC (XEP-0045) or a
Muji-focalized component would be a self-contained XMPP component rather
than a core server feature. Openfire/Prosody/ejabberd do not ship this out
of the box, and there is currently no known open-source SFU component that
speaks this protocol (the XEP explicitly calls out XEP-0340's MCU/SFU
attempt as unmaintained and unused). For our own end-to-end testing (see
`maestro/README.md`), a real SFU component would have to be written (or
borrowed from Goffi's own reference implementation, if one exists) and
seeded into the Docker-based test environment alongside Openfire; the
existing Maestro flows that only exercise client-to-client Jingle would not
exercise this without such a component.

## Comparison to other multiparty approaches

How `av-conferences` compares to other SFU/MCU designs for multiparty calls,
for context on where it sits in the design space:

### Jitsi: XEP-0340 (COLIBRI) → internal "Colibri2" (not a XEP)

- Jitsi Meet's architecture has three tiers: client ↔ **Jicofo** (the
  "focus", a server-side XMPP component) ↔ **JVB** (the actual SFU media
  engine). Jicofo terminates standard Jingle (XEP-0166/0167) with each
  client, with Jitsi-specific extensions (e.g. `source-name` signaling,
  SSRC rewriting for scale). Separately, Jicofo talks to JVB using
  **COLIBRI** (XEP-0340) — which `av_conferences.xml` itself calls out as
  unmaintained and unused. Jitsi has since moved on to an internal,
  never-published "Colibri2" protocol (XMPP IQ `ConferenceModifyIQ`/
  REST-JSON) used purely between Jicofo and JVB, invisible to clients, with
  cascading/relayed bridges (Octo) and "visitor" endpoints for huge calls.
- **Key difference:** Jitsi never exposes bridge-control semantics to
  third-party clients — a generic XMPP client cannot join a Jitsi SFU
  conference by opening a plain Jingle session, because stream-origin
  tracking and bundle regrouping live entirely inside Jicofo/JVB-specific,
  non-standardized signaling. `av-conferences` puts that exact piece
  (`content-add`/`content-remove` + `<origin>`) into the *client-visible*
  protocol instead, specifically so any Jingle-capable client can
  interoperate with any compliant SFU service — at the cost of not yet
  addressing Jitsi's largest-scale scenarios (cascading, visitors,
  demand-based SSRC rewriting).
- **Focus + SFU fusion:** put another way, `av-conferences` collapses
  Jitsi's two-tier split into a **single XMPP entity** that plays both
  roles. It terminates each participant's `session-initiate` directly (it
  *is* the focus — no separate Jicofo-equivalent delegating elsewhere), and
  the same entity also joins the underlying media infra and does the actual
  ICE/DTLS-SRTP/RTP forwarding (it *is* the SFU — no separate JVB-equivalent
  behind a bridge-control protocol). Because focus and bridge are fused,
  there is no need for anything like COLIBRI/Colibri2 at all — "who gets
  whose stream forwarded" is just internal logic in that one service,
  surfaced to clients only as ordinary `content-add`/`content-remove` +
  `<origin>`. The win is simplicity (no second protocol or Jicofo↔JVB wire
  format to design); the cost is that a single fused entity has no native
  story yet for things Jitsi's split architecture enables precisely because
  it's split — e.g. cascading/relayed bridges (Octo) or visitor-node
  scale-out. As specified today, `av-conferences` is inherently a
  single-bridge, non-cascading design.

### Galène / "In-Band SFU Sessions" (Openfire plugin)

- Architecturally the closest cousin: a native per-participant Jingle
  session straight to the SFU, same shape as `av-conferences`. The Openfire
  Galene plugin bundles the [Galène](https://galene.org) SFU directly and
  exposes it over native XMPP Jingle (ICE/TURN handled by Galène, optional
  MUC-room-backed auth) — but its README states it implements a *different*
  ProtoXEP, Ignite Realtime's "XEP-XXXX: In-Band SFU Sessions", with no
  published spec text found to diff against `av-conferences`. It is not
  wire-compatible with `av-conferences` as published.
- Notably, Galène's author and Goffi have directly discussed this overlap:
  Goffi has already built an XMPP↔Galène bridge — the **"Conferences"
  component in his Libervia project** — that speaks `av-conferences`
  against a Galène backend. That component, not the Openfire plugin, is the
  closest thing to a reference implementation to test interop against.

### ofmeet (Jitsi Videobridge/Jicofo/Jitsi Meet bundle, Openfire plugin)

- Implements **XEP-0483 (HTTP Online Meetings)**: the client asks an HTTP
  endpoint for a meeting URL, and the conference happens inside the bundled
  Jitsi Meet web app using its own Colibri/Colibri2 signaling, not Jingle.
  Adapting it to `av-conferences` would mean discarding the web client and
  Jicofo's signaling entirely and keeping only the bare Jitsi Videobridge —
  at which point it's a brand-new Jingle↔Videobridge bridge, not an
  adaptation. Not a good starting point for this XEP.

### MUJI (XEP-0272) — the "no SFU" baseline

- Pure mesh: every participant opens a one-to-one Jingle session with every
  other participant (O(n²) sessions/streams), coordinated via MUC presence,
  with no new server component required. This is what Wimsy already
  implements (`lib/av/muji_session.dart`). `av-conferences` is meant to
  replace this for larger rooms: one Jingle session per participant instead
  of n−1, at the cost of needing a dedicated SFU service that doesn't exist
  yet for Wimsy to test against.

### mediasoup / LiveKit / BigBlueButton-style SFUs

- These (and most commercial WebRTC SFU stacks) don't use XMPP/Jingle for
  client↔SFU signaling at all — the client talks over a proprietary
  WebSocket + JSON/Protobuf or gRPC channel, with XMPP (if present) only
  used for room bootstrap/chat. This is the opposite design point from
  `av-conferences`, which deliberately reuses Jingle/BUNDLE semantics
  almost unchanged for the SFU leg.

### Implication for Wimsy's server-side testing path

Neither Openfire plugin is a drop-in fit: ofmeet speaks an unrelated
protocol (XEP-0483) and would require discarding nearly everything it does;
the Galene plugin is architecturally right but speaks a different,
non-interoperable ProtoXEP. The more realistic paths to end-to-end testing
are (1) running Goffi's existing Libervia "Conferences" component (which
already speaks `av-conferences` against a Galène backend) alongside our test
server for interop, (2) forking/extending the Openfire Galene plugin to
additionally speak `av-conferences` — feasible since both wrap the same
Galène engine and the hard part (per-participant Jingle session + SFU core)
is already solved there, or (3) a **Focus-only Openfire plugin fronting a
real Jitsi Videobridge (JVB) over Colibri2**: the plugin would terminate
`session-initiate` from clients (playing the "Focus" half described above)
while driving an actual JVB instance for ICE/DTLS-SRTP/RTP forwarding via
JVB's existing `ConferenceModifyIQ`/REST-JSON Colibri2 control channel —
reusing JVB's mature, already-solved SFU media engine instead of writing a
new one or forking Galène. This is architecturally plausible and arguably a
smaller lift than the other two options for the SFU-engine piece, but it
requires a translation layer in the Focus: JVB/Colibri2 multiplexes all
remote SSRCs onto one bundled m-line per client and conveys "whose stream is
this" out-of-band (Jitsi's `source-name`/SSRC-to-owner signaling), whereas
`av-conferences` wants one explicit `<content>` per origin tagged with an
`<origin>` element. The Focus would have to map "JVB says a new SSRC owned
by participant X appeared" to "synthesize a `content-add` with a fresh
content name, reusing/extending the BUNDLE group, with `<origin
entity='X'/>`" (and the reverse on removal) — new code, but a translation
layer on top of working plumbing rather than a new media engine. Caveats:
Colibri2 is unpublished and Jitsi-version-coupled (two layers of unstable
interface risk on top of a still-draft ProtoXEP), and Jitsi's scale features
(Octo cascading, visitor nodes) are themselves built on Jicofo's own
bounded/demand-signaled forwarding model, so they would not carry over for
free without extending `av-conferences` itself (see below).

## Possible extension: demand-signalled, bounded forwarding

Jitsi's Colibri2 model solves a scaling problem for large calls — bounding
and dynamically reselecting which remote sources get forwarded to each
endpoint — via a mechanism that breaks down into:

- **Bounded set of forwarded sources.** Each endpoint negotiates a maximum
  number of video sources it wants delivered at once (e.g. only the
  last-N active speakers, plus whoever is pinned/on-stage), and JVB enforces
  that cap instead of forwarding all N−1 remote videos unconditionally.
- **Demand-driven selection.** The *client* tells Jicofo which sources it
  currently wants (its own non-standardized signaling extension), and
  Jicofo reacts by issuing Colibri2 `ConferenceModifyIQ` messages to JVB to
  start/stop forwarding sources as the client's selection changes — forwarding
  is triggered by the receiver's actual need, not unconditionally by a
  sender joining.
- **SSRC rewriting to keep SDP stable.** Because the forwarded-source set
  changes dynamically but renegotiating SDP on every switch is expensive,
  JVB remaps whichever remote source is currently selected onto one of a
  small, fixed pool of SSRCs/m-lines the client already has set up — so
  swapping who occupies a visible tile doesn't need a fresh
  `content-add`/O-A round-trip, just an internal remap plus a lightweight
  which-source-is-now-which-SSRC signal.
- **Active-speaker/layout awareness and simulcast/SVC layer selection** are
  typically combined on top, so the bridge can proactively swap the
  current speaker into a bounded slot and send lower-resolution layers to
  thumbnails.

All of this lives entirely inside Jicofo's proprietary Jingle extensions and
the internal Colibri2 channel — none of it is a published XEP. On a closer
re-read of `doc/xeps/av_conferences.xml` (not just a paraphrase of it),
though, more of the above turns out to already be legal, spec-compliant
`av-conferences` *policy* than first assumed — the gap is narrower than "the
whole bounded-forwarding concept is out-of-spec."

### What's already possible within the spec as published

- **Selection, not blanket forwarding, is the stated baseline.** `Receiving
  Streams` (`doc/xeps/av_conferences.xml` line 96) says the SFU service
  "selects and delivers" the streams of other participants — not "forwards
  every stream to every participant." The Business Rules section (lines
  290–293) only mandates: never echo a stream back to its own sender, never
  open independent sessions outside the participant's own one, and never let
  content `name`s collide. There is no MUST to forward everything to
  everyone.
- **Reselection over time is a named, intended use case.** Line 101
  explicitly anticipates the SFU changing *which* streams go to a
  participant and tearing the old ones down with `content-remove` "because
  the service changed its selection" — i.e. active-speaker-style reselection
  is baked into plain `content-add`/`content-remove`, not an extension.
- **Bounded ("K slots") forwarding is a pure server-side policy choice.** A
  Focus can legitimately keep only K forwarded contents per participant and
  swap which origin occupies each one via a `content-remove` + `content-add`
  cycle, reusing the content `name` (the Business Rules only require names to
  avoid *collisions*, not to stay bound to one origin forever). This is
  fully conformant today, at the cost of a renegotiation round-trip per
  swap instead of Jitsi's lightweight SSRC remap.
- **Simulcast/quality selection is explicitly spec'd.** Line 92: "A joining
  entity MAY send the same audio or video stream with different quality for
  simulcast purposes. It is up to the SFU service to then select which one
  to forward." This already sanctions the thumbnail-vs-on-stage
  quality-selection behavior from the Jitsi comparison, with zero signaling
  needed.

### What genuinely needs an extension

Only the *signaling* half is actually missing — a way for the client to ask
for a selection, and a way for the Focus to reassign an existing slot's
occupant without a full renegotiation round-trip:

- There is no vocabulary anywhere in the XEP for a participant to express
  *which* sources it wants selected — `content-accept`/`content-reject` only
  let it accept or refuse whatever the service already chose to send, with
  no request/preference mechanism. (The `urn:xmpp:av-conferences:config`
  ad-hoc node is scoped to *room* configuration, e.g. recording, not
  per-participant display preferences, so repurposing it would be a stretch.)
- `<origin>` is scoped to an entire `content-add` action (lines 109–111: "a
  single `<origin>` element identifies the origin of all the contents of the
  action"), so reassigning who owns a slot has no mechanism today other than
  a full `content-remove`/`content-add` round-trip — nothing like
  `description-info`-based per-SSRC origin reassignment exists in the spec.

Addressing just these two pieces (not the whole bounded-forwarding idea)
would require extending `av-conferences` itself, e.g.:

- **Wimsy → Focus ("here are my slots"):** negotiate a small, fixed set of
  "slot" contents up front (e.g. 4 video `<content>`s, or 4 SSRCs within
  fewer bundled contents via XEP-0339 `ssrc`/`ssrc-group`), tagged with a
  semantic role ( "large tile", "thumbnail 1".."thumbnail 3") rather than a
  participant identity, declared once instead of per-origin. This needs new
  vocabulary `av-conferences` doesn't have today — something like a
  `<slot role='...'/>` element alongside a content's `<description>` — and,
  if Wimsy wants to actively request what fills them, a request mechanism
  too ("give me the top-2 active speakers and my pinned contact").
- **Focus → Wimsy ("slot X is now JID Y"):** today's `<origin>` is scoped to
  a whole `<content>`, with no way to say "within this content's SSRC set,
  SSRC 12345 now belongs to JID Y" without tearing the content down and
  re-adding it. XEP-0167's `description-info` action already exists for
  informational RTP-description updates that don't require full
  renegotiation, so an SSRC-scoped `<origin>` (carrying an `ssrc` attribute)
  sent via `description-info` could reassign ownership of one slot without a
  `content-add`/`content-remove` cycle, e.g.:

  ```xml
  <jingle action='description-info' ...>
    <content name='video-slot-2'>
      <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='video'>
        <origin xmlns='urn:xmpp:jingle:av-conferences:0' ssrc='998877' entity='alice@example.com'/>
      </description>
    </content>
  </jingle>
  ```

Together, this would buy the Jitsi-style win (bounded, demand-driven
forwarding) without Jitsi's proprietary Colibri2 channel: slot/SSRC
allocation happens once via ordinary `content-add`, and all the dynamic
"who's in slot 2 now" churn rides on lightweight `description-info` updates
instead of repeated `content-add`/`content-remove` cycles, while staying
entirely inside the client-visible Jingle protocol `av-conferences` already
uses. None of this exists in the `av_conferences.xml` draft 0.0.2 as
fetched — it would need to be proposed back into the ProtoXEP upstream, or
implemented as a Wimsy-specific extension namespace (with the caveat that a
non-standard extension would not interoperate with other `av-conferences`
clients/SFUs that don't know about it).

One axis this slot/SSRC-remap design does **not** need to touch: resolution
and bitrate. Changing what resolution/bitrate an existing SSRC is encoding
at is a pure sender-side codec/RTP-plane decision — no tear-down, no
renegotiation, no `content-modify`/`description-info` round-trip needed, and
no XMPP traffic at all. WebRTC video codecs can change frame dimensions
between keyframes freely as long as payload type/clock rate stay the same;
Wimsy's own adaptive-bitrate code (`lib/xmpp/xmpp_service.dart`, around line
5099) already exercises the equivalent mechanism for bitrate via a local
`RTCRtpSender.setParameters()` call, with zero signaling. This is also the
mechanism behind simulcast layer selection mentioned above: a sender
encodes multiple resolution layers on separate SSRCs (or a single SVC SSRC
carries multiple layers internally), and the SFU picks which to forward —
again a pure media-plane decision. The contrast with the slot/`<origin>`
proposal above is sharp: *who* owns an SSRC needs new signaling (the
receiver can't infer a JID from raw RTP), but *what resolution* an SSRC is
currently encoding at needs none.

## Client-side changes Wimsy would need

Server-side work is the bulk of the effort, but the client is not a no-op
either:

- `xmpp/xmpp_service.dart`'s Jingle action dispatch (`_handleJingleSessionInitiate`,
  `_handleJingleSessionAccept`, `_handleJingleContentModify`, ...) currently
  has **no handling for `content-add` / `content-remove` / `content-accept` /
  `content-reject`** — those Jingle actions aren't in the `JingleAction`
  switch at all today. This is the main code gap: today's call model assumes
  a session's content set is fixed after `session-accept` (aside from
  `content-modify`, which only changes attributes of existing contents).
- Need to parse the `<origin>` element (new namespace
  `urn:xmpp:jingle:av-conferences:0`) and associate it with whichever
  contents arrived in the same `content-add`, so the UI can label/route each
  forwarded stream to the right participant tile — this is the multi-stream
  analogue of the per-peer tracking `lib/av/muji_session.dart` already does
  for Muji.
- The RTP/ICE/DTLS media pipeline needs to support adding/removing
  WebRTC tracks mid-session (content-add/remove), including dynamically
  joining newly added remote tracks into the already-established BUNDLE
  transport (`lib/xmpp/jingle_grouping.dart` already models BUNDLE groups,
  but today only for the initial offer).
- UI: a conference view that can render an arbitrary, changing number of
  remote tiles (one per `<origin>`, potentially several streams per origin
  for camera + screen share), distinct from the current 1:1 and Muji mesh UI.
- Disco: advertise the `urn:xmpp:jingle:av-conferences:0` feature once
  client support lands, and use disco#info on a JID the user calls to detect
  whether it's actually an SFU room (`category='conference'
  type='audio-video'`) versus a one-to-one contact.

## Suggested next steps

1. Treat this as a new phase appended to `doc/av-plan.md` once there is a
   server-side SFU to test against — implementing the client half in
   isolation can't be verified end-to-end without one.
2. Prototype the `content-add`/`content-remove`/`<origin>` handling in
   `xmpp_service.dart` behind the existing Jingle call state machine, reusing
   as much of the one-to-one and Muji code paths as possible.
3. Do not add this to `doap.xml`'s `SupportedXep` list until there is a
   working implementation — it is still a ProtoXEP (number `xxxx`), the
   XML Schema/IANA/Registrar sections are still `TODO`, and no server-side
   counterpart exists to interoperate with yet.
