# Agent Instructions

- When XEP support changes (added/removed/updated), update `doap.xml` to keep the SupportedXep list current.
- Always run tests before any commit that changes code or test configuration:
  - `flutter analyze`, `flutter test`, and the dart tests for vendored dependencies
  - Run Maestro flows against the Android emulator to test end-to-end functionality.
- Always consider the possibility for adding additional tests, both to new and existing code.
- Commit code after each self-contained change, but never push.
  - Prefer multiple commits where changes can be broken down. 
  - In commit messages, use a clear headline but also include a more detailed description, and how the changes were tested. Include details of new tests added.
- When adding new features, ensure they are well-documented with comments and clear variable names. Follow the existing coding style and conventions.
- Once each new session, confirm you've read and will follow these instructions.