# Agent Instructions

- When XEP support changes (added/removed/updated), update `doap.xml` to keep the SupportedXep list current.
- Always run `flutter analyze`, `flutter test`, and the dart tests for our vendored xmpp_stone before any commit.
- Commit code when it's ready, but never push.
- Always consider the possibility for adding additional tests, both to new and existing code.
- In commit messages, use a clear headline but also include a more detailed description, and how the changes were tested. Include details of new tests added.
- When adding new features, ensure they are well-documented with comments and clear variable names. Follow the existing coding style and conventions.
