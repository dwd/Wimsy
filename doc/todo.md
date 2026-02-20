# TODO list

Agent should pick a single item from this list and proceed with it. If
it can be handled, do so, mark the item done with a tick, and
commit (but do not push) the result. Always test with flutter analyze, flutter test, and dart tests within the xmpp_stone package prior to committing!

* ✓ SM should not be pinging every 5 seconds. Instead, it should ping every 5 minutes, or on network change. However, if there are outstanding unacknowledged stanzas, it should ping within 15 seconds. (So, send a stanza, start a timer for 15 second if one doesn't already exist). If there are unacknowledged received stanzas when sending an </a>, we should unilaterally send the <r/> to acknowledge them at the same time.
* ✓ Implement roster versioning - XEP-0237
* Message editing - XEP-0308
* Message Replies
* Inline images and file attachments. Should do reading then sending.
* Maestro test suite?
* ✓ Client State Indication - XEP-0352 (when client unfocused for some time or explicitly backgrounded)
* Check over MAM and see if it can be optimized. In particular I think recording the last mam-id should allow us to elide or simplify the initial MAM catchup. You may need to update ./doc/mam-sync.md as well.
* ✓ Similar with PEP (particularly with avatars) - we should rely on +notify most of the time, and rarely if ever explciitly subscribe.
* UX refresh - I like the compact nature of the message window now, but the contacts list and header/title bars are quite clunky.
