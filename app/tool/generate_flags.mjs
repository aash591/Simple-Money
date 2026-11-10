// Regenerates assets/flags/*.png from the flag artwork shipped by the
// `country_flags` package. The app draws flags at ~32px, where the source
// vectors' detail is invisible but not free — Serbia's alone was 501KB — so
// they are rasterised once here instead of being decoded on device.
//
// Only territories present in assets/data/currencies.json are emitted.
//
// Run when the currency list changes:
//   npm install sharp
//   node tool/generate_flags.mjs
//
// SVG_DIR points into the pub cache; update the version if country_flags is
// re-added and upgraded, or point it at any other set of <alpha-2>.svg files.

import sharp from 'sharp';
import { readFileSync, readdirSync, mkdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const APP = dirname(dirname(fileURLToPath(import.meta.url)));
const PUB_CACHE =
  process.env.PUB_CACHE || join(homedir(), 'AppData/Local/Pub/Cache');
const SVG_DIR = join(
  PUB_CACHE,
  'hosted/pub.dev/country_flags-4.1.2/res/svg',
);
const OUT = join(APP, 'assets/flags');
const HEIGHT = 128;

const currencies = JSON.parse(
  readFileSync(join(APP, 'assets/data/currencies.json'), 'utf8'),
);
const territories = [
  ...new Set(currencies.map((c) => c.territory.toLowerCase())),
].sort();

mkdirSync(OUT, { recursive: true });
const available = new Set(
  readdirSync(SVG_DIR)
    .filter((f) => f.endsWith('.svg'))
    .map((f) => f.slice(0, -4)),
);

const missing = [];
let total = 0;

for (const t of territories) {
  if (!available.has(t)) {
    missing.push(t);
    continue;
  }
  const dest = join(OUT, `${t}.webp`);
  await sharp(join(SVG_DIR, `${t}.svg`), { density: 300 })
    .resize({ height: HEIGHT })
    .webp({ lossless: true, effort: 6 })
    .toFile(dest);
  total += statSync(dest).size;
}

console.log(`png written:   ${territories.length - missing.length}`);
console.log(`no source svg: ${missing.join(', ') || '(none)'}`);
console.log(`total size:    ${(total / 1024 / 1024).toFixed(2)} MB`);
