# SimpleMoney

A simple, private, offline-first money manager for Android, built with Flutter.

The idea is small: every transaction answers two questions, kept apart.

- **What was it for?** → Category (Food, Fuel, Bills…)
- **Where did the money come from?** → Account (Cash, bank, card, wallet…)

Food paid from Cash and Food paid from a bank are both just **Food**.
A transfer between your own accounts is not spending.

Adding an expense should take a few seconds: amount, category, account, save.
Everything else stays under "More options".

## What it does

- **Transactions**: expense, income and transfer, with search, filters and history.
- **Accounts and categories**: any currency, reorderable, with 3D category icons and real bank and brand logos.
- **Budgets**: monthly total and per category.
- **Home**: month summary, spending by category, balances, recent items.
- **Debts and loans**: money lent or borrowed, loan EMIs and payoff progress.
- **Recurring payments**: subscriptions, rent, premiums, SIPs, with reminders.
- **Portfolio**: brokers and holdings, with prices.
- **Bank SMS import**: reads bank messages on the phone and queues them for review. Works for any country.
- **Statement import**: map a bank statement's columns once, reuse it.
- **UPI**: scan a QR and record the payment.
- **AI assistant**: Claude, ChatGPT and other MCP apps can look at your data through a relay and *suggest* changes. Nothing changes until you approve it in More › AI assistant. See [relay/](relay/README.md).
- **Community fixes**: SMS formats and statement layouts fixed with the AI can be shared, with no messages, amounts or names in them. See [community/](community/README.md).
- **Backup**: optional Google Drive backup, automatic or manual, and restore on a new phone.
- **Multi-currency**: set a main currency for combined totals. Daily rates are fetched only if you use two or more currencies, and cached rates work offline.
- **Also**: light and dark mode, app lock, export and import, activity log.

## Privacy

No login, no custom backend, data stays on the device. The network is used only for optional Drive backup, exchange rates, price lookups, and the AI session or community sharing when you turn them on.

## Repository layout

| Folder | What it is |
|---|---|
| `app/` | The Flutter Android app (`lib/`, `assets/`, `test/`, `android/`) |
| `app/packages/` | Local packages: `universal_bank_sms_parser`, `drive_authorization` |
| `relay/` | Cloudflare Worker for the AI (MCP) connection |
| `community/` | Cloudflare Worker + D1 for shared SMS and statement fixes |
| `WebDoc/` | Public website and privacy/terms pages |
| `sms/` | SMS restore and collector tools ([RESTORE.md](sms/RESTORE.md)) |
| `readme/` | Icon workflow, ADB over Tailscale notes |
| `assets_raw/`, `icons/` | Source artwork for icons and logos |
| `tool/`, `build.ps1` | Setup and build scripts |

## Get started

On a fresh Windows PC, run `SetupEnvironment.bat` from the repo root. It installs the missing tools in their standard locations and restores all dependencies.

Then:

```sh
cd app
flutter pub get
flutter analyze
flutter test
flutter run
```

In Android Studio, **Run on all Android devices** builds one debug APK and installs it on every connected phone and emulator.

Release builds need `secrets/android/key.properties` and are made from the root:

```sh
build app:play      # bumps the version, builds the Play Store bundle
```

## Code layout (`app/lib/`)

```text
data/      database (Drift/SQLite), repositories, backup, prices, AI tools
domain/    models and business rules
state/     per-feature stores
ui/
  components/   shared widgets (empty state, search, charts…)
  theme/        colors, type, spacing, motion
  home/  transactions/  budgets/  sms/  upi/  welcome/
  more/         everything the More tab opens (accounts, categories,
                debts, loans, recurring, portfolio, ai, settings…)
```

Amounts are stored as integer minor units. Totals are computed in the database, not in memory. Reuse the shared components instead of building one-off versions.

## Stack

Flutter and Dart, Drift (SQLite), shared_preferences, workmanager, Google Drive API, Cloudflare Workers for the relay and community.

Keep dependencies minimal.

## Design

Calm and modern: soft shadows, rounded corners, one accent blue, off-white and charcoal backgrounds, big readable amounts, generous spacing, subtle motion. Light and dark are equally supported.

## Icons and logos

Category icons (soft 3D) and brand/bank logos have a step-by-step workflow in [IconCreationWorkflow.md](readme/IconCreationWorkflow.md).

## Main rule

Prefer simplicity. If a feature makes normal money tracking slower or more confusing, hide it under advanced options.

## License

Licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

You can use, change and share this code. If you distribute it, or run a modified version as a network service, you must publish your full source under the same license. Copyright and license notices must stay.
