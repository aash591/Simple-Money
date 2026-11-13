"""Translate the PennyWise non-Indian fixtures into reviewable portable rules.

Offline migration aid. Input is tool/world-harvest.json: sanitized messages
taken from PennyWise parser-core's tests and bank-samples.json (AGPL-3.0, see
NOTICE.md), each with what its parser extracts. Every message becomes one
bounded literal template: amount, account, reference, dates and numbers turn
into captures. The resulting bank files are the authoritative sources afterward.

  python tool/migrate_world.py            # write rules/<country>/ and tests
"""
import collections
import decimal
import json
import re
import sys
from source_layout import root, write_json

HARVEST = root / 'tool/world-harvest.json'
CURRENCIES = json.loads((root.parent.parent / 'assets/data/currencies.json').read_text(encoding='utf-8'))
SKIP_COUNTRIES = {'IN'}
# The pilot packs already carry these hand-written banks.
EXISTING = {'Parsian Bank', 'Bangkok Bank'}

# Scripts whose digits the engine can map to ASCII.
SCRIPT_DIGITS = {
    'persian': range(0x06F0, 0x06FA),
    'arabic_indic': range(0x0660, 0x066A),
    'thai': range(0x0E50, 0x0E5A),
}
ENGLISH_CLASSIFIERS = [
    ('security', ['your otp', 'Your OTP', 'otp is', 'verification code', 'one-time password']),
    ('promotional', ['apply now', 'exclusive offer', 'Exclusive offer', 'pre-approved', 'cashback offer']),
    ('failed', ['failed', 'declined', 'unsuccessful']),
    ('pending', ['pending']),
    ('future', ['will be debited', 'Will be debited', 'will be credited', 'to be debited', 'payment due']),
    ('notice', ['statement generated', 'minimum amount due']),
]
# One-time-password words per language; only these are safe to apply country-wide.
LOCAL_SECURITY = {
    'AE': ['رمز التحقق', 'كلمة المرور لمرة واحدة'], 'SA': ['رمز التحقق', 'رمز التفعيل'],
    'EG': ['رمز التحقق', 'كلمة المرور لمرة واحدة'], 'JO': ['رمز التحقق', 'كلمة المرور لمرة واحدة'],
    'OM': ['رمز التحقق'], 'IR': ['رمز یکبار مصرف', 'کد تایید'],
    'TH': ['รหัส OTP', 'รหัสผ่านใช้ครั้งเดียว'],
    'ET': ['OTP', 'የይለፍ ቃል'], 'TZ': ['nambari ya siri', 'neno la siri'],
    'KE': ['nambari ya siri'], 'MZ': ['código de verificação', 'código de segurança'],
    'SV': ['código de verificación', 'clave de un solo uso'], 'CO': ['código de verificación', 'clave dinámica'],
    'DE': ['TAN', 'Verifizierungscode'], 'FR': ['code de vérification', 'code à usage unique'],
    'CZ': ['ověřovací kód', 'jednorázový kód'], 'TR': ['doğrulama kodu', 'tek kullanımlık şifre'],
    'RU': ['код подтверждения', 'одноразовый пароль'], 'BY': ['код подтверждения', 'одноразовый пароль'],
}
COUNTRY_CODES = {
    'Nepal': 'NP', 'Thailand': 'TH', 'United States': 'US', 'Ethiopia': 'ET', 'Nigeria': 'NG',
    'Saudi Arabia': 'SA', 'Tanzania': 'TZ', 'UAE': 'AE', 'Iran': 'IR', 'Jordan': 'JO',
    'Sri Lanka': 'LK', 'Mozambique': 'MZ', 'Bangladesh': 'BD', 'Egypt': 'EG',
    'El Salvador': 'SV', 'Eurozone': 'EU', 'Kenya': 'KE', 'United Kingdom': 'GB',
    'Belarus': 'BY', 'Colombia': 'CO', 'Czech Republic': 'CZ', 'Oman': 'OM',
    'Pakistan': 'PK', 'Russia': 'RU', 'Turkey': 'TR', 'India': 'IN',
}
FOLDER = {
    'NP': 'nepal', 'TH': 'thailand', 'US': 'usa', 'ET': 'ethiopia', 'NG': 'nigeria',
    'SA': 'saudiarabia', 'TZ': 'tanzania', 'AE': 'uae', 'IR': 'iran', 'JO': 'jordan',
    'LK': 'srilanka', 'MZ': 'mozambique', 'BD': 'bangladesh', 'EG': 'egypt',
    'SV': 'elsalvador', 'FR': 'france', 'DE': 'germany', 'KE': 'kenya', 'GB': 'uk', 'BY': 'belarus',
    'CO': 'colombia', 'CZ': 'czechia', 'OM': 'oman', 'PK': 'pakistan', 'RU': 'russia', 'TR': 'turkey',
}
GENERIC = {'BANK', 'ALERT', 'ALERTS', 'INFO', 'SMS', 'NOTIFY', 'PAY', 'MOBILE', 'CARD', 'MONEY'}
MONTHS = r'(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)'


def normalize(text):
    return re.sub(r'\s+', ' ', text).strip()


def ascii_digits(text):
    out = []
    for ch in text:
        for digits in SCRIPT_DIGITS.values():
            if ord(ch) in digits:
                ch = str(ord(ch) - digits[0])
                break
        out.append(ch)
    return ''.join(out)


def scripts_in(text):
    return [name for name, digits in SCRIPT_DIGITS.items() if any(ord(c) in digits for c in text)]


def exponent(code):
    for entry in CURRENCIES if isinstance(CURRENCIES, list) else CURRENCIES.get('currencies', []):
        if entry.get('code') == code:
            return int(entry.get('digits', entry.get('decimalDigits', 2)))
    return 2


def canonical_sender(sender):
    s = re.sub(r'\s+', ' ', sender.strip()).upper()
    if re.fullmatch(r'[+()\d .-]+', s):
        return re.sub(r'[+() .-]', '', s)
    s = re.sub(r'^[A-Z]{2}-', '', s)
    s = re.sub(r'-[STG]$', '', s)
    return s


def valid_sender(s):
    return bool(re.fullmatch(r'[A-Z][A-Z0-9_ -]{2,30}', s) or re.fullmatch(r'\d{3,15}', s))


def money_matches(body, minor, exp):
    """Find amount spans in the (ASCII-digit) body; returns [(match, mark)]."""
    found = []
    pattern = r'(?<!\d)\d[\d,.]*(?!\d)'
    for m in re.finditer(pattern, body):
        text = m[0].rstrip('.,')
        for mark, group in (('.', ','), (',', '.')):
            try:
                value = decimal.Decimal(text.replace(group, '').replace(mark, '.'))
            except decimal.InvalidOperation:
                continue
            if int(value * 10 ** exp) != minor or value != value.quantize(decimal.Decimal(1).scaleb(-exp)):
                continue
            if mark == ',' and '.' not in text and ',' not in text:
                continue
            if text.count(mark) > 1 or (mark in text and len(text.split(mark)[-1]) > exp and exp):
                continue
            found.append((m.start(), m.start() + len(text), mark))
            break
    return found


def template(case, bankid, number, country_currency):
    original = normalize(case['body'])
    body = ascii_digits(original)
    direction = {'EXPENSE': 'debit', 'CREDIT': 'debit', 'INCOME': 'credit'}[case['type']]
    currency = case['currency']
    exp = max(exponent(currency), 2) if currency else 2
    try:
        minor = int(decimal.Decimal(case['amount'].replace(',', '')) * 10 ** exp)
    except Exception:
        raise ValueError('bad amount')
    spans = []
    output = {}

    def add(start, end, name, op):
        if any(start < b and end > a for a, b, _, _ in spans):
            return False
        spans.append((start, end, name, op))
        return True

    amounts = money_matches(body, minor, exp)
    if not amounts:
        raise ValueError('no amount in body')
    amount = max(amounts, key=lambda m: (bool(re.search(r'(?:[A-Z]{3}|[$£€]|Rs\.?|TK|Tk|BDT|KSh|TSh|USD|AED|SAR)\s*$', body[:m[0]])), -m[0]))
    mark = amount[2]
    add(amount[0], amount[1], 'amount', 'capture_money')
    output['amount'] = {'capture': 'amount'}
    if currency and currency != country_currency:
        output['currency'] = {'value': currency}
    for field, key, name, op in [('accountLast4', 'account', 'account', 'capture_account'),
                                 ('reference', 'reference', 'reference', 'capture_text'),
                                 ('counterparty', 'merchant', 'party', 'capture_text')]:
        value = case.get(key)
        if not value or (field == 'accountLast4' and not re.search(r'\d', value)):
            continue
        if field == 'reference' and re.fullmatch(r'[A-Za-z0-9-]+', value):
            op = 'capture_reference'
        found = None
        if field == 'accountLast4':
            for m in re.finditer(r'[Xx*#\d][Xx*#\d.-]*', body):
                digits = re.sub(r'\D', '', m[0])
                if digits.endswith(value) if value.isdigit() else m[0].lower().endswith(value.lower()):
                    if not any(m.start() < b and m.end() > a for a, b, _, _ in spans):
                        found = m
                        break
        else:
            hit = re.search((r'(?<!\w)' if value[0].isalnum() else '') + re.escape(value) + (r'(?!\w)' if value[-1].isalnum() else ''), original, re.I)
            if hit and not any(hit.start() < b and hit.end() > a for a, b, _, _ in spans) and len(original) == len(body):
                found = hit
                value = hit[0]
        if found and add(*found.span(), name, op):
            output[field] = {'capture': name}
            if field == 'accountLast4':
                output[field].update(operation='extract_account_suffix', length=4)
                if len(re.sub(r'\D', '', body[found.start():found.end()])) < 4:
                    output[field]['allowShort'] = True
                if not value.isdigit():
                    output[field]['preserveMask'] = True
        elif field == 'counterparty':
            output[field] = {'value': value}
        elif field == 'accountLast4':
            raise ValueError(f'cannot locate account {value}')
    metadata_patterns = [
        r'\b\d{1,4}[-/.]\w{1,9}[-/.]\d{1,4}(?: [\d:]+(?: ?[aApP][mM])?)?',
        r'\b\d{1,2}[A-Za-z]{3,9}\d{2,4}\b',
        r'\b' + MONTHS + r' \d{1,2}(?:,? \d{4})?\b',
        r'\b\d{1,2}:\d{2}(?::\d{2})?(?: ?[aApP][mM])?',
        r'\b(?=[A-Za-z0-9]*\d)(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{6,}\b',
        r'https?://[^ ]+',
        r'\b\d[\d,]*(?:\.\d+)?\b',
    ]
    metadata = 0
    for index, pattern in enumerate(metadata_patterns):
        for m in re.finditer(pattern, body):
            op = 'capture_datetime' if index < 4 else 'capture_reference' if index == 4 else 'capture_text' if index == 5 else 'capture_number'
            start, end = m.span()
            if start == 0 and op == 'capture_reference':
                start += len(re.match(r'[A-Za-z]*', m[0])[0])
                if start >= end:
                    continue
            if add(start, end, f'meta{metadata}', op):
                metadata += 1
    spans.sort()
    tokens = []
    cursor = 0
    for start, end, name, op in spans:
        literal = original[cursor:start]
        if not literal:
            raise ValueError('adjacent captures or missing initial literal')
        tokens.append({'op': 'match_literal', 'value': literal})
        capture = {'op': op, 'name': name, 'maxLength': 256 if op == 'capture_text' else 64}
        if op == 'capture_account':
            visible = len(re.sub(r'\D', '', body[start:end]))
            if visible < 4:
                capture['minDigits'] = max(1, visible)
        tokens.append(capture)
        cursor = end
    if original[cursor:]:
        tokens.append({'op': 'match_literal', 'value': original[cursor:]})
    tokens.append({'op': 'match_end'})
    channel = 'card' if (case['type'] == 'CREDIT' or re.search(r'\bcard\b|بطاقة|บัตร', body, re.I)) else \
        'atm' if re.search(r'\bATM\b|withdrawn from', body) else \
        'wallet' if re.search(r'wallet|m-?pesa|mobile money|bkash|telebirr|mola', body, re.I) else 'bankTransfer'
    fmt = {'id': f'{bankid}.template{number:03}', 'classification': 'completed',
           'direction': direction, 'channel': channel, 'tokens': tokens, 'output': output}
    defaults = {}
    if mark == ',':
        defaults['decimalMark'] = ','
        defaults['grouping'] = 'western'
    elif re.search(r'\d,\d{2},\d{3}', original):
        defaults['grouping'] = 'indian'
    scripts = scripts_in(original)
    if scripts:
        defaults['digits'] = ['ascii'] + scripts
    if re.search(r'[^\x00-\x7f]', original):
        defaults['case'] = 'exact'
    if defaults:
        fmt['defaults'] = defaults
    # Variable-field regression: swap every capture for another valid value.
    values = {name: body[a:b] for a, b, name, _ in spans}
    mutated = {}
    for a, b, name, op in spans:
        value = values[name]
        if name == 'amount':
            value = ('321,09' if mark == ',' else '321.09')
        elif name == 'account':
            positions = [i for i, c in enumerate(value) if c.isdigit()]
            chars = list(value)
            for i, digit in zip(positions[-4:], '9988'[-len(positions[-4:]):]):
                chars[i] = digit
            value = ''.join(chars)
        elif name == 'reference':
            value = 'MIG123456' if op == 'capture_reference' else '556677/88'
        elif name == 'party':
            value = 'MIGRATIONSHOP'
        elif op == 'capture_number':
            value = '9876.54'
        elif op == 'capture_reference':
            value = 'META998877'
        elif op == 'capture_text' and name.startswith('meta'):
            value = 'metadatavalue'
        elif op == 'capture_datetime':
            value = '11:22:33' if re.match(r'^\d{1,2}:', value) else '02-DEC-2027' + (' 11:22:33' if ':' in value else '')
        mutated[name] = value
    mutation_body = original
    for a, b, name, _ in reversed(spans):
        mutation_body = mutation_body[:a] + mutated[name] + mutation_body[b:]
    candidate = {
        'amountMinor': minor, 'currencyCode': currency or country_currency,
        'direction': direction, 'channel': channel, 'bankName': None, 'countryCode': None,
        'accountLast4': None, 'reference': None, 'counterparty': None,
    }
    mutation_candidate = dict(candidate, amountMinor=32109 * 10 ** (exp - 2))
    for field in ['accountLast4', 'reference', 'counterparty']:
        binding = output.get(field)
        key = {'accountLast4': 'account', 'reference': 'reference', 'counterparty': 'merchant'}[field]
        if not binding:
            continue
        value = binding.get('value', mutated.get(binding.get('capture')))
        if field == 'accountLast4':
            if not binding.get('preserveMask'):
                value = re.sub(r'\D', '', value)
            value = value[-4:]
            shown = values[binding['capture']]
            candidate[field] = (shown if binding.get('preserveMask') else re.sub(r'\D', '', shown))[-4:]
        else:
            candidate[field] = case[key] if 'value' in binding else values[binding['capture']]
        mutation_candidate[field] = binding.get('prefix', '') + value
    return fmt, candidate, mutation_body, mutation_candidate, defaults


SKIP_FILE = root / 'tool/world-skip.json'
SKIPPED = {}
if SKIP_FILE.exists():
    SKIPPED = {(b, n): why for b, n, why in json.loads(SKIP_FILE.read_text(encoding='utf-8'))}


def main():
    harvest = json.loads(HARVEST.read_text(encoding='utf-8'))
    by_country = collections.defaultdict(list)
    for bank in harvest['banks']:
        if bank['country'] in SKIP_COUNTRIES or bank['name'] in EXISTING:
            continue
        by_country[bank['country']].append(bank)
    report = collections.defaultdict(list)
    for code, banks in sorted(by_country.items()):
        folder = FOLDER[code]
        currency = banks[0]['countryCurrency']
        country_path = root / 'rules' / folder / 'country.json'
        classifiers = [{'classification': c, 'when': {'any': words}} for c, words in ENGLISH_CLASSIFIERS]
        if code in LOCAL_SECURITY:
            classifiers[0]['when']['any'] = classifiers[0]['when']['any'] + LOCAL_SECURITY[code]
        exponents = {currency: max(exponent(currency), 2)}
        refs = []
        for bank in sorted(banks, key=lambda b: b['slug']):
            bankid = f"{code.lower()}.{bank['slug']}"
            formats, cases_out, mutations, signatures = [], [], [], {}
            senders = {canonical_sender(x) for x in bank['senders']}
            for number, case in enumerate(bank['cases'], 1):
                if case['type'] not in ('EXPENSE', 'CREDIT', 'INCOME') or not case.get('amount') or not case.get('currency'):
                    report[bankid].append(f"skip {case.get('name') or number}: no usable expectation")
                    continue
                if (bankid, number) in SKIPPED:
                    report[bankid].append(f"skip {case.get('name') or number}: {SKIPPED[(bankid, number)]}")
                    continue
                if not valid_sender(canonical_sender(case['sender'])):
                    report[bankid].append(f"skip {case.get('name') or number}: sender {case['sender']!r} cannot be indexed")
                    continue
                try:
                    fmt, candidate, mutation_body, mutation_candidate, defaults = template(case, bankid, number, currency)
                except ValueError as e:
                    report[bankid].append(f"skip {case.get('name') or number}: {e}")
                    continue
                exponents.setdefault(candidate['currencyCode'], max(exponent(candidate['currencyCode']), 2))
                candidate.update(bankName=bank['name'], countryCode=code)
                mutation_candidate.update(bankName=bank['name'], countryCode=code)
                signature = json.dumps([fmt.get('defaults'), fmt['tokens']], sort_keys=True)
                if signature in signatures:
                    prior = signatures[signature]
                    if prior['output'] != fmt['output'] or prior['channel'] != fmt['channel']:
                        report[bankid].append(f"skip {case.get('name') or number}: same layout, different reading")
                        continue
                    ruleid = prior['id']
                else:
                    formats.append(fmt)
                    signatures[signature] = fmt
                    ruleid = fmt['id']
                sender = canonical_sender(case['sender'])
                if valid_sender(sender):
                    senders.add(sender)
                fixture = {'id': f"{bank['slug']}-ported-{number:03}", 'country': code, 'bankId': bankid,
                           'provenance': f"PennyWise {bank['source']} ({case.get('name') or 'bank sample'}); see NOTICE.md",
                           'input': {'sender': case['sender'], 'body': case['body'], 'receivedAt': '2026-10-07T00:00:00.000Z'},
                           'expected': {'classification': 'completed', 'decision': 'review',
                                        'reason': 'completedNeedsReview', 'packVersion': 1, 'ruleId': ruleid,
                                        'candidate': {**candidate, 'occurredAt': '2026-10-07T00:00:00.000Z'}},
                           'compareLegacy': True}
                cases_out.append(fixture)
                mutations.append({**fixture, 'id': f"{bank['slug']}-variables-{number:03}",
                                  'provenance': 'Generated variable-field regression; not an upstream SMS',
                                  'compareLegacy': False,
                                  'input': {**fixture['input'], 'body': mutation_body},
                                  'expected': {**fixture['expected'], 'candidate': {**mutation_candidate, 'occurredAt': '2026-10-07T00:00:00.000Z'}}})
            if not formats:
                report[bankid].append('NO RULES')
                continue
            senders = sorted(s for s in senders if valid_sender(s) and s not in GENERIC)
            for fmt in formats:
                fmt['id'] = fmt['id']
            write_json(root / f'rules/{folder}/{bank["slug"]}/rules.json',
                       {'id': bankid, 'name': bank['name'], 'senders': senders, 'formats': formats})
            refs.append(f'{bank["slug"]}/rules.json')
            conf = root / f'tests/conformance/{folder}/{bank["slug"]}'
            write_json(conf / 'ported.json', cases_out)
            write_json(conf / 'variables.json', mutations)
            base = cases_out[0]
            rejections = []
            for classification, prefix in [('security', 'your otp is 123456. '), ('promotional', 'exclusive offer: apply now. '),
                                           ('failed', 'payment failed. '), ('pending', 'payment pending. '),
                                           ('future', 'will be debited. '), ('notice', 'statement generated. ')]:
                rejections.append({'id': f"{bank['slug']}-reject-{classification}", 'country': code, 'bankId': bankid,
                                   'provenance': 'Generated adversarial prefix, not an upstream SMS',
                                   'input': {**base['input'], 'body': prefix + base['input']['body']},
                                   'expected': {'classification': classification, 'decision': 'ignored', 'reason': classification,
                                                'packVersion': 1, 'ruleId': None, 'candidate': None}, 'compareLegacy': False})
            for label, sender, text, reason in [
                    ('unknown-sender', 'UNREGISTEREDX', base['input']['body'], 'unregisteredSender'),
                    ('balance-only', base['input']['sender'], 'Available balance 9876.54.', 'noMatchingFormat')]:
                rejections.append({'id': f"{bank['slug']}-reject-{label}", 'country': code, 'bankId': bankid,
                                   'provenance': 'Generated rejection regression, not an upstream SMS',
                                   'input': {**base['input'], 'sender': sender, 'body': text},
                                   'expected': {'classification': 'unknown', 'decision': 'ignored', 'reason': reason,
                                                'packVersion': 1, 'ruleId': None, 'candidate': None}, 'compareLegacy': False})
            write_json(conf / 'rejections.json', rejections)
        if not refs:
            continue
        defaults = {'currency': currency, 'case': 'ascii_insensitive', 'digits': ['ascii'],
                    'decimalMark': '.', 'grouping': 'western', 'exponents': exponents}
        if country_path.exists():
            # Keep a pilot country's hand-written banks, classifiers and denominations.
            current = json.loads(country_path.read_text(encoding='utf-8-sig'))
            refs = sorted(set(current['banks']) | set(refs))
            classifiers = current['classifiers']
            defaults = {**defaults, **current['defaults'],
                        'exponents': {**exponents, **current['defaults'].get('exponents', {})}}
        write_json(country_path, {'schemaVersion': '0.3', 'minEngineVersion': '0.3.0', 'packVersion': 1,
                                  'country': code, 'defaults': defaults, 'classifiers': classifiers, 'banks': refs})
    skipped = sum(len(v) for v in report.values())
    for bank, lines in sorted(report.items()):
        for line in lines:
            print(bank, line)
    print(f'{skipped} notes', file=sys.stderr)


if __name__ == '__main__':
    main()
