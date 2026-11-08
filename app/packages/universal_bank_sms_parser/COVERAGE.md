# Indian portable rule coverage

**54/54 upstream Indian bank/payment-service families** have JSON rules and standalone runtime packs.
The collection contains **289 Indian formats**, **278 migrated movements**, **278 variable-field examples**, and **46 legacy rejected literals**.

55 additional rules cover sanitized templates seen during physical-device
inbox testing across several Indian banks. Their synthetic fixtures are
tracked separately from migrated upstream movements and variable examples.

Each family additionally has nine generated rejection cases covering security,
promotions, failed/pending/future transactions, notices, unknown senders,
promotional senders, and balance-only messages. Earlier pilot cases are retained.

This is fixture-backed coverage of the existing
historical upstream ledger, not a claim to cover
every bank operating in India or every possible SMS format. Wallets, payment
providers, and mutual funds follow the upstream family definitions. Generic
RBL sender metadata is outside those 54 validated upstream families; no RBL
pack is represented as validated. Standard Chartered entries here cover India;
the upstream Pakistan sender/fixtures remain outside this migration.

Rules and tests execute entirely in the universal engine without a legacy
parser checkout. Historical migration differences
are labelled with `legacyDifferences`. Generated examples are labelled as
synthetic. Source-derived fixtures retain their separate provenance.

| Family | Formats | Migrated movements | Variable examples | Legacy rejections |
| --- | ---: | ---: | ---: | ---: |
| [AU Small Finance Bank](rules/india/au/rules.json) | 6 | 6 | 6 | 1 |
| [Airtel Payments Bank](rules/india/airtel/rules.json) | 1 | 1 | 1 | 0 |
| [Amazon Pay](rules/india/amazonpay/rules.json) | 2 | 11 | 11 | 1 |
| [American Express](rules/india/amex/rules.json) | 1 | 1 | 1 | 0 |
| [Axis Bank](rules/india/axis/rules.json) | 6 | 11 | 11 | 0 |
| [Bandhan Bank](rules/india/bandhan/rules.json) | 5 | 7 | 7 | 2 |
| [Bank of Baroda](rules/india/baroda/rules.json) | 11 | 11 | 11 | 4 |
| [Bank of India](rules/india/boi/rules.json) | 4 | 4 | 4 | 1 |
| [CRED](rules/india/cred/rules.json) | 2 | 5 | 5 | 2 |
| [Canara Bank](rules/india/canara/rules.json) | 11 | 5 | 5 | 3 |
| [Cashfree](rules/india/cashfree/rules.json) | 2 | 2 | 2 | 1 |
| [Central Bank of India](rules/india/central/rules.json) | 1 | 1 | 1 | 0 |
| [City Union Bank](rules/india/cityunion/rules.json) | 1 | 1 | 1 | 0 |
| [DBS Bank](rules/india/dbs/rules.json) | 1 | 1 | 1 | 0 |
| [Department of Post](rules/india/post/rules.json) | 2 | 4 | 4 | 4 |
| [Dhanlaxmi Bank](rules/india/dhanlaxmi/rules.json) | 5 | 5 | 5 | 1 |
| [Equitas Small Finance Bank](rules/india/equitas/rules.json) | 3 | 4 | 4 | 1 |
| [Federal Bank](rules/india/federal/rules.json) | 38 | 24 | 24 | 0 |
| [Greater Bank](rules/india/greater/rules.json) | 2 | 2 | 2 | 1 |
| [HDFC Bank](rules/india/hdfc/rules.json) | 11 | 5 | 5 | 3 |
| [HDFC Mutual Fund](rules/india/hdfcmf/rules.json) | 1 | 1 | 1 | 0 |
| [HSBC Bank](rules/india/hsbc/rules.json) | 4 | 4 | 4 | 1 |
| [ICICI Bank](rules/india/icici/rules.json) | 20 | 22 | 22 | 0 |
| [IDBI Bank](rules/india/idbi/rules.json) | 1 | 1 | 1 | 0 |
| [IDFC FIRST Bank](rules/india/idfc/rules.json) | 10 | 7 | 7 | 1 |
| [India Post Payments Bank](rules/india/ippb/rules.json) | 1 | 1 | 1 | 0 |
| [Indian Bank](rules/india/indian/rules.json) | 8 | 11 | 11 | 2 |
| [Indian Overseas Bank](rules/india/iob/rules.json) | 1 | 1 | 1 | 0 |
| [IndusInd Bank](rules/india/indusind/rules.json) | 13 | 14 | 14 | 0 |
| [JK Bank](rules/india/jk/rules.json) | 1 | 1 | 1 | 0 |
| [Jana Small Finance Bank](rules/india/jana/rules.json) | 2 | 2 | 2 | 0 |
| [Jio Payments Bank](rules/india/jiopayments/rules.json) | 4 | 4 | 4 | 0 |
| [JioPay](rules/india/jiopay/rules.json) | 4 | 4 | 4 | 1 |
| [Jupiter](rules/india/jupiter/rules.json) | 1 | 1 | 1 | 0 |
| [Karnataka Bank](rules/india/karnataka/rules.json) | 1 | 1 | 1 | 0 |
| [Kerala Bank](rules/india/kerala/rules.json) | 3 | 2 | 2 | 0 |
| [Kerala Gramin Bank](rules/india/keralagramin/rules.json) | 3 | 4 | 4 | 0 |
| [Kotak Bank](rules/india/kotak/rules.json) | 10 | 13 | 13 | 0 |
| [LazyPay](rules/india/lazypay/rules.json) | 1 | 1 | 1 | 0 |
| [NSDL Payments Bank](rules/india/nsdl/rules.json) | 2 | 3 | 3 | 0 |
| [Navi Mutual Fund](rules/india/navi/rules.json) | 2 | 2 | 2 | 0 |
| [OneCard](rules/india/onecard/rules.json) | 6 | 1 | 1 | 0 |
| [Pluxee](rules/india/pluxee/rules.json) | 1 | 1 | 1 | 0 |
| [Punjab & Sind Bank](rules/india/psb/rules.json) | 4 | 4 | 4 | 0 |
| [Punjab National Bank](rules/india/pnb/rules.json) | 7 | 9 | 9 | 1 |
| [Saraswat Co-operative Bank](rules/india/saraswat/rules.json) | 6 | 8 | 8 | 1 |
| [Slice](rules/india/slice/rules.json) | 13 | 14 | 14 | 7 |
| [South Indian Bank](rules/india/southindian/rules.json) | 7 | 7 | 7 | 2 |
| [Standard Chartered Bank](rules/india/standardchartered/rules.json) | 4 | 6 | 6 | 0 |
| [State Bank of India](rules/india/sbi/rules.json) | 17 | 6 | 6 | 2 |
| [UCO Bank](rules/india/uco/rules.json) | 5 | 5 | 5 | 0 |
| [Union Bank of India](rules/india/union/rules.json) | 4 | 1 | 1 | 0 |
| [Utkarsh Bank](rules/india/utkarsh/rules.json) | 1 | 1 | 1 | 0 |
| [Yes Bank](rules/india/yes/rules.json) | 6 | 4 | 4 | 3 |

The categorization corpus contains 29 engine-neutral cases. Category and
merchant rules live in country JSON and are returned by the parser.

Core validation covers independent bank-pack parsing, shared conformance,
ambiguity handling, and bounded-search checks; no legacy checkout is required.
Run `dart test` and `dart analyze` from `engines/dart`. All 56 country/bank sources and packs
and 1,246 shared cases are checked by the conformance audit. The unsigned
development manifest matches compiled pack hashes and byte counts.

A Windows x64 Dart 3.13.4 JIT benchmark over 10,000 warm parses measured
47.1 µs median and 173.5 µs p95; activating all 56 packs took 300 ms.
These are local measurements, not mobile-device latency guarantees.
