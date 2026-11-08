# Universal Bank SMS Parser — Dart engine

The Dart package is located here. The rule language, country sources, runtime
packs, and cross-language conformance corpus live at the project root, two
directories above. See the [project README](../../README.md) and
[specification](../../spec/specification.md).

From this directory:

```sh
dart pub get
dart test
dart analyze
dart run tool/compile_rules.dart ../../distribution/packs ../../rules
dart run tool/benchmark_portable.dart
```

Consumers use `package:universal_bank_sms_parser/universal_bank_sms_parser.dart`.
For a local dependency, point its `path` at this directory, not the project root.
Tests use the checked-in conformance corpus and do not require a legacy parser checkout.

The engine exports `PortableCategorizer` and `SmsSuggestedCategory`. Country-owned
JSON rules supply category and counterparty output; no Flutter API is required.
