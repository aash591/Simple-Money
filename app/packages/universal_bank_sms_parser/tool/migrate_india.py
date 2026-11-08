"""Translate the legacy fixture corpus into reviewable, bounded literal templates.

Historical offline migration aid using previously harvested fixture data.
The legacy harvester has been removed; this tool is not part of validation.
Amounts, accounts, references, parties and numeric metadata become captures.
Keep the resulting bank files as the authoritative sources after migration.
"""
import collections
import decimal
import json
import re
from source_layout import root, write_json

IDS = dict(zip([
    'AU Small Finance Bank', 'Airtel Payments Bank', 'Amazon Pay', 'American Express',
    'Axis Bank', 'Bandhan Bank', 'Bank of Baroda', 'Bank of India', 'CRED',
    'Canara Bank', 'Cashfree', 'Central Bank of India', 'City Union Bank', 'DBS Bank',
    'Department of Post', 'Dhanlaxmi Bank', 'Equitas Small Finance Bank', 'Federal Bank',
    'Greater Bank', 'HDFC Bank', 'HDFC Mutual Fund', 'HSBC Bank', 'ICICI Bank', 'IDBI Bank',
    'IDFC FIRST Bank', 'India Post Payments Bank', 'Indian Bank', 'Indian Overseas Bank',
    'IndusInd Bank', 'JK Bank', 'Jana Small Finance Bank', 'Jio Payments Bank', 'JioPay',
    'Jupiter', 'Karnataka Bank', 'Kerala Bank', 'Kerala Gramin Bank', 'Kotak Bank',
    'LazyPay', 'NSDL Payments Bank', 'Navi Mutual Fund', 'OneCard', 'Pluxee',
    'Punjab & Sind Bank', 'Punjab National Bank', 'Saraswat Co-operative Bank', 'Slice',
    'South Indian Bank', 'Standard Chartered Bank', 'State Bank of India', 'UCO Bank',
    'Union Bank of India', 'Utkarsh Bank', 'Yes Bank',
], [
    'au', 'airtel', 'amazonpay', 'amex', 'axis', 'bandhan', 'baroda', 'boi', 'cred',
    'canara', 'cashfree', 'central', 'cityunion', 'dbs', 'post', 'dhanlaxmi', 'equitas',
    'federal', 'greater', 'hdfc', 'hdfcmf', 'hsbc', 'icici', 'idbi', 'idfc', 'ippb',
    'indian', 'iob', 'indusind', 'jk', 'jana', 'jiopayments', 'jiopay', 'jupiter',
    'karnataka', 'kerala', 'keralagramin', 'kotak', 'lazypay', 'nsdl', 'navi', 'onecard',
    'pluxee', 'psb', 'pnb', 'saraswat', 'slice', 'southindian', 'standardchartered',
    'sbi', 'uco', 'union', 'utkarsh', 'yes',
]))


def normalize(text):
    return re.sub(r'\s+', ' ', text).strip()


def template(sample, bankid, number):
    body = normalize(sample['body'])
    candidate = dict(sample['candidate'])
    spans = []
    output = {}
    differences = {}
    def correct(field, value):
        if candidate[field] != value:
            differences[field] = candidate[field]
            candidate[field] = value
    if candidate['bankName'] == 'Axis Bank' and '\n' in sample['body']:
        lines = sample['body'].splitlines()
        for i, line in enumerate(lines):
            if line.startswith('Avl '):
                correct('counterparty', lines[i - 1].strip())
    if candidate['bankName'] == 'Kotak Bank':
        payee = re.search(r' from Kotak Bank AC \S+ to (.+?) on ', body)
        refund = re.search(r' from (.+?) refunded to ', body)
        if payee: correct('counterparty', payee[1])
        if refund: correct('counterparty', refund[1])
    if candidate['reference'] == 'unded' and 'refunded' in body.lower():
        differences['reference'] = 'unded'
        candidate['reference'] = None
    # Correct the known IndusInd merchant bug rather than capturing an amount as
    # a merchant. The original value remains explicit in conformance provenance.
    if candidate['bankName'] == 'IndusInd Bank' and re.match(r'Rs\.? ?\d', candidate['counterparty'] or ''):
        party = re.search(r'(?:towards|from) ([^ ]+@[^. ]+(?:\.[^ ]+)?)', body, re.I)
        if party:
            differences['counterparty'] = candidate['counterparty']
            candidate['counterparty'] = party[1].rstrip('.')

    def add(start, end, name, op):
        if any(start < b and end > a for a, b, _, _ in spans):
            return False
        spans.append((start, end, name, op))
        return True

    amounts = []
    for m in re.finditer(r'(?<!\d)\d[\d,]*(?:\.\d{1,2})?(?!\d)|(?<![A-Za-z\d])\.\d{1,2}(?!\d)', body):
        try:
            minor = int(decimal.Decimal(m[0].replace(',', '')) * 100)
        except decimal.InvalidOperation:
            continue
        if minor == candidate['amountMinor']:
            amounts.append(m)
    if not amounts:
        raise ValueError(f'No transaction amount: {body}')
    amount = max(amounts, key=lambda m: (bool(re.search(r'(?:INR|USD|EUR|GBP|Rs\.?|rupees)\s*$', body[:m.start()], re.I)), -m.start()))
    add(*amount.span(), 'amount', 'capture_money')
    output['amount'] = {'capture': 'amount'}
    if candidate['currencyCode'] != 'INR':
        output['currency'] = {'value': candidate['currencyCode']}
    for field, name, op in [('accountLast4', 'account', 'capture_account'),
                             ('reference', 'reference', 'capture_text'),
                             ('counterparty', 'party', 'capture_text')]:
        value = candidate[field]
        if not value:
            continue
        if field == 'reference' and re.fullmatch(r'[A-Za-z0-9-]+', value):
            op = 'capture_reference'
        found = None
        if field == 'accountLast4':
            for m in re.finditer(r'[Xx*#\d][Xx*#\d.-]*', body):
                digits = re.sub(r'\D', '', m[0])
                suffix_matches = digits.endswith(value) if value.isdigit() else m[0].lower().endswith(value.lower())
                if suffix_matches and not any(m.start() < b and m.end() > a for a,b,_,_ in spans):
                    found = m
                    break
        else:
            found = re.search((r'(?<!\w)' if value[0].isalnum() else '') + re.escape(value) + (r'(?!\w)' if value[-1].isalnum() else ''), body, re.I)
            if found and found[0] != value:
                correct(field, found[0])
                value = found[0]
        if found and add(*found.span(), name, op):
            output[field] = {'capture': name}
            if field == 'accountLast4':
                output[field].update(operation='extract_account_suffix', length=4)
                if len(value) < 4:
                    output[field]['allowShort'] = True
                if not value.isdigit():
                    output[field]['preserveMask'] = True
        elif field == 'counterparty':
            # A semantic label, e.g. "Cheque Credit", not a fixture merchant.
            if value.startswith('Card ') and 'accountLast4' in output:
                output[field] = {'capture': 'account', 'prefix': 'Card '}
            else:
                output[field] = {'value': value}
        else:
            raise ValueError(f'Cannot locate {field}={value}: {body}')

    # Preserve legacy null-merchant output while accepting variable merchants in
    # positions that the legacy parser deliberately does not return.
    if candidate['counterparty'] is None:
        for pattern in [r'(?<= at ).+?(?= on \d)', r'(?<= for ).+?(?= via e-mandate)',
                        r'(?<=paid to ).+?(?= via slice)', r'(?<= on ).+?(?=\. Avl\. Limit:| \. Avl Limit:|\. Avl Limit:)']:
            for m in re.finditer(pattern, body):
                add(*m.span(), 'ignoredMerchant', 'capture_text')
                break
    # Dates are one capture so repeated '-' or '/' delimiters do not truncate it.
    metadata_patterns = [
        r'\b\d{1,4}[-/]\w{1,9}[-/]\d{1,4}(?: [\d:]+(?: ?[aApP][mM])?)?',
        r'\b\d{1,2}[A-Za-z]{3,9}\d{2,4}\b',
        r'\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?) \d{1,2}(?:,? \d{4})?\b',
        r'\b\d{1,2}:\d{2}(?::\d{2})?(?: ?[aApP][mM])?',
        r'\b(?=[A-Za-z0-9]*\d)(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{6,}\b',
        r'https?://[^ ]+',
        r'(?<=@)[A-Za-z0-9._-]+',
        r'\b\d[\d,]*(?:\.\d+)?\b',
    ]
    metadata = 0
    for index, pattern in enumerate(metadata_patterns):
        for m in re.finditer(pattern, body):
            op = 'capture_datetime' if index < 4 else 'capture_reference' if index == 4 else 'capture_text' if index < 7 else 'capture_number'
            if bankid == 'in.federal' and m[0] == '0000' and body[:m.start()].endswith('sent by '):
                continue
            start, end = m.span()
            if start == 0 and op == 'capture_reference':
                start += len(re.match(r'[A-Za-z]+', m[0])[0])
            if add(start, end, f'meta{metadata}', op):
                metadata += 1
    spans.sort()
    tokens = []
    cursor = 0
    for start, end, name, op in spans:
        literal = body[cursor:start]
        if not literal:
            raise ValueError(f'Adjacent captures or missing initial literal: {body} {spans}')
        tokens.append({'op': 'match_literal', 'value': literal})
        capture = {'op': op, 'name': name, 'maxLength': 256 if op == 'capture_text' else 64}
        if op == 'capture_account':
            visible = len(re.sub(r'\D', '', candidate['accountLast4']))
            if visible < 4:
                capture['minDigits'] = max(1, visible)
        tokens.append(capture)
        cursor = end
    if body[cursor:]:
        tokens.append({'op': 'match_literal', 'value': body[cursor:]})
    tokens.append({'op': 'match_end'})
    fmt = {'id': f'{bankid}.template{number:03}', 'classification': 'completed',
           'direction': candidate['direction'], 'channel': candidate['channel'],
           'tokens': tokens, 'output': output}
    if candidate['counterparty'] is None:
        for marker in [' has received Rs ', "you've received"]:
            initial = tokens[0]['value']
            if marker in initial: tokens[0]['value'] = initial[initial.index(marker):]
    if bankid == 'in.sbi' and any(ord(c) > 0xFFFF for c in body):
        fmt['senders'] = ['SBI CARDS AND PAYMENT SERVICES']
    if bankid == 'in.idfc' and 'monthly interest' not in body:
        fmt['requires'] = {'none': ['monthly interest']}
    if bankid == 'in.saraswat' and 'ACH Credit:' not in body:
        fmt['requires'] = {'none': ['ACH Credit:']}
    if bankid == 'in.axis' and candidate['channel'] == 'card':
        fmt['requires'] = {'none': [' on AXIS BANK ']}
    if bankid == 'in.baroda' and 'Cr. to ' in body and 'to redacted@' not in body:
        fmt['requires'] = {'none': ['to redacted@']}
    if bankid == 'in.federal' and 'sent by ' in body:
        fmt['requires'] = {'all': ['sent by 0000 ']} if 'sent by 0000 ' in body else {'none': ['sent by 0000 ']}
    if bankid == 'in.psb' and candidate['reference'] is None:
        fmt['requires'] = {'none': ['NEFT/', 'UPI/', 'Credit of ']}
    if bankid == 'in.dhanlaxmi' and 'Payment from ' in body:
        for token in tokens:
            if token.get('name') == 'party': token['excludeCharacters'] = '/'
    if bankid == 'in.slice' and candidate['counterparty'] and 'credit card transaction' in body:
        for token in tokens:
            if token.get('name') == 'party': token['rejectDateTime'] = True
    # Transaction amounts may use either international or Indian grouping.
    if re.search(r'\d,\d{2},\d{3}', amount[0]):
        fmt['defaults'] = {'grouping': 'indian'}
    values = {name: body[a:b] for a,b,name,_ in spans}
    mutated = {}
    for a,b,name,op in spans:
        value = values[name]
        if name == 'amount': value = '321.09'
        elif name == 'account':
            positions = [i for i,c in enumerate(value) if c.isdigit()]
            chars = list(value)
            for i, digit in zip(positions[-4:], '9988'[-len(positions[-4:]):]): chars[i] = digit
            value = ''.join(chars)
        elif name == 'reference': value = 'MIG123456' if op == 'capture_reference' else '556677/88'
        elif name == 'party': value = 'MIGRATIONSHOP'
        elif name == 'ignoredMerchant': value = 'VARIABLEMERCHANT'
        elif op == 'capture_number': value = '9876.54'
        elif op == 'capture_reference': value = 'META998877'
        elif op == 'capture_text' and name.startswith('meta'): value = 'metadatavalue'
        elif op == 'capture_datetime': value = '11:22:33' if re.match(r'^\d{1,2}:', value) else '02-DEC-2027' + (' 11:22:33' if ':' in value else '')
        mutated[name] = value
    mutation_body = body
    for a,b,name,_ in reversed(spans): mutation_body = mutation_body[:a] + mutated[name] + mutation_body[b:]
    mutation_candidate = dict(candidate, amountMinor=32109)
    for field in ['accountLast4', 'reference', 'counterparty']:
        binding = output.get(field)
        if not binding: continue
        value = binding.get('value', mutated.get(binding.get('capture')))
        if field == 'accountLast4':
            if not binding.get('preserveMask'): value = re.sub(r'\D', '', value)
            value = value[-4:]
        mutation_candidate[field] = binding.get('prefix', '') + value
    return fmt, candidate, differences, mutation_body, mutation_candidate


def main():
    harvest = json.loads((root / 'tool/india-harvest.json').read_text(encoding='utf-8'))
    grouped = collections.defaultdict(dict)
    for sample in harvest['samples']:
        grouped[sample['candidate']['bankName']].setdefault(sample['body'], sample)
    assert set(grouped) == set(IDS), set(IDS) - set(grouped)
    country_file = root / 'rules/india/country.json'
    country = json.loads(country_file.read_text(encoding='utf-8'))
    country.update(schemaVersion='0.2', minEngineVersion='0.2.0')
    country['defaults']['exponents'].update(USD=2, EUR=2, GBP=2)
    for classifier in country['classifiers']:
        if classifier['classification'] == 'failed':
            classifier['when'].pop('none', None)
    banks = []
    count = 0
    for name, slug in sorted(IDS.items(), key=lambda item: item[1]):
        bankid = f'in.{slug}'
        path = root / f'rules/india/{slug}/rules.json'
        # Preserve pilot identity selectors and the independently authored formats.
        bank = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {
            'id': bankid, 'name': name, 'senders': [], 'formats': []}
        bank['senders'] = sorted(set(harvest['senders'].get(name, [])) | set(bank['senders']))
        if slug == 'hdfcmf': bank['senders'] = sorted(set(bank['senders']) | {'HDFCMF-AC'})
        if slug == 'indusind': bank.pop('requires', None)
        formats = [f for f in bank['formats'] if '.template' not in f['id']]
        bank['formats'] = formats
        if slug == 'idfc':
            for fmt in formats:
                if '.account.' in fmt['id']: fmt['requires'] = {'none': ['monthly interest']}
        cases = []
        mutations = []
        signatures = {}
        for n, sample in enumerate(grouped[name].values(), 1):
            fmt, candidate, differences, mutation_body, mutation_candidate = template(sample, bankid, n)
            signature = json.dumps([fmt.get('defaults'), fmt['tokens']], sort_keys=True)
            if signature in signatures:
                prior = signatures[signature]
                assert prior['output'] == fmt['output'] and prior['channel'] == fmt['channel'], (name, n)
                ruleid = prior['id']
            else:
                formats.append(fmt)
                signatures[signature] = fmt
                ruleid = fmt['id']
                count += 1
            fixture = {'id': f'{slug}-ported-{n:03}', 'country': 'IN', 'bankId': bankid,
                       'provenance': f'Legacy Dart regression: {sample["provenance"]}; see NOTICE.md',
                       'input': {'sender': sample['sender'], 'body': sample['body'],
                                 'receivedAt': '2026-10-07T00:00:00.000Z'},
                       'expected': {'classification': 'completed', 'decision': 'review',
                                    'reason': 'completedNeedsReview', 'packVersion': 1,
                                    'ruleId': ruleid,
                                    'candidate': {**candidate, 'occurredAt': '2026-10-07T00:00:00.000Z'}},
                       'compareLegacy': True}
            if differences:
                fixture['legacyDifferences'] = differences
            cases.append(fixture)
            mutations.append({**fixture, 'id': f'{slug}-variables-{n:03}',
                              'provenance': 'Generated variable-field regression; not an upstream SMS',
                              'compareLegacy': False,
                              'input': {**fixture['input'], 'body': mutation_body},
                              'expected': {**fixture['expected'], 'candidate': {**mutation_candidate, 'occurredAt': fixture['input']['receivedAt']}}})
            mutations[-1].pop('legacyDifferences', None)
        write_json(path, bank)
        write_json(root / f'tests/conformance/india/{slug}/ported.json', cases)
        write_json(root / f'tests/conformance/india/{slug}/variables.json', mutations)
        base = cases[0]
        rejections = []
        for classification, prefix in [('security', 'Your OTP is 123456. '), ('promotional', 'Exclusive offer: apply now. '), ('failed', 'Payment failed. '), ('pending', 'Payment pending. '), ('future', 'Will be debited. '), ('notice', 'Statement generated. ')]:
            rejections.append({'id': f'{slug}-reject-{classification}', 'country': 'IN', 'bankId': bankid,
                               'provenance': 'Generated adversarial prefix, not an upstream SMS',
                               'input': {**base['input'], 'body': prefix + base['input']['body']},
                               'expected': {'classification': classification, 'decision': 'ignored', 'reason': classification,
                                            'packVersion': 1, 'ruleId': None, 'candidate': None}, 'compareLegacy': False})
        for label, sender, body, reason in [('unknown-sender', 'UNREGISTERED', base['input']['body'], 'unregisteredSender'),
                                            ('promotion-sender', 'VM-'+bank['senders'][0]+'-P', base['input']['body'], 'unregisteredSender'),
                                            ('balance-only', base['input']['sender'], 'Available balance INR 9876.54.', 'noMatchingFormat')]:
            rejections.append({'id': f'{slug}-reject-{label}', 'country': 'IN', 'bankId': bankid,
                               'provenance': 'Generated rejection regression, not an upstream SMS',
                               'input': {**base['input'], 'sender': sender, 'body': body},
                               'expected': {'classification': 'unknown', 'decision': 'ignored', 'reason': reason,
                                            'packVersion': 1, 'ruleId': None, 'candidate': None}, 'compareLegacy': False})
        for n, rejected in enumerate([r for r in harvest['rejections'] if r['bankName'] == name], 1):
            text = normalize(rejected['body']).lower()
            classification, reason = 'unknown', 'noMatchingFormat'
            for classifier in country['classifiers']:
                if any(phrase.lower() in text for phrase in classifier['when']['any']):
                    classification = reason = classifier['classification']
                    break
            if rejected['sender'].endswith('-P'): classification, reason = 'unknown', 'unregisteredSender'
            rejections.append({'id': f'{slug}-legacy-rejection-{n:03}', 'country': 'IN', 'bankId': bankid,
                               'provenance': f'Legacy rejected literal: {rejected["provenance"]}; see NOTICE.md',
                               'input': {**base['input'], 'sender': rejected['sender'], 'body': rejected['body']},
                               'expected': {'classification': classification, 'decision': 'ignored', 'reason': reason,
                                            'packVersion': 1, 'ruleId': None, 'candidate': None}, 'compareLegacy': True})
        write_json(root / f'tests/conformance/india/{slug}/rejections.json', rejections)
        banks.append(f'{slug}/rules.json')
    country['banks'] = banks
    write_json(country_file, country)
    print(f'Migrated {len(banks)} bank/service families, {count} templates.')


if __name__ == '__main__':
    main()



