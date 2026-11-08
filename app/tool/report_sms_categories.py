"""Analyze local snapshots using package categories; export only aggregate counts.

Run from the repository root: python app/tool/report_sms_categories.py
Raw bodies are sent only to the local Dart process and never written to reports.
"""
import json
import shutil
import subprocess
from collections import Counter
from pathlib import Path

root = Path(__file__).resolve().parents[2]
app = root / 'app'
messages = []
unique = []
seen = set()
files = sorted((root / 'artifacts/sms').rglob('all_sms.jsonl'))
for path in files:
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        sender = row.get('sender', row.get('address'))
        at = row.get('receivedAtMs', row.get('dateMs'))
        key = (sender, at, row['body'])
        unique.append(key not in seen)
        seen.add(key)
        messages.append({'sender': sender, 'receivedAt': at, 'body': row['body']})
payload = ''.join(json.dumps(row) + '\n' for row in messages)
process = subprocess.run(
    [shutil.which('dart') or 'dart', 'run', 'tool/diagnose_sms_inbox.dart',
     '--per-message', '--categories', '--app-parser'],
    cwd=app, input=payload, text=True, encoding='utf-8', capture_output=True, check=True,
)
decisions = [json.loads(line) for line in process.stdout.splitlines() if line.startswith('{')]
if len(decisions) != len(messages):
    raise RuntimeError('Diagnostic result count does not match the inbox')
distinct = [row for row, first in zip(decisions, unique) if first]
candidates = [row for row in distinct if row['hasCandidate']]
counts = Counter((row['categoryId'], row['categoryName']) for row in candidates)
personal = sum(row['isFallback'] is True for row in candidates)
named = sum(row['hasCounterparty'] for row in candidates)
lines = [
    '# SMS categorization analysis', '',
    f'Analyzed all {len(messages):,} messages across {len(files)} local snapshots. '
    f'There are {len(distinct):,} distinct messages by exact sender, received time and body. '
    'Snapshots overlap; transaction counts below exclude exact duplicates.', '',
    f'The current app parser recognizes {len(candidates):,} distinct transactions. '
    f'The package supplies specific categories for {len(candidates)-personal:,}; '
    f'{personal:,} use the Personal fallback. '
    f'{named:,} retain an extracted merchant/recipient name.', '',
    '| Package category | Distinct transactions |', '| --- | ---: |',
]
for (_, name), count in counts.most_common():
    lines.append(f'| {name or "Uncategorized"} | {count:,} |')
lines += [
    '', '## Confirmed patterns', '',
    '- Indian Railw / Indian Railways / IRCTC UTS / IRCTCTOURISM -> Public Transport / Train.',
    '- Kerala State Ro / keralastateroad / KSRTC and exact Kerala State or Kerala Stat merchant names -> Public Transport / Bus.',
    '- Uber / Ola / taxi -> Public Transport / Cab.',
    '- Kerala State Electricity Board / KSEBL -> Electricity; evaluated before transport.',
    '- Merchant names containing store -> Groceries. Recognizable fuel/pharmacy names take priority. Mart and other grocery words require word boundaries.',
    '- ATM withdrawal / ATM txn debits -> ATM Withdrawal; CDM CHARGE DR -> Bank Charges.',
    '- Deposit of Cash ... CDM / using cash deposit machine credits -> ATM Deposit; by CASH -> Cash Deposit. Cashfree is not a cash deposit.',
    '- Received or credited card payments -> Credit Card Repayment. Purchases, refunds and cashback remain distinct.',
    '- Unfamiliar names retain their titles and receive Personal, explicitly marked isFallback=true.',
    '- Bill-generated notices, already-paid reminders and outstanding-dues EMI offers are excluded from transaction import.',
    '', '## Integration', '',
    'All categorization and counterparty extraction knowledge lives in package country JSON. '
    'The reference engine returns stable category IDs, labels, types, matched rule IDs and fallback status. '
    'Flutter maps that output to local categories; it does not infer merchant categories.', '',
    'SMS review reuses TransactionsScreen for search, type/account/category filters, period tabs and group totals. '
    'It starts with an all-time category overview, and bulk saving does not require opening each row. '
    'Credit card spending is orange.', '',
    'Counts cover recognized formats only. Personal is a generic fallback and does not claim to infer an unfamiliar name\'s purpose. '
    'This report contains no private message bodies, account numbers, references or personal names.', '',
]
path = root / 'artifacts/sms/pattern-analysis.md'
path.write_text('\n'.join(lines), encoding='utf-8')
print(f'{len(messages):,} messages; {len(distinct):,} distinct; {len(candidates):,} transactions; {personal:,} Personal; {named:,} named.')
for (_, name), count in counts.most_common():
    print(f'{name}: {count}')
print(f'Report: {path}')
