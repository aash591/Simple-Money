# SimpleMoney

**A free, private expense manager and budget planner for Android. No account, works offline, and your data stays on your phone.**

[Get it on Google Play](https://play.google.com/store/apps/details?id=com.aash591.SimpleMoney) · [Website and guides](https://simplemoney.aashglobal.in) · [Privacy policy](https://simplemoney.aashglobal.in/privacy)

SimpleMoney is built around one small idea. Every transaction answers two questions, and the app keeps them apart:

- **What was it for?** That is the **category** (Food, Fuel, Bills…).
- **Where did the money come from?** That is the **account** (Cash, bank, card, wallet…).

Food paid from Cash and Food paid from a bank are both just **Food**. Moving money between your own accounts is a transfer, not spending.

Adding an expense takes a few seconds: amount, category, account, save. Everything else waits under "More options".

## What you can do

### Track
- Record **expenses, income and transfers**, then search, filter and browse the history.
- Keep any number of **accounts** in any currency: cash, bank, card, wallet or a broker.
- Organize with **categories** and sub-categories, with soft 3D icons and real bank and brand logos.
- Set a **monthly budget**, overall and per category, and see how much is left.
- Read the **Home** screen at a glance: this month's summary, spending by category, balances and recent items. Arrange it your way.
- Use **multiple currencies** with a main currency for combined totals. Exchange rates are fetched only if you actually use two or more currencies, and cached rates work offline.

### Stop typing it in
- **Bank SMS import.** SimpleMoney reads your bank messages on the phone and queues them for you to review. It is built to work for any country, with ready-made rules for India, the UK, the USA, UAE, Saudi Arabia, Germany, France, Turkey, Nigeria, Kenya, Pakistan, Bangladesh, Sri Lanka, Thailand and more. Messages are read on the device and never uploaded.
- **Teach it a new bank.** If your bank's message isn't recognised, mark the amount, account and merchant once and the app learns the format.
- **Statement import.** Open a bank or UPI statement (PDF or file), map its columns once, and reuse the layout next time.
- **UPI.** Scan a QR code and record the payment.

### Know where you stand
- **Debts.** Track money you lent or borrowed, person by person.
- **Loans.** See EMIs, what you have paid and how close you are to being done.
- **Recurring payments.** Subscriptions, rent, premiums and SIPs, with reminders before they are due.
- **Portfolio.** Record stocks, ETFs, mutual funds, crypto and gold at a broker or in hand, with prices.

### Ask an AI, stay in control
- Connect **Claude, ChatGPT or any MCP app** and ask questions about your own money: "what did I spend on food last month?"
- The AI can only **suggest** changes: new transactions, category fixes, budgets, loans. **Nothing changes until you approve it** in More › AI assistant.
- Fixes you teach the app (SMS formats, statement layouts) can optionally be shared with the community, with no messages, amounts or names in them.

### Back up and protect
- **Google Drive backup**, automatic or manual, into your own Drive. Backups can be encrypted with a PIN that is never stored, and you can restore on a new phone.
- **App lock** with fingerprint or PIN.
- **Export and import** your data, and an **activity log** of what changed.
- **Light and dark** looks, with colors and styles you can customize.

## Free and Pro

Tracking your money is free, forever. **SimpleMoney Pro** is an optional one-time purchase or subscription that adds unlimited budgets, all looks and colors, the AI assistant, and removes ads. It helps keep the app going.

## Privacy

- No sign-up and no login.
- Your data lives on your device. There is no server holding your transactions.
- The internet is used only for things you switch on: Drive backup, exchange rates, price lookups, the AI connection and community sharing.
- Bank SMS is read locally and not uploaded.

Read the full [privacy policy](https://simplemoney.aashglobal.in/privacy).

## Built with

Flutter and Dart on Android, with a local SQLite database (Drift). Amounts are stored as exact integer minor units, so totals never drift. Dependencies are kept minimal.

## Run it from source

You need the [Flutter SDK](https://docs.flutter.dev/get-started/install) and the Android SDK.

```sh
cd app
flutter pub get
flutter test
flutter run
```

Optional online features read settings from `app/.env` (copy `app/.env.example`). Without them the app still builds and runs. Release builds need your own signing key.

| Folder | What it is |
|---|---|
| `app/` | The Flutter app |
| `app/packages/universal_bank_sms_parser/` | The bank SMS parser, with per-country rules |
| `app/packages/drive_authorization/` | Google Drive sign-in package |
| `WebDoc/` | The website, privacy policy and terms |
| `readme/` | Developer notes |

## Contributing

Bug reports and pull requests are welcome. Please run `flutter analyze` and `flutter test` first, and keep the main rule in mind: **prefer simplicity.** If a feature makes everyday money tracking slower or more confusing, it belongs under advanced options.

Never post real bank messages, statements, account numbers or names in an issue or pull request. Black them out first.

## License

Made by Aash Global. Licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

You can use, change and share this code. If you distribute it, or run a modified version as a network service, you must publish your full source under the same license. Copyright and license notices must stay.
