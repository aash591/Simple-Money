Currency names, country/territory names, and minor units are derived from
[Unicode CLDR](https://github.com/unicode-org/cldr-json), retrieved 2026-09-09.
The bundled list includes current legal tender for each territory, searched
entirely offline. Unicode's license is included alongside the data.

Regenerate deliberately with `python tool/update_currencies.py` from `app/`.
Review currency changes before shipping a new catalog; saved accounts retain
their original minor-unit precision.
