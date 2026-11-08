"""Country/bank layout shared by the pilot generator and migration."""
import json
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def write_country_source(country, source):
    index = {key: value for key, value in source.items() if key != 'banks'}
    references = []
    for bank in source['banks']:
        name = bank['id'].split('.')[-1]
        reference = f'{name}/rules.json'
        references.append(reference)
        write_json(root / 'rules' / country / reference, bank)
    index['banks'] = references
    write_json(root / 'rules' / country / 'country.json', index)


def write_conformance(fixtures):
    groups = {}
    for fixture in fixtures:
        identifier = fixture['id']
        if identifier.startswith('idfc'):
            country, code, bank = 'india', 'IN', 'idfc'
        elif identifier.startswith('shared-indian'):
            country, code, bank = 'india', 'IN', 'indian'
        elif identifier.startswith('shared-indusind'):
            country, code, bank = 'india', 'IN', 'indusind'
        elif identifier.startswith('parsian'):
            country, code, bank = 'iran', 'IR', 'parsian'
        elif identifier.startswith('thai'):
            country, code, bank = 'thailand', 'TH', 'bangkok'
        else:
            # General adversarial examples use Bandhan's message template.
            country, code, bank = 'india', 'IN', 'bandhan'
        fixture = {**fixture, 'country': code, 'bankId': f'{code.lower()}.{bank}'}
        groups.setdefault((country, bank), []).append(fixture)
    for (country, bank), cases in groups.items():
        write_json(root / 'tests/conformance' / country / bank / 'v0.1.json', cases)
