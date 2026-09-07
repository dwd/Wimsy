# Message Handling

This document describes how incoming message stanzas flow through the system, how they are routed to specific handlers, and how they turn into visible state changes (messages, reactions, receipts, etc.). It also outlines refactors that would improve reliability and testability.

## 1) Entry Points From The Stream

The primary entry points for message-like traffic are set up in `XmppService` during connection initialization.

- `MessageHandler.getInstance(connection).messagesStream` in `XmppService._setupMessageSignals()`.
  - This is the main pipeline for `MessageStanza` handling.
  - It gates mediated MUC invites first, then forwards all other `MessageStanza` instances to `_handleMessageStanza`.

- `MucManager.roomMessageStream` in `XmppService._setupMuc()`.
  - This is a separate pipeline for MUC groupchat messages. It has its own parsing and persistence logic.

- Jingle/JMI flows (signaling) are routed via Jingle and JMI handlers rather than the generic message handler, but JMI messages are still carried in `MessageStanza` and handled inside `_handleMessageStanza`.

The rest of this document focuses on `MessageHandler.messagesStream` and MUC handling, then summarizes PEP/caps and other message-adjacent pipelines.

## 2) Message Stanza Pipeline (1:1 Chat)

**Location:** `lib/xmpp/xmpp_service.dart`, `_setupMessageSignals()` and `_handleMessageStanza()`.

### 2.1 From Stream to Handler

`_setupMessageSignals()` subscribes to `MessageHandler.messagesStream` and processes each stanza as follows:

1. If the stanza is `null`, it is ignored.
2. A mediated MUC invite is detected first via `parseMucMediatedInvite(stanza)`.
   - If present, `_handleMediatedInvite()` creates a `ChatMessage` that carries the invite details and persists it.
3. Otherwise, the stanza is handed off to `_handleMessageStanza()`.

### 2.2 `_handleMessageStanza` Decision Tree

`_handleMessageStanza` only processes `MessageStanzaType.CHAT`. Anything else is dropped early.

For `MessageStanzaType.CHAT`, the current logic is:

1. **JMI signaling**
   - `parseJmiAction(stanza)`
   - If present, `_handleJmiMessage(...)` is invoked and the stanza is considered handled.

2. **Receipts**
   - `received` receipts: `_extractReceiptsId(...)` → `_applyReceipt(...)`.

3. **Chat markers**
   - `displayed` markers: `_extractMarkerId(..., 'displayed')` → `_applyDisplayed(...)`.

4. **Reactions**
   - `_extractReactionUpdate(...)` → `_applyReactionUpdate(...)`.
   - Target chat is chosen with `_reactionChatTarget(...)` to differentiate between incoming and self-sent reactions.

5. **Content filter**
   - If body and OOB URL are both empty, the stanza is ignored.

6. **Archive / self-message filtering**
   - `_isArchivedStanza(stanza)` is ignored.
   - If sender is the current user bare JID, it is ignored.

7. **Receipt/marker requests (ack/visibility)**
   - A valid stanza id is required.
   - If it requests receipts, `_sendReceipt(...)` is sent.
   - If it is markable, `_sendMarker(..., 'received')` is sent.
   - If the active chat matches, `_sendMarker(..., 'displayed')` is also sent.

### 2.3 Where Messages Are Actually Created

The direct `CHAT` stanza path currently **does not** create a `ChatMessage` for basic text messages in `_handleMessageStanza`. Instead, `ChatMessage` instances are created in other locations:

- **MUC groupchat messages** (roomMessageStream) → `_addRoomMessage(...)`.
- **Mediated MUC invites** → `_handleMediatedInvite(...)` → `_addMessage(...)`.
- **File transfer offers** (Jingle session-initiate for IBB) → `_addFileTransferMessage(...)`.

This is intentional but also means that a plain 1:1 chat body currently only produces receipts/markers, not a stored message, unless another code path handles it.

### 2.4 Message State Updates

Incoming message-related updates that do result in visible changes include:

- `_applyReceipt(...)` and `_applyDisplayed(...)` update status of existing messages.
- `_applyReactionUpdate(...)` updates `ChatMessage.reactions` for matching messages.
- `_applyMessageCorrection(...)` updates message content for edit/replace.

All of these update in-memory lists and call the appropriate persistor (`_messagePersistor` or `_roomMessagePersistor`) and `notifyListeners()`.

## 3) MUC Groupchat Pipeline

**Location:** `lib/xmpp/xmpp_service.dart`, `_setupMuc()`.

For MUC, messages are not processed by `_handleMessageStanza`. Instead, they flow through `MucManager.roomMessageStream` and are handled in the `message` subscription:

- Message corrections with `replaceId` are applied using `_applyRoomMessageCorrection(...)`.
- Reaction updates with a `reactionTargetId` are applied via `_applyRoomReactionUpdate(...)`.
- Otherwise, the message is added as a `ChatMessage` via `_addRoomMessage(...)`.

A self-reflection keeps the message marked as outgoing, but its first receipt
replaces the optimistic local send timestamp with the room event timestamp and
reinserts it into the ordered message list. This puts it after messages received
earlier with the same timestamp, confirms delivery, and persists the corrected
order. Later duplicate reflections can merge metadata without moving the message
again. The room event uses a server delay timestamp when provided, otherwise the
local receive time. Regression coverage is in
`test/room_message_reflection_test.dart` and exercises the service handler used by
the room stream.

Room presence and subject changes are handled by other MUC streams and do not create `ChatMessage` entries (they update room state and presence/occupant state).

## 4) PEP / Caps / Disco Interactions

These are not direct message stanzas but are part of the broader "message-like" flow that affects chat state:

- `PepCapsManager` monitors presence caps (`<c/>`) in presence stanzas, triggers disco#info, and records feature sets.
- `PepManager` uses caps data to request metadata updates.
- Caps are tracked at both bare JID and full JID scope.

This affects features used elsewhere (e.g., determining Jingle support), but is not a direct message processing pipeline.

## 5) Message Persistence and Visibility

- `_messages` stores 1:1 chat messages, keyed by bare JID.
- `_roomMessages` stores MUC messages, keyed by room JID.
- `_messagePersistor` and `_roomMessagePersistor` are invoked after updates to ensure persistence.
- `notifyListeners()` is called when in-memory state changes.

### Where Visible Change Happens

Visible change for the user generally means:

- A `ChatMessage` is added or updated.
- A room state or occupant state changes.
- Jingle/JMI state changes are reflected in the call UI.

If a stanza leads to none of these, the system currently drops it silently.

## 6) Sensible Refactors For Reliability and Testability

Below are changes that would improve reliability, testability, and observability. The aim is: **every message stanza should result in a visible change or a tracked “unhandled” signal.**

### 6.1 Add a Single Message Routing Layer

Introduce a `MessageRouter` or `MessagePipeline` that normalizes all `MessageStanza` inputs into a structured event model (e.g., `IncomingMessageEvent`), and explicitly returns a `HandlingResult` for each stanza:

- `Handled` (e.g., message stored / reaction applied / receipt applied)
- `Ignored` (with reason)
- `Unhandled` (with reason)

This allows logging or surface-level visibility into unhandled content.

### 6.2 Persist “Unhandled Message” Artifacts

Add an “unhandled message” record (or a lightweight telemetry log) that captures:

- `stanza id`, `from`, `type`, `body`, and a short XML snippet.
- Reason for not handling (e.g., "no body and no OOB URL", "archived stanza ignored").

This can appear in a debug view or in logs and aligns with the requirement that every message ordinarily results in a visible change.

### 6.3 Consolidate 1:1 Message Creation

Right now, `CHAT` stanzas do not automatically create a `ChatMessage`. It would improve consistency to add a code path for adding incoming chat messages when:

- It is a `CHAT` stanza.
- It has a body or OOB payload.
- It is not archived or self-sent.

This could sit inside `_handleMessageStanza` after receipt/marker processing and would ensure visible change for ordinary inbound chats.

### 6.4 Make Message Handling Pure and Testable

Refactor `_handleMessageStanza` into a pure function that returns a list of intent-like actions:

- `ApplyReceipt`, `ApplyDisplayed`, `ApplyReaction`, `AddMessage`, `SendReceipt`, `SendMarker`.

Then have a small imperative layer that executes those actions. This makes unit tests straightforward and deterministic.

### 6.5 Track and Surface “No Message-ID” Drops

Currently, stanzas without a `messageId` are dropped. Track these explicitly (e.g., a counter and sample logging), or allow a fallback message key based on stanza-id or time+sender for visibility.

### 6.6 Improve OOB/Correction/Reaction Matching

Consider normalizing and centralizing the “candidate stanza” logic (the repeated traversal of forwarded messages) into a shared helper that returns a normalized `MessagePayload` with fields like `body`, `oob`, `replaceId`, `reactionUpdate`, etc. This reduces duplication and makes parsing consistent across MAM/forwarded messages and direct messages.

### 6.7 Validate MAM vs Live Messages

Currently, `_isArchivedStanza` simply ignores archived messages, while MUC handling uses `mamResultId` for storage. A unified approach would:

- Accept MAM messages but mark them as `archived`, or
- Only ignore them if they already exist in local state.

This prevents silent drops when the stanza only arrives via MAM.

### 6.8 Add a “Message Processing Result” Telemetry Hook

A small, centralized hook such as `onMessageProcessed(result)` could allow UI or logging to show:

- “Message received and stored”
- “Receipt applied”
- “Reaction applied”
- “Ignored: archived”
- “Unhandled: unknown payload”

This provides the observability required for reliability, and makes it easier to add tests around “every message should lead to a visible change.”

## 7) Summary of Current Gaps

- Plain 1:1 chat messages with a body do not appear to be persisted via `_handleMessageStanza`.
- Unhandled or ignored stanzas are silently dropped with no visibility.
- Parsing logic for forwarded stanzas is duplicated across OOB, reactions, and corrections.

The refactors above address these reliability and testability concerns while aligning with the goal that every message results in a visible change or a tracked “unhandled” outcome.
