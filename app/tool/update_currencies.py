"""Bundle English currency/territory names and minor units from Unicode CLDR."""
import datetime
import json
import pathlib
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = 'https://raw.githubusercontent.com/unicode-org/cldr-json/main/'

def read(path):
    with urllib.request.urlopen(BASE + path) as response:
        return json.load(response)

data = read('cldr-json/cldr-core/supplemental/currencyData.json')['supplemental']['currencyData']
names = read('cldr-json/cldr-numbers-full/main/en/currencies.json')['main']['en']['numbers']['currencies']
territories = read('cldr-json/cldr-localenames-full/main/en/territories.json')['main']['en']['localeDisplayNames']['territories']
today = datetime.date.today().isoformat()
# The bank SMS parser reads Iranian rial amounts with two decimals (the Iran
# pack's "exponents": {"IRR": 2}) and the app stores SMS-detected accounts
# with two digits. Keep the list the same, or a hand-made rial account could
# not take those messages.
DIGITS_OVERRIDE = {'IRR': 2}
rows = []
for territory, entries in data['region'].items():
    if len(territory) != 2 or territory not in territories:
        continue
    for entry in entries:
        for code, validity in entry.items():
            if validity.get('_tender') == 'false' or validity.get('_from', '') > today or validity.get('_to', '9999') < today:
                continue
            rows.append(dict(country=territories[territory], territory=territory, code=code,
                             name=names[code]['displayName'],
                             digits=DIGITS_OVERRIDE.get(code, int(data['fractions'].get(code, data['fractions']['DEFAULT'])['_digits']))))
rows.sort(key=lambda row: (row['country'], row['code']))
target = ROOT / 'assets/data'
target.mkdir(parents=True, exist_ok=True)
(target / 'currencies.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
with urllib.request.urlopen(BASE + 'LICENSE') as response:
    (target / 'UNICODE-LICENSE.txt').write_bytes(response.read())
print(f'Bundled {len(rows)} country/currency entries.')
