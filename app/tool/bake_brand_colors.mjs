// One-time migration for existing Simple Icons WebPs. The fetch script now
// bakes these colors when it rasterizes new SVGs.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const app = dirname(dirname(fileURLToPath(import.meta.url)));
const catalog = readFileSync(join(app, 'lib/domain/brand_icons.dart'), 'utf8');
const brands = join(app, 'assets/icon_packs/brands');
let count = 0;
for (const entry of catalog.split('  BrandIcon(').slice(1)) {
  if (entry.includes('isOriginal: true')) continue;
  const key = entry.match(/^\s*'([^']+)'/)?.[1];
  const hex = entry.match(/Color\(0xFF([0-9A-Fa-f]{6})\)/)?.[1];
  if (!key || !hex) throw new Error(`Incomplete catalog entry: ${entry.slice(0, 80)}`);
  const rgb = [0, 2, 4].map((offset) => parseInt(hex.slice(offset, offset + 2), 16));
  const path = join(brands, `${key}.webp`);
  const { data, info } = await sharp(readFileSync(path)).ensureAlpha().raw()
    .toBuffer({ resolveWithObject: true });
  for (let i = 0; i < data.length; i += 4) {
    data[i] = rgb[0];
    data[i + 1] = rgb[1];
    data[i + 2] = rgb[2];
  }
  const output = await sharp(data, {
    raw: { width: info.width, height: info.height, channels: 4 },
  }).webp({ quality: 90, alphaQuality: 100, effort: 6 }).toBuffer();
  writeFileSync(path, output);
  count++;
}
console.log(`baked colors into ${count} brand WebPs`);
