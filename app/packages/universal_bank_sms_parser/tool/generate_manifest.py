"""Generate or check deterministic, unsigned development distribution metadata."""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
entries = []
versions = set()
schema_versions = set()
engine_versions = set()
for pack_path in sorted((root / 'distribution/packs').rglob('*.json')):
    data = pack_path.read_bytes()
    pack = json.loads(data)
    versions.add(pack['packVersion'])
    schema_versions.add(pack['schemaVersion'])
    engine_versions.add(pack['minEngineVersion'])
    bank_ids = {rule['bankId'] for rule in pack['rules']}
    if len(bank_ids) != 1:
        raise SystemExit('Each runtime file must contain exactly one bank.')
    entries.append({
        'id': next(iter(bank_ids)),
        'countries': sorted({rule['country'] for rule in pack['rules']}),
        'path': pack_path.relative_to(root / 'distribution').as_posix(),
        'sha256': hashlib.sha256(data).hexdigest(),
        'sizeBytes': len(data),
    })
if not entries or any(len(values) != 1 for values in [versions, schema_versions, engine_versions]):
    raise SystemExit('Packs must share version requirements and be nonempty.')
manifest = {
    'schemaVersion': next(iter(schema_versions)),
    'minEngineVersion': next(iter(engine_versions)),
    'packVersion': next(iter(versions)),
    'status': 'development',
    'signature': None,
    'packs': entries,
}
path = root / 'distribution/manifest.json'
if sys.argv[1:] == ['--check']:
    if not path.exists() or json.loads(path.read_text(encoding='utf-8')) != manifest:
        raise SystemExit('Manifest does not match the compiled pack; regenerate it.')
    print('Manifest matches the compiled pack.')
elif sys.argv[1:]:
    raise SystemExit('Usage: python tool/generate_manifest.py [--check]')
else:
    path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print('Generated unsigned development manifest.')
