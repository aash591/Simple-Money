# SimpleMoney

An offline-first Android money manager built with Flutter. The app supports
accounts, transactions, budgets, loans, debts, recurring payments, bank SMS
and statement imports, UPI flows, and optional Google Drive backup and restore.

## Development

Run `SetupEnvironment.bat` from the repository root on a fresh Windows machine.
It restores the app and nested SMS parser dependencies as well as the required
development tools. Open this `app/` directory as the Flutter project.

```powershell
flutter pub get
flutter analyze --no-pub
flutter test
flutter run
```

If configuring the SDK manually, also run `dart pub get` in
`packages/universal_bank_sms_parser/engines/dart` before analysis. That package
has its own development dependencies and tests.

## Structure

- `lib/domain/`: money and financial models.
- `lib/data/`: SQLite repositories, imports, backup, and integrations.
- `lib/state/`: application stores and controllers.
- `lib/ui/`: screens, shared components, and themes.
- `test/`: repository, state, and widget tests.

Related files stay together: `data/db/` contains the database, SQL schema,
and profile-only fixtures; `data/agent/` contains tool execution and MCP
schemas; `ui/transactions/` contains the screen and its grouped rows. Their
Dart parts keep the existing public imports and private helpers intact.
Visual tests share `test/preview_fonts.dart` to load the bundled production
fonts consistently.

Amounts are stored as integer minor units. Balance changes and their ledger
entries are committed atomically. Local transaction saves refresh the changed
row; external imports and restore refresh the full transaction store.

## Backup and privacy

Everyday tracking works offline. Optional Drive sync uploads changes to the
hidden application-data folder and can restore a backup after reinstalling or
on a new phone. Concurrent editing across devices and snapshots are not
supported. Drive backup encryption is optional and off by default. Enable it
on the Sync screen with a six-character, case-sensitive letter/number PIN.
Keep the PIN safe: signing in again to restore encrypted data requires it,
and SimpleMoney cannot recover it. Older Drive copies retain their existing
protection. The local SQLite database is not encrypted by this feature.

See the [project guide](../readme/README.md) and
[Drive setup and restore documentation](../readme/GOOGLE_DRIVE_SYNC.md).
