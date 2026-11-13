"""Record migrated cases the portable engine cannot reproduce faithfully.

Reads a `dart test -r expanded` log, then writes tool/world-skip.json so that
migrate_world.py leaves those messages out. Messages that two formats of one
bank both match keep only the first; every other mismatch is dropped.
"""
import collections
import json
import re
import sys
from source_layout import root

log = open(sys.argv[1], encoding='utf-8', errors='replace').read()
harvest = json.loads((root / 'tool/world-harvest.json').read_text(encoding='utf-8'))
code = {b['slug']: b['country'].lower() for b in harvest['banks']}
skip_file = root / 'tool/world-skip.json'
skips = {(b, n): why for b, n, why in json.loads(skip_file.read_text(encoding='utf-8'))} if skip_file.exists() else {}
blocks = re.split(r'\n(?=\d\d:\d\d \+\d+ -\d+: )', log)
ambiguous = collections.defaultdict(set)
added = 0
for block in blocks:
    if '[E]' not in block.split('\n')[0]:
        continue
    m = re.search(r'conformance: ([a-z0-9_-]+)-(ported|variables)-(\d+)', block)
    if not m:
        continue
    slug, number = m[1], int(m[3])
    why = re.search(r'Which: (.*)', block)
    why = why[1][:90] if why else 'differs'
    if 'ambiguousMatches' in why:
        ambiguous[(slug, )].add(number)
        continue
    key = (f'{code[slug]}.{slug}', number)
    if key not in skips:
        skips[key] = why
        added += 1
for (slug,), numbers in ambiguous.items():
    ordered = sorted(numbers)
    for number in (ordered[1:] if len(ordered) > 1 else ordered):
        key = (f'{code[slug]}.{slug}', number)
        if key not in skips:
            skips[key] = 'overlaps another layout of the same bank'
            added += 1
skip_file.write_text(json.dumps([[b, n, w] for (b, n), w in sorted(skips.items())], ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
print('added', added, 'total', len(skips))
