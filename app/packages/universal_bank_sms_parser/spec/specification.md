# Universal Bank SMS Parser rule specification

Draft specification **0.3**; reference engine **0.3.0**. The collection implements
292 formats across India, Iran, and Thailand. JSON data contains no executable
code or regular-expression strings. Future engines must execute the same
operations and pass all files under `tests/conformance/<country>/<bank>/`.

## Versions and files

`schemaVersion` identifies the rule language and is exactly `0.3` in this draft.
`minEngineVersion` is a numeric `major.minor.patch` compatibility requirement.
`packVersion` is an independent positive release integer, at most
9,007,199,254,740,991. Source files compiled together must share a pack version.
Unsupported schemas, operations, and newer engine requirements are rejected.

- `country.schema.json`: `rules/<country>/country.json`, with bank file references.
- `bank.schema.json`: `rules/<country>/<bank>/rules.json`.
- `rules.schema.json`: expanded country-source structure passed to the compiler.
- `runtime.schema.json`: resolved engine input with a canonical sender index.
- `input.schema.json`: platform-supplied sender, body, and received timestamp.
- `result.schema.json`: serialized classification, review decision, and candidate.

The JSON schemas describe structure. The compiler additionally checks semantic
constraints such as defined captures, currency mappings, and token boundaries.

## Source hierarchy and compilation

A country source contains defaults, classifiers, and banks. Each bank contains
its ID, display name, canonical sender IDs, optional defaults and identity
requirements, and message formats. A format contains its unique ID, completed
classification, direction, channel, tokens, output bindings, and optional
defaults, requirements, and classifiers.

The filesystem loader resolves the country index's `banks` list, whose entries
have the form `<bank>/rules.json`. References cannot contain traversal segments
or absolute paths. Bank objects are then assembled into the expanded source
structure for compilation. This filesystem organization is independent of the
runtime language. Samples use `tests/conformance/<country>/<bank>/*.json` and
include `country` and `bankId` metadata, even for rejection examples.

Defaults resolve **engine → country → bank → format**. Scalars and arrays are
replaced by the child value. `exponents` and `denominations` maps merge by key.
Country, bank, and format classifiers concatenate. Bank and format requirements
are both required; a format cannot remove a bank's identity requirement.
A format may specify `senders`, a nonempty subset of its bank's sender allowlist.
This narrows matching for sender-specific formats without introducing new senders.

Compilation resolves defaults, validates rules, sorts formats by rule ID, and
builds a sender-to-rule index. It rejects duplicate rule IDs and duplicate
resolved matching signatures. It does not prove that arbitrary patterns never
overlap. Runtime disagreement is handled conservatively as described below.
Compilation is deterministic and does not embed timestamps or machine paths.

## Normalization and comparison

The input body is limited to 4,000 UTF-16 code units. Whitespace code points
U+0009–U+000D, U+0020, U+00A0, and U+202F collapse to one ASCII space; leading and
trailing whitespace is removed. Other characters remain unchanged.

ASCII digits are always supported. The `digits` setting can additionally map
Persian U+06F0–U+06F9, Arabic-Indic U+0660–U+0669, and Thai U+0E50–U+0E59 to
ASCII digits. No Unicode normalization or locale-dependent case conversion is
performed. `case: exact` compares literally. `ascii_insensitive` folds only
ASCII A–Z to a–z. Captured text retains its normalized spelling.

Sender input is limited to 128 UTF-16 units. Whitespace is normalized as above,
and ASCII lowercase letters are uppercased. Numeric senders remove formatting
characters `+`, parentheses, spaces, periods, and hyphens. Text senders remove
a two-letter routing prefix followed by `-`, and a final `-S`, `-T`, or `-G`.
A final `-P` is rejected. Canonical text IDs match ASCII
`[A-Z][A-Z0-9_ -]{2,30}`. Internal hyphens are retained, so aliases such as
`HDFCMF-AC` must be explicitly registered. Only indexed senders are parsed.

## Classification

Selectors contain optional `all`, `any`, and `none` literal arrays. Every `all`
literal must occur, at least one `any` literal must occur if that array is
nonempty, and no `none` literal may occur. Occurrence means substring matching
under the resolved normalization and case settings, not whole-word matching.
An empty identity selector matches. A classifier must have positive evidence.

Classification is evaluated before field extraction for all rules whose sender
and identity requirements match. Rejection precedence is:

1. `security`
2. `promotional`
3. `failed`
4. `pending`
5. `future`
6. `notice`

Rejection returns `ignored`, with no candidate or rule ID. Only formats declaring
`completed` may extract. If no valid format and fields match, the result is
`unknown` / `ignored` / `noMatchingFormat`.

## Matching operations

Formats start with a nonempty `match_literal` and end with either a literal or
`match_end`. Literals have
canonical whitespace; boundary spaces are significant. The engine searches
for the first literal and evaluates tokens in order at each occurrence. Text
before the first literal is allowed. Text after the last literal is allowed
unless the format ends with `match_end`.

Each capture immediately precedes a literal delimiter or `match_end`. Delimiter
positions within `maxLength` are tried in ascending order using depth-first
search, until the remaining tokens match. `capture_datetime` tries positions in
descending order to include an optional time component. A terminal capture uses
the end of the normalized message. Captured text is trimmed; empty values fail.
Search is bounded by the message-wide work budget, including delimiter scans.
The first complete token match supplies captures; there is no unbounded regex
execution or author-defined code.

| Operation | Validation |
| --- | --- |
| `match_literal` | Consume the literal at the current cursor. |
| `match_end` | Require the cursor to equal the end of the normalized body; terminal token only. |
| `capture_money` | Unsigned digits with configured decimal and grouping marks. |
| `capture_account` | ASCII digits and masks `X`, `x`, `*`, `.`, `-`, `#`; `minDigits` is 1–4, default 4. |
| `capture_reference` | Nonempty ASCII letters, digits, or hyphens. |
| `capture_text` | Any nonempty bounded normalized text; optional `excludeCharacters` vetoes any listed UTF-16 code unit; `rejectDateTime: true` rejects values matching the metadata date/time grammar. |
| `capture_number` | Numeric metadata matching `[0-9]+(?:[,.][0-9]+)*`; cannot bind a transaction amount. |
| `capture_datetime` | ASCII date/time metadata grammar below; cannot bind a transaction amount. |
| `capture_enum` | Match a declared value and return its canonical declared spelling. |

Capture names are unique within a format. Enum values must remain distinct
after normalization and case folding. Output bindings reference a defined
capture or supply one fixed string value.
Reference and counterparty bindings may add a nonempty fixed `prefix`. Currency
bindings do not allow prefixes. Fixed values represent semantic labels, such as
`ATM` or `Interest Credit`, rather than a sample-specific merchant.

The date/time metadata grammar is the union of these four forms (ASCII only):
`[0-9]{1,4}[-/][A-Za-z0-9]{1,9}[-/][0-9]{1,4}` optionally followed by a space,
`[0-9:]+`, and optional space plus `AM`/`PM` in any ASCII letter case; or
`[0-9]{1,2}:[0-9]{2}` with optional `:[0-9]{2}` and the same AM/PM suffix;
`[0-9]{1,2}[A-Za-z]{3,9}[0-9]{2,4}`; or
`[A-Za-z]{3,9} [0-9]{1,2}` optionally followed by an optional comma, space,
and a four-digit year.
This captures metadata, does not validate calendar dates, and never determines
the transaction timestamp. The grammar is part of the engine contract, not
a regex supplied by a pack author.

## Amounts, currencies, and accounts

`decimalMark` is `.` or `,`; the opposite mark is the grouping separator.
`grouping` is `none`, `western`, or `indian`. Ungrouped integer digits are always
allowed. Western grouping uses an initial 1–3 digits followed by groups of
three. Indian grouping uses an initial 1–2 digits and middle groups of two,
ending in three; a single separator allows an initial 1–3 digits. Empty groups,
signs, exponents, and malformed grouping are rejected.
A leading decimal mark, such as `.50`, is interpreted as `0.50`.

Each currency has a declared minor-unit exponent from zero to three. Fraction
digits cannot exceed that exponent. Values are converted using exact integer
arithmetic, with no floating-point rounding. Amounts must be positive and no
larger than 9,007,199,254,740,991 minor units after denomination conversion.

Currency comes from a fixed output value, a mapped enum capture, or the resolved
default. A denomination enum capture selects a `{currency, multiplier}` entry
instead; an explicit currency binding is forbidden in that case. The multiplier
is a positive integer, applied during exact minor-unit conversion. For example,
toman uses an IRR multiplier of 10; rial uses 1.

`extract_account_suffix` removes account mask characters and returns the last
four visible digits. Fewer than four visible digits cannot supply this output.
With `allowShort: true`, it returns all visible digits when fewer than four are
present. With `preserveMask: true`, it instead takes the last four characters of
the captured account, preserving masks; `allowShort` then applies to character
count. For example, the tail `71xx` remains `71xx`. These are account hints,
not full account identifiers.

## Results and ambiguity

The input timestamp is supplied by the host, not inferred from message dates.
Serialized timestamps use UTC ISO-8601 with millisecond precision. A completed
candidate returns `review` / `completedNeedsReview`, with rule ID and pack
version. Rules cannot authorize automatic imports.

All matching candidates are compared across amount, currency, direction,
channel, bank, country, account suffix, reference, and counterparty. Equivalent
candidates choose the lexicographically first matching rule ID. Disagreement
returns `completed` / `review` / `ambiguousMatches`, with a null candidate and
rule ID; no amount is selected automatically.

## Work limits and distribution

Compilation/loading limits serialized UTF-8 data to 4 MiB, sources to 32,
runtime formats to 4,096, indexed rules per sender to 128, tokens per format to
48, and capture lengths to 256 UTF-16 units. Matching permits at most 16 anchor
occurrences per format and 8,192 matching steps per message (token evaluations
and delimiter-position scans). Exceeding a
matching limit returns `unknown` / `ignored` / `workLimit`.

`distribution/manifest.json` describes the checked-in development pack, with
relative path, SHA-256, byte count, and version metadata. It is **unsigned** and
does not implement a production trust or update protocol. The host must verify
trusted bytes before activation. CDN transport, signing, rollback protection,
and automatic activation remain separate work.

Distribution entries point to `packs/<country>/<bank>.json`, each containing a
single bank. A host may load selected entries and merge the validated packs;
merged packs must share `packVersion`. Duplicate-rule validation and sender
index construction also apply to the merged snapshot.

## Category and counterparty enrichment (0.3)

Country sources may define `categoryRules` and `counterpartyRules`. Compilation
injects each source's `country`, retains these arrays at the runtime-pack root,
and sorts each by ascending `priority`, then ASCII `id`. Merging standalone bank
packs deduplicates identical enrichment IDs and rejects conflicting definitions.
Each collection is limited to 256 unique rules. No language-specific regular
expressions or executable code are stored in these rules.

Enrichment runs only after an unambiguous completed transaction is extracted.
It does not affect rejection classification, matching ambiguity or financial
fields. It first extracts a counterparty, then selects the first category rule
whose country, direction, optional channel filter, body `requires`, and `when`
selector match. Rules use the existing whitespace normalization and ASCII case
folding. Non-ASCII characters remain unchanged.

A counterparty rule specifies a literal `prefix`, up to 16 literal `suffixes`,
`when` body selectors and `maxLength` (1-256 UTF-16 units). Preserve delimiter
boundary spaces when normalizing; this can be implemented by normalizing the
literal surrounded by sentinel characters, then removing the sentinels. Search
for the first prefix and the earliest following suffix. Require a nonempty,
bounded trimmed capture with at least one ASCII letter. If no extraction rule
succeeds, retain the transaction format's existing counterparty. Captures keep
original case and do not include their suffix/reference/amount metadata.

A category rule specifies `categoryId`, `name`, optional label `aliases`,
`directions`, `source` (`body` or `merchant`), `match`, `when`, optional body
`requires`, and optional `channels`. `merchant` reads the enriched counterparty;
if absent, it reads the normalized body. The same all/any/none selector semantics
apply, with three occurrence modes:

- `substring`: literal occurrence anywhere.
- `words`: occurrence bounded on both ends by the field boundary or a character
  outside ASCII a-z and 0-9. This avoids classifying Cashfree as CASH or Pumpkin
  as pump. Multiword literals use normalized spaces.
- `exact`: the entire normalized field equals the literal.

`requires` always applies substring selectors to the body. Rules need positive
all/any evidence unless `isFallback` is true. Personal fallback rules run last;
a matched fallback returns its category without claiming a known purpose.

The result's optional `candidate.category` contains stable `id`, display `name`,
`type` (`expense` for debit, `income` for credit), matched `ruleId`, `isFallback`
and `aliases`. A country without matching category rules omits that field.
Category output is a suggestion; host persistence/review policy remains external.
Engine ports must also pass `tests/categorization/*.json`, independently of any
UI, local database identifiers, framework, or host platform.
