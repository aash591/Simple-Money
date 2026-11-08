# Universal Bank SMS Parser

An experimental pure Dart compiler and interpreter for language-independent JSON
SMS rules. Country and bank knowledge lives in rule packs, separate from the
engine. Neither runtime use nor validation requires Flutter or a legacy parser
checkout. Tests use the checked-in source rules and conformance corpus.

The v0.3 rules contain **all 54 Indian bank and payment-service families** from
the existing upstream coverage ledger: **289 Indian formats**, plus the three
Iran/Thailand pilot formats. The shared corpus has **1,246 cases**, including
278 migrated Indian movements, 55 physical-device-derived formats, variable-field examples, and rejection checks.
See [COVERAGE.md](COVERAGE.md) for the bank list and validation scope.
This does not yet replace the existing package's 159 worldwide families. Transport,
signatures, CDN publication, and automatic update activation are not implemented.

```dart
import 'dart:convert';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

// The host supplies verified pack bytes from bundled assets or local storage.
final pack = const RuleCompiler().loadRuntime(
  jsonDecode(packJson) as Map<String, dynamic>,
);
final engine = PortableSmsEngine(pack);
final result = engine.parse(BankSms(
  sender: 'BDNSMS',
  body: message,
  receivedAt: receivedAt,
));
final portableResult = result.toJson();
```

Construct the engine once per activated pack. Parsing is synchronous and offline.
Credit/debit describes direction on the notified account, not income or spending.
Use `candidate.accountingTreatment` for accounting: the package's
`credit_card_repayment` category maps to `transfer` on either side of a payment.
Repayment JSON includes `accountingTreatment: "transfer"`; older saved candidates
derive the same treatment from their category. Hosts must resolve both accounts
before recording a transfer and must not invent a missing source or destination.
`isRepeatedSmsNotification` identifies identical normalized notifications within
30 seconds. It compares the full text and sender, never amount/merchant alone;
hosts can use `smsNotificationIdentity` to persist an identity hash after import
or dismissal. Notifications outside that retry window remain separate.
Generic NACH debits use the fallback `nach_debit` suggestion and expose
`category.needsCategoryConfirmation`. Hosts should leave their local category
unset until the user confirms the payment purpose; NACH alone is not evidence
of an EMI or loan repayment.
ATM withdrawals expose `isAtmWithdrawal` and `accountingTreatment: "transfer"`.
Hosts should suggest an active cash account in the withdrawal currency, ask the
user when the destination is ambiguous, and record a transfer to cash. Cash
deposits, refunds and ATM fees retain their own classifications.
Federal Bank UPI alerts without account digits still identify `Federal Bank`,
with `accountLast4: null`. A host may suggest an account when its SMS history
contains exactly one distinct Federal Bank account in the same country and
currency (excluding credit cards). With zero or multiple accounts, leave the
account unresolved for review. Keep this inference separate from the original
candidate and reconsider it when new account identities appear in history.
All completed candidates require review. Replacing a validated pack creates a new
engine; changes to patterns do not require recompiling the application.

## Layout

```text
universal_bank_sms_parser/
├── spec/
│   ├── rules.schema.json
│   ├── specification.md
│   ├── result.schema.json
│   ├── country.schema.json
│   ├── bank.schema.json
│   ├── input.schema.json
│   └── runtime.schema.json
├── rules/
│   ├── india/
│   │   ├── country.json
│   │   ├── bandhan/rules.json
│   │   ├── idfc/rules.json
│   │   ├── indian/rules.json
│   │   ├── indusind/rules.json
│   │   └── ... (54 bank/service directories)
│   ├── iran/
│   └── thailand/
├── engines/
│   └── dart/
│       ├── lib/
│       ├── test/
│       ├── tool/
│       └── pubspec.yaml
├── tests/
│   └── conformance/
│       ├── india/<bank>/{ported,variables,rejections}.json
│       ├── iran/parsian/v0.1.json
│       └── thailand/bangkok/v0.1.json
├── distribution/
│   ├── manifest.json
│   └── packs/<country>/<bank>.json
└── tool/
```

Shared schemas, rules, and conformance fixtures are independent of any engine.
Country indexes hold shared defaults and classifiers and reference bank files.
Each bank file holds its senders, identity requirements, overrides, and formats.
Samples are grouped by the same country/bank hierarchy, including rejection
examples. The compiled distribution also contains one runtime pack per bank;
validated packs can be merged into a single in-memory sender index.
The Dart package lives at `engines/dart`; point local Dart/Flutter dependencies
at that directory. Future engines can be added as sibling directories.

Run from the project root:

```sh
cd engines/dart
dart pub get
dart run tool/compile_rules.dart ../../distribution/packs ../../rules
dart test
dart analyze
dart run tool/benchmark_portable.dart
```

After recompiling a pack, refresh its development manifest from the project root:

```sh
python tool/generate_manifest.py
python tool/generate_manifest.py --check
```

The manifest is unsigned development metadata, with a relative pack path,
SHA-256, byte count, country list, and version requirements. It is not a
production update endpoint.

The compiler validates supported operations, defaults, captures, version
compatibility, and exact duplicate patterns. General pattern overlap is handled
at runtime: conflicting candidates produce an ambiguous review result.

The [v0.3 specification](spec/specification.md) defines the implemented portable
semantics. The schemas and rule language remain experimental; additional engine
implementations and the production update pipeline remain future work.
See [NOTICE.md](NOTICE.md) for provenance and [LICENSE](LICENSE) for licensing.

## Indian migration

Each bank has editable source rules, shared conformance examples, and a compiled
distribution pack. Amounts, account suffixes, references, merchants, and numeric
date/balance metadata are captured; the engine does not look up entire sample
messages. Sender restrictions and bank-specific classification requirements stay
in JSON. The v0.3 operations add bounded delimiter search, metadata captures,
message-end matching, short/masked account tails, and text prefixes.

The original migration used legacy Dart fixtures as a reference;
`tool/migrate_india.py` records that historical import workflow. It is not needed
to build, test, or update the package. Legacy-dependent Dart tools and comparisons
have been removed; provenance and historical difference annotations are retained.
The checked-in bank rules are now authoritative: edit those files for new formats.
The historical pilot generator refuses to overwrite the expanded collection.
`dart run tool/audit_conformance.dart` checks candidate parity;
`--update-identities` changes only deterministic rule IDs for entries whose field
parity passes; extraction expectations are never rewritten by that tool.
After editing rules, compile the packs and regenerate the manifest as above.
Optional schema validation: install `tool/requirements.txt`, then run
`python tool/validate_data.py` from the project root.

## Cash deposits

The bundled SBI rules recognize `Deposit of Cash at ... CDM` as an ATM credit
and `CDM CHARGE DR` as a separate ATM debit. Federal Bank's
`using cash deposit machine` format is also an ATM credit. Canara's `by CASH`
format is a cash credit with an unspecified machine channel; its reported
three-digit account suffix is preserved without padding. The `atm` channel
covers both deposits and withdrawals; use `direction` to distinguish them.

Sanitized package regressions live in each bank's `cash-deposits.json` file.
The original validation inspected 80 deposit/fee message copies across seven
local snapshots, including duplicates; these private messages are not bundled.

## Portable categorization

Category suggestions and merchant/recipient extraction are package outputs.
The Flutter app does not contain merchant keyword rules. Both behaviors are
specified by `categoryRules` and `counterpartyRules` in
[`rules/india/country.json`](rules/india/country.json), compiled into each bank
pack, and deduplicated when packs are merged. The catalog contains 28 category
rules and six name-extraction rules. Other countries may define their own
catalog; an unconfigured country does not inherit Indian categories.

```dart
final result = engine.parse(sms);
final transaction = result.candidate;
final suggestion = transaction?.category;
if (suggestion != null) {
  print(suggestion.id);         // public_transport_train
  print(suggestion.name);       // Train
  print(suggestion.type);       // expense or income
  print(suggestion.isFallback); // true for unfamiliar names -> Personal
}
```

A completed Indian candidate serializes its category as:

```json
{
  "id": "public_transport_train",
  "name": "Train",
  "type": "expense",
  "ruleId": "in.category.train",
  "isFallback": false,
  "aliases": ["Public Transport", "Transportation"]
}
```

Hosts resolve the stable ID to their category storage, retain `counterparty` as
the title, and may let users override the suggestion. Labels and aliases are
presentation hints, not app-specific database IDs. `Personal` is explicitly a
fallback label and does not infer the purpose of a person's payment.
`PortableCategorizer(pack).enrich(body, candidate)` also supports already
extracted transactions. `PortableSmsEngine.parse` applies the same rules after
it recognizes a completed transaction; rejected messages have no candidate or
category. Category rules never alter amounts, directions, dates or accounts.

The 29 cases under [`tests/categorization`](tests/categorization) are shared
engine-neutral fixtures, covering precedence, short names, unknown names,
withdrawals/deposits, repayment/refund distinctions and word boundaries.
The Dart reference engine tests them alongside the bank conformance corpus.
The JSON schemas and [specification](spec/specification.md) define the operations
that another engine must implement. This is an unreleased development format;
there are no backward-compatibility adapters or published update endpoint.

Transport rules return `public_transport_bus` (Bus), `public_transport_train` (Train), and `public_transport_cab` (Cab). Kerala State/KSRTC matches Bus; Indian Railways/IRCTC matches Train; Uber/Ola/taxi matches Cab. All include Public Transport as an alias, allowing consumers to map these categories into their own hierarchy.
