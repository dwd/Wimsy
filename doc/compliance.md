# XEP-0479 Compliance Shortfalls (Client Focus)

Source requirements: XEP-0479 (Compliance Suites 2023).

This is a client-side gap list for the Core, Web, and IM suites. Items are ordered to reach Client first, then Advanced Client, within each suite. (Server requirements are out of scope.)

## Core Suite

Client: appears met (RFC 6120 core, TLS, XEP-0030, XEP-0115). No shortfalls noted.

Advanced Client: appears met (Direct TLS XEP-0368, PEP XEP-0163). No shortfalls noted.

## Web Suite

Client shortfalls (must also satisfy Core Client):
- None noted.

Advanced Client shortfalls (must also satisfy Core Advanced Client + Web Client):
- No additional items beyond Web Client shortfalls.

Status: Web Client and Advanced Web Client appear met.

## IM Suite

Client shortfalls (must also satisfy Core Client):
- None noted.

Status: IM Client appears met.

Advanced Client shortfalls (must also satisfy IM Client):
- XEP-0398 + XEP-0153 (User Avatar Compatibility) — partial (server-side injection depends on server support; client sends vcard-temp:x:update but does not compute hashes itself).
- XEP-0308 (Last Message Correction).
- XEP-0234 + XEP-0261 (Jingle File Transfer + Jingle IBB transport).

Status: IM Advanced Client is not met until the above are implemented.
