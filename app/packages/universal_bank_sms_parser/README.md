# Universal Bank SMS Parser

Language-independent **JSON rule packs** that turn bank SMS into structured
transactions, plus a specification, schemas and a shared conformance suite so
that anyone can write an engine for them in any language.

The rules are the product. Country and bank knowledge lives in the packs, and
adding a bank means adding a JSON file, not changing code. An engine is just an
interpreter of those packs, and it runs entirely on the device: no network and
no server.

This repository includes a **reference engine in Dart**, which is what
SimpleMoney uses for its SMS import. It is optional. If you work in Kotlin,
Swift, Rust, Python, JavaScript or anything else, use the packs with your own
engine and check it against the same conformance cases.

## What is covered

**25 countries, 157 banks and payment services, 667 message formats**, checked
by a shared corpus of **2,824 conformance cases**, including rejection checks
for promotions, security alerts, failed or pending transactions and balance-only
messages.

| Country | Banks and services | Formats |
| --- | ---: | ---: |
| India | 58 | 303 |
| Ethiopia | 9 | 42 |
| Saudi Arabia | 6 | 40 |
| Nepal | 12 | 33 |
| USA | 8 | 33 |
| UAE | 5 | 31 |
| Jordan | 5 | 28 |
| Tanzania | 4 | 24 |
| Nigeria | 9 | 23 |
| Thailand | 11 | 21 |
| Iran | 4 | 14 |
| Mozambique | 4 | 14 |
| Egypt | 3 | 13 |
| Sri Lanka | 5 | 13 |
| Bangladesh | 2 | 10 |
| Pakistan | 1 | 4 |
| El Salvador | 2 | 4 |
| Czechia | 1 | 3 |
| Oman | 1 | 3 |
| Russia | 1 | 3 |
| Germany | 1 | 2 |
| Turkey | 1 | 2 |
| UK | 2 | 2 |
| France | 1 | 1 |
| Kenya | 1 | 1 |

Coverage is fixture-backed: a bank without a collected message has no rules
yet. That is the gap SimpleMoney's "teach the app" flow and community fixes are
meant to close. See [COVERAGE.md](COVERAGE.md) for the Indian bank list and
validation scope.

> **Status: experimental.** The rule language and schemas are an unreleased
> development format. Transport, signatures, CDN publication and automatic
> update activation are not implemented, and there are no backward-compatibility
> adapters.

## Write your own engine

Everything an engine needs is engine-neutral and lives outside `engines/`:

1. **Read the [specification](spec/specification.md)** for the rule operations,
   captures, defaults and result semantics.
2. **Load the packs** from `distribution/packs/<country>/<bank>.json`. They are
   already compiled for runtime, and `distribution/manifest.json` lists each
   one with its SHA-256, size, countries and version requirements. Validate a
   pack against [`spec/runtime.schema.json`](spec/runtime.schema.json) and
   return results shaped like [`spec/result.schema.json`](spec/result.schema.json).
3. **Run the conformance suite.** Every case in `tests/conformance/` and
   `tests/categorization/` is a plain JSON input and expected output. An engine
   is correct when it reproduces them, including the rejection cases.

You can also start from the editable source rules in `rules/` and write your own
compiler, but you don't have to: the compiled packs are enough. The Dart engine
under `engines/dart` is a working example to compare against.

## Usage (Dart reference engine)

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

Construct the engine once per activated pack. Parsing is synchronous and
offline. Replacing a validated pack creates a new engine, and changes to
patterns do not require recompiling the application. Validated packs can be
merged into a single in-memory sender index.

All completed candidates require review before they are recorded.

## What the engine returns

A completed candidate carries the amount, currency, direction, account suffix,
reference, counterparty, channel and balance or date metadata when the message
has them. Amounts and identifiers are captured by the rules; the engine never
looks up whole sample messages.

Things hosts should know:

- **Direction is not income or spending.** Credit and debit describe the
  direction on the notified account. Use `candidate.accountingTreatment`:
  the `credit_card_repayment` category maps to `transfer` on either side of a
  payment. Hosts must resolve both accounts before recording a transfer and
  must not invent a missing source or destination.
- **Repeated notifications.** `isRepeatedSmsNotification` identifies identical
  normalized notifications (same full text and sender) within 30 seconds.
  Hosts can persist `smsNotificationIdentity` after import or dismissal.
  Notifications outside that window stay separate.
- **NACH debits.** Generic NACH debits use the fallback `nach_debit` suggestion
  and expose `category.needsCategoryConfirmation`. Leave the category unset
  until the user confirms the purpose; NACH alone is not evidence of an EMI or
  loan repayment.
- **ATM withdrawals** expose `isAtmWithdrawal` and
  `accountingTreatment: "transfer"`. Suggest an active cash account in the
  withdrawal currency, ask when the destination is ambiguous, and record a
  transfer to cash. Cash deposits, refunds and ATM fees keep their own
  classifications. The `atm` channel covers deposits and withdrawals; use
  `direction` to tell them apart.
- **Missing account digits.** Some UPI alerts name the bank but not the account
  (`accountLast4: null`). A host may suggest an account when its history holds
  exactly one matching account for that bank, country and currency (excluding
  credit cards). With zero or several, leave it unresolved for review, keep the
  inference separate from the original candidate, and reconsider it when new
  account identities appear.

## Categories and counterparties

Category suggestions and merchant or recipient extraction are package outputs;
the Flutter app holds no merchant keyword rules. Both are defined by
`categoryRules` and `counterpartyRules` in a country's
[`country.json`](rules/india/country.json), compiled into each bank pack and
deduplicated when packs are merged. Another country may define its own catalog;
an unconfigured country does not inherit Indian categories.

```dart
final result = engine.parse(sms);
final suggestion = result.candidate?.category;
if (suggestion != null) {
  print(suggestion.id);         // public_transport_train
  print(suggestion.name);       // Train
  print(suggestion.type);       // expense or income
  print(suggestion.isFallback); // true for unfamiliar names -> Personal
}
```

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

Hosts resolve the stable ID to their own category storage, keep `counterparty`
as the title, and may let users override the suggestion. Labels and aliases are
presentation hints, not database IDs. `Personal` is an explicit fallback and
never infers the purpose of a payment to a person. Category rules never change
amounts, directions, dates or accounts. `PortableCategorizer(pack).enrich(body,
candidate)` also works on already extracted transactions.

## Layout

```text
universal_bank_sms_parser/
├── spec/             schemas and the portable specification
├── rules/            editable source rules, one folder per country
│   └── <country>/
│       ├── country.json        shared defaults and classifiers
│       └── <bank>/rules.json   senders, identity requirements, formats
├── engines/dart/     optional reference engine in Dart (lib/, test/, tool/)
├── tests/
│   ├── conformance/<country>/<bank>/   shared, engine-neutral examples
│   └── categorization/                 shared categorization fixtures
├── distribution/     compiled packs and the development manifest
└── tool/             Python helpers: manifest, schemas, validation
```

Schemas, rules and fixtures are independent of any engine, so another engine
can be added as a sibling of `engines/dart` (for example `engines/kotlin`). The checked-in bank rules are the
source of truth: edit those files to add or fix a format. Each bank's
conformance folder holds its samples and rejection examples, and the compiled
distribution has one runtime pack per bank.

The [specification](spec/specification.md) defines the implemented semantics
that any other engine must follow.

## Develop

Compiling rules and running the tests below uses the Dart engine's tooling; if
you only consume the packs with your own engine, you don't need Dart at all.
From `engines/dart`:

```sh
dart pub get
dart run tool/compile_rules.dart ../../distribution/packs ../../rules
dart test
dart analyze
dart run tool/benchmark_portable.dart
```

After recompiling a pack, refresh the development manifest from the package
root:

```sh
python tool/generate_manifest.py
python tool/generate_manifest.py --check
```

The manifest is unsigned development metadata (relative pack path, SHA-256,
byte count, countries and version requirements). It is not a production update
endpoint.

Optional schema validation: install `tool/requirements.txt`, then run
`python tool/validate_data.py` from the package root.
`dart run tool/audit_conformance.dart` checks candidate parity.

The compiler validates supported operations, defaults, captures, version
compatibility and exact duplicate patterns. General pattern overlap is handled
at runtime: conflicting candidates produce an ambiguous review result.

## Adding or fixing a bank

1. Add or edit `rules/<country>/<bank>/rules.json` with the sender and a
   bounded template for the message, using captures for the variable parts.
2. Add sanitized samples and at least one rejection example under
   `tests/conformance/<country>/<bank>/`. Never include real account numbers,
   names or balances.
3. Compile the packs, regenerate the manifest and run `dart test` as above.

## Provenance and license

Licensed under the GNU Affero General Public License v3.0; see
[LICENSE](LICENSE). Many rules and fixtures were adapted from open-source
projects and keep their original authors' copyright. See
[NOTICE.md](NOTICE.md) for the full attribution and how each fixture is
labelled. Samples reported by SimpleMoney users are sanitized before they are
added, and private messages are never bundled.
