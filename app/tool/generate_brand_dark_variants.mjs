// Explicit, per-logo dark treatments selected after viewing the normal WebPs
// on the picker's charcoal tile. Run after fetch_brand_icons.mjs.
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const app = dirname(dirname(fileURLToPath(import.meta.url)));
const brands = join(app, 'assets/icon_packs/logos');
const rawBrands = join(app, '../assets_raw/icon_packs_raw/logos');
const dartOutput = join(app, 'lib/domain/brand_dark_icons.dart');
const catalog = readFileSync(join(app, 'lib/domain/brand_icons.dart'), 'utf8');
// Entries are read one at a time: the formatter wraps long ones over several
// lines, so a single-line pattern would silently miss them.
const bankCountries = new Map(
  catalog.split(/BrandIcon\(\s*/).slice(1).flatMap((entry) => {
    const key = entry.match(/^'([^']+)'/)?.[1];
    const country = entry.match(/isBank: true,\s*bankCountry: "([^"]+)"/)?.[1];
    return key != null && country != null ? [[key, country]] : [];
  }),
);
const countryFolder = (country) => country
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, '_')
  .replace(/^_|_$/g, '');
const brandFile = (base, key, suffix = '') => {
  const country = bankCountries.get(key);
  const directory = country == null
    ? join(base, 'brands')
    : join(base, 'banks', countryFolder(country));
  return join(directory, `${key}${suffix}.webp`);
};

// Each entry is an art-direction decision for this mark, not an automatic
// luminance conversion over the catalog. Accents remain their source colors.
const treatments = [
  { key: 'tataplayfiber', treatment: 'white' },
  { key: 'cred', treatment: 'white' },
  { key: 'zee5', treatment: 'white' },
  { key: 'ola', treatment: 'white' },
  { key: 'kseb', treatment: 'white', keepAccent: (r, g, b) => g > 70 && g > r * 1.2 && g > b * 1.1 },
  { key: 'asianetbroadband', treatment: 'white', keepAccent: (r, g, b) => r > 60 && r > g * 1.25 && r > b * 1.15 },
  { key: 'openai', treatment: 'white' },
  { key: 'amazon', treatment: 'white', keepAccent: (r, g, b) => r > 90 && g > 70 && b < 60 },
  { key: 'bri', treatment: 'white' },
  { key: 'bca', treatment: 'white' },
  { key: 'indianoverseas', treatment: 'white' },
  { key: 'kotak811', treatment: 'white', keepAccent: (r, g, b) => r > 60 && r > g * 1.25 && r > b * 1.15 },
  { key: 'cityunionbank', treatment: 'white' },
  { key: 'sbicard', treatment: 'white', keepAccent: (r, g, b) => b > 120 && g > 80 && g > r * 1.3 },
  { key: 'appletv', treatment: 'white' },
  { key: 'uber', treatment: 'white' },
  { key: 'notion', treatment: 'white' },
  { key: 'github', treatment: 'white' },
  { key: 'paypal', treatment: 'whiteBadge' },
  { key: 'paytm', treatment: 'white' },
  { key: 'jio', treatment: 'jioBlue', url: 'https://rilstaticasset.akamaized.net/sites/default/files/2024-03/PNG_download_Jio-Logo-Mono-Black.png' },
  { key: 'visa', treatment: 'white' },
  { key: 'jcb', treatment: 'white' },
  { key: 'dinersclub', treatment: 'white' },
  { key: 'square', treatment: 'white' },
  { key: 'revolut', treatment: 'white' },
  { key: 'vivawallet', treatment: 'white' },
  { key: 'applepay', treatment: 'white' },
  { key: 'razorpay', treatment: 'white' },
  { key: 'tradingview', treatment: 'white' },
  { key: 'monzo', treatment: 'white' },
  { key: 'samsungpay', treatment: 'white' },
  { key: 'payback', treatment: 'white' },
  { key: 'bankofamerica', treatment: 'white' },
  { key: 'deutschebank', treatment: 'white' },
  { key: 'hdfcbank', treatment: 'white' },
  { key: 'thurgauerkantonalbank', treatment: 'white' },
  { key: 'bancoagricola', treatment: 'white' },
  { key: 'lloydsbank', treatment: 'white' },
  { key: 'emiratesnbd', treatment: 'white' },
  { key: 'bankofscotland', treatment: 'white' },
  { key: 'virginmoneyuk', treatment: 'whiteCircle' },
  // Parser-pack banks whose dark navy/black/purple artwork vanishes on charcoal.
  { key: 'nationalsavingsbank', treatment: 'white', keepAccent: (r, g, b) => r > 170 && g > 120 && b < 80 },
  { key: 'sabb', treatment: 'white', keepAccent: (r, g, b) => r > 150 && g < 90 && b < 90 },
  { key: 'parsian', treatment: 'white', keepAccent: (r, g, b) => r > 110 && r > g * 1.25 && r > b * 1.5 },
  { key: 'discovercard', treatment: 'white', keepAccent: (r, g, b) => r > 200 && g > 80 && g < 190 && b < 110 },
  { key: 'emiratesislamic', treatment: 'white' },
  { key: 'uobthailand', treatment: 'white', keepAccent: (r, g, b) => r > 150 && g < 90 && b < 90 },
  { key: 'd360bank', treatment: 'white', keepAccent: (r, g, b) => r > 200 && g < 140 && b < 130 && r > g * 1.5 },
  { key: 'opay', treatment: 'white', keepAccent: (r, g, b) => g > 140 && r < 90 },
  { key: 'citibank', treatment: 'white', keepAccent: (r, g, b) => r > 150 && g < 90 && b < 90 },
  { key: 'navyfederal', treatment: 'white' },
  { key: 'banquesaudifransi', treatment: 'white' },
  // These official light-surface marks are solid black and disappear on the
  // app's charcoal, navy, and true-black themes.
  { key: 'goldmansachs', treatment: 'white' },
  { key: 'investec', treatment: 'white' },
  { key: 'morganstanley', treatment: 'white' },
  // XP's black tile with white lettering vanishes on dark surfaces: swap the
  // two, which is the brand's own white-tile form.
  { key: 'xp', treatment: 'invertTile' },
  // Black app tiles from crypto exchanges and wallets: same swap.
  { key: 'okx', treatment: 'invertTile' },
  { key: 'bybit', treatment: 'invertTile' },
  { key: 'ledger', treatment: 'invertTile' },
  { key: 'indmoney', treatment: 'invertTile' },
  { key: 'bitso', treatment: 'white' },
  { key: 'hargreaveslansdown', treatment: 'white' },
];
const keys = treatments.map(({ key }) => key);
const onlyKeys = process.argv.includes('--only')
  ? new Set(process.argv.slice(process.argv.indexOf('--only') + 1))
  : null;
const selectedTreatments = onlyKeys == null
  ? treatments
  : treatments.filter(({ key }) => onlyKeys.has(key));
if (onlyKeys != null && selectedTreatments.length !== onlyKeys.size) {
  throw new Error('Unknown dark brand key in --only selection');
}

// Remove only companions formerly generated by this script.
if (existsSync(dartOutput)) {
  const oldKeys = [...readFileSync(dartOutput, 'utf8')
    .matchAll(/^\s+'([a-z0-9]+)',?$/gm)].map((match) => match[1]);
  for (const key of oldKeys) {
    if (!keys.includes(key)) rmSync(brandFile(brands, key, '_dark'), { force: true });
  }
}

for (const { key, treatment, keepAccent, url } of selectedTreatments) {
  const output = brandFile(brands, key, '_dark');
  mkdirSync(dirname(output), { recursive: true });
  if (treatment === 'jioBlue') {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Missing official Jio mark, HTTP ${response.status}`);
    const { data, info } = await sharp(Buffer.from(await response.arrayBuffer()))
      .resize(256, 256, { fit: 'contain' }).ensureAlpha().raw()
      .toBuffer({ resolveWithObject: true });
    // The official monochrome mark has a dark circle and white lettering.
    // Use the blue already present in our normal Jio asset for the circle.
    const blue = [10, 41, 133];
    for (let i = 0; i < data.length; i += 4) {
      const white = Math.max(0, Math.min(1, (data[i] - 20) / 235));
      for (let channel = 0; channel < 3; channel++) {
        data[i + channel] = Math.round(blue[channel] * (1 - white) + 255 * white);
      }
    }
    await sharp(data, { raw: { width: info.width, height: info.height, channels: 4 } })
      .webp({ quality: 90, alphaQuality: 100, effort: 6 }).toFile(output);
    continue;
  }

  const { data, info } = await sharp(readFileSync(brandFile(brands, key)))
    .ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  if (treatment === 'white') {
    for (let i = 0; i < data.length; i += 4) {
      if (keepAccent?.(data[i], data[i + 1], data[i + 2])) continue;
      data[i] = 255;
      data[i + 1] = 255;
      data[i + 2] = 255;
    }
  } else if (treatment === 'invertTile') {
    for (let i = 0; i < data.length; i += 4) {
      data[i] = 255 - data[i];
      data[i + 1] = 255 - data[i + 1];
      data[i + 2] = 255 - data[i + 2];
    }
  } else if (treatment !== 'whiteBadge' && treatment !== 'whiteCircle') {
    throw new Error(`Unknown dark treatment for ${key}: ${treatment}`);
  }
  let artwork = sharp(data, { raw: { width: info.width, height: info.height, channels: 4 } });
  if (treatment === 'whiteBadge') {
    // PayPal's blue P sits on white in its own dark-use guidance.
    const mark = await artwork.resize(180, 180).png().toBuffer();
    const badge = Buffer.from('<svg width="256" height="256"><rect x="8" y="8" width="240" height="240" rx="40" fill="white"/></svg>');
    artwork = sharp(badge).composite([{ input: mark, left: 38, top: 38 }]);
  } else if (treatment === 'whiteCircle') {
    // Virgin Money's official vector uses transparent knockout lettering.
    // Restore the intended white lettering on dark tiles without adding a
    // rectangular presentation background.
    const mark = await artwork.png().toBuffer();
    const backing = Buffer.from(
      '<svg width="256" height="256"><circle cx="128" cy="128" r="118" fill="white"/></svg>',
    );
    artwork = sharp(backing).composite([{ input: mark, left: 0, top: 0 }]);
  }
  await artwork.webp({ quality: 90, alphaQuality: 100, effort: 6 }).toFile(output);
}

writeFileSync(dartOutput,
  `// GENERATED by tool/generate_brand_dark_variants.mjs - do not hand-edit.\n` +
  `const darkBrandIconKeys = <String>{\n${keys.map((key) => `  '${key}',`).join('\n')}\n};\n`);
mkdirSync(rawBrands, { recursive: true });
for (const { key } of selectedTreatments) {
  const rawOutput = brandFile(rawBrands, key, '_dark');
  mkdirSync(dirname(rawOutput), { recursive: true });
  copyFileSync(brandFile(brands, key, '_dark'), rawOutput);
}
console.log(`generated ${selectedTreatments.length} individually selected dark brand variants`);
