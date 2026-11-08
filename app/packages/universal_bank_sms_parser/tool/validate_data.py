"""Validate shared rule, distribution, input and result data against JSON Schema.

Optional authoring dependency: pip install -r tool/requirements.txt
"""
import json
from pathlib import Path
from jsonschema import Draft202012Validator

root = Path(__file__).resolve().parent.parent


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def main():
    validators = {}
    for file in (root / 'spec').glob('*.schema.json'):
        schema = read(file)
        Draft202012Validator.check_schema(schema)
        validators[file.name] = Draft202012Validator(schema)
    banks = 0
    for file in (root / 'rules').glob('*/country.json'):
        country = read(file)
        validators['country.schema.json'].validate(country)
        sources = []
        for reference in country['banks']:
            bank = read(file.parent / reference)
            validators['bank.schema.json'].validate(bank)
            sources.append(bank)
            banks += 1
        validators['rules.schema.json'].validate({**country, 'banks': sources})
    for file in (root / 'distribution/packs').rglob('*.json'):
        validators['runtime.schema.json'].validate(read(file))
    cases = 0
    for file in (root / 'tests/conformance').rglob('*.json'):
        for fixture in read(file):
            validators['input.schema.json'].validate(fixture['input'])
            validators['result.schema.json'].validate(fixture['expected'])
            cases += 1
    category_cases = 0
    for file in (root / 'tests/categorization').glob('*.json'):
        for fixture in read(file):
            candidate = fixture['input']['candidate']
            validators['input.schema.json'].validate({'sender': 'TESTBANK', 'body': fixture['input']['body'], 'receivedAt': candidate['occurredAt']})
            validators['result.schema.json'].validate({
                'classification': 'completed', 'decision': 'review',
                'reason': 'completedNeedsReview', 'packVersion': 1,
                'ruleId': 'categorization_fixture',
                'candidate': {**candidate, **fixture['expected']},
            })
            category_cases += 1
    print(f'Validated {banks} bank sources/packs, {cases} bank cases and {category_cases} category cases against JSON Schema.')


if __name__ == '__main__':
    main()
