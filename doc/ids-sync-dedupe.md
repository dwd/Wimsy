# Ids, Sync, and Dedupe

## Types of identifier

Note that all ids are scoped by the jid that created them. Therefore,
all ids can be presumed unique within that scope, and ids may also collide
between scopes.

An intentional collision between ids in different scopes could be an
attack if the ids _without scope_ are used to identify a message. This attack
is wholly mitigated by ensuring the scope is also used.

Mostly, the scoping jid is the bare jid of the sender - but there are exceptions.

### XEP-0359 Stanza Id

These are used in a number of cases, but primarily by MAM. We'll
refer to these as the stanza-id within this document.

This gives us a subspecies of id we'll call "mam-id", which is the
XEP-0359 stanza-id scoped by the archive jid.

### Stanza "id" Attribute

This can be considered the primary id scoped by the sender jid.

We'll call this the attr-id within this document.

Of interest is where this is "reflected" by a XEP-0045 chatroom - and
the vast majority of servers do this. A chatroom can advertise
http://jabber.org/protocol/muc#stable_id as a XEP-0030 (disco)
feature, but even if it doesn't this is a relatively safe assumption.

In this case, the reflection will be under the occupant jid, not the sender's.
For reflections of messages, therefore, this is an odd case where the jids do not match exactly,
but we can still treat the messages as identical.

Note that MUC occupants' attr-ids are odd-balls anyway since the scoping jid is the occupant full-jid (so room-jid/nickname).

## Use cases

In all cases, all ids consist of a 2-tuple of (scope-jid, id-string). This is worth repeating!

### Dedupe

If we're given two messages with the same mam-id, they're definitely the same message.

If we're given two messages with the same attr-id, they're almost certainly the same message.

If we're given two messages with the same stanza-id, they're also definitely the same message.

### MAM / Sync

We can only use mam-ids to sync messages from MAM. No other ids can be used here.

