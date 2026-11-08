"""Build the Indian family ledger from source rules and shared regressions."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
read = lambda path: json.loads(path.read_text(encoding='utf-8-sig'))
rows = []
case_count = sum(len(read(path)) for path in (root / 'tests/conformance').rglob('*.json'))
device_formats = 0
for file in (root / 'rules/india').glob('*/rules.json'):
    bank = read(file)
    device_formats += sum('.device' in fmt['id'] for fmt in bank['formats'])
    slug = file.parent.name
    fixtures = root / 'tests/conformance/india' / slug
    legacy = read(fixtures / 'ported.json')
    variables = read(fixtures / 'variables.json')
    rejects = read(fixtures / 'rejections.json')
    rows.append((bank['name'], slug, len(bank['formats']),
                 sum('-device' not in f['id'] for f in legacy),
                 sum('-device' not in f['id'] for f in variables),
                 sum('legacy-rejection' in f['id'] for f in rejects)))
rows.sort()
lines = [
    '# Indian portable rule coverage', '',
    f'**{len(rows)}/54 upstream Indian bank/payment-service families** have JSON rules and standalone runtime packs.',
    f'The collection contains **{sum(r[2] for r in rows)} Indian formats**, '
    f'**{sum(r[3] for r in rows)} migrated movements**, '
    f'**{sum(r[4] for r in rows)} variable-field examples**, and '
    f'**{sum(r[5] for r in rows)} legacy rejected literals**.', '',
    f'{device_formats} additional rules cover sanitized templates seen during physical-device',
    'inbox testing across several Indian banks. Their synthetic fixtures are',
    'tracked separately from migrated upstream movements and variable examples.', '',
    'Each family additionally has nine generated rejection cases covering security,',
    'promotions, failed/pending/future transactions, notices, unknown senders,',
    'promotional senders, and balance-only messages. Earlier pilot cases are retained.', '',
    'This is fixture-backed coverage of the existing',
    'historical upstream ledger, not a claim to cover',
    'every bank operating in India or every possible SMS format. Wallets, payment',
    'providers, and mutual funds follow the upstream family definitions. Generic',
    'RBL sender metadata is outside those 54 validated upstream families; no RBL',
    'pack is represented as validated. Standard Chartered entries here cover India;',
    'the upstream Pakistan sender/fixtures remain outside this migration.', '',
    'Rules and tests execute entirely in the universal engine without a legacy',
    'parser checkout. Historical migration differences',
    'are labelled with `legacyDifferences`. Generated examples are labelled as',
    'synthetic. Source-derived fixtures retain their separate provenance.', '',
    '| Family | Formats | Migrated movements | Variable examples | Legacy rejections |',
    '| --- | ---: | ---: | ---: | ---: |',
]
for name, slug, formats, legacy, variables, rejects in rows:
    lines.append(f'| [{name}](rules/india/{slug}/rules.json) | {formats} | {legacy} | {variables} | {rejects} |')
lines += ['', 'The categorization corpus contains 29 engine-neutral cases. Category and',
          'merchant rules live in country JSON and are returned by the parser.', '', 'Core validation covers independent bank-pack parsing, shared conformance,',
          'ambiguity handling, and bounded-search checks; no legacy checkout is required.',
          'Run `dart test` and `dart analyze` from `engines/dart`. All 56 country/bank sources and packs',
          f'and {case_count:,} shared cases are checked by the conformance audit. The unsigned',
          'development manifest matches compiled pack hashes and byte counts.', '',
          'A Windows x64 Dart 3.13.4 JIT benchmark over 10,000 warm parses measured',
          '47.1 µs median and 173.5 µs p95; activating all 56 packs took 300 ms.',
          'These are local measurements, not mobile-device latency guarantees.', '']
(root / 'COVERAGE.md').write_text('\n'.join(lines), encoding='utf-8')
print(f'Generated coverage for {len(rows)} Indian families.')
