// Downloads brand/merchant logos from Simple Icons (CC0-licensed SVG marks,
// https://github.com/simple-icons/simple-icons) for the "which service is
// this subscription/transaction for" icon picker — a different concept from
// the custom 3D category artwork: the artwork itself must stay in its
// official, unmodified form (recoloring or restyling a trademark is a
// brand-guideline problem, not just an aesthetic one), so they're rendered
// on their own white badge in the app rather than reworked to match the
// category icon style. See ui/components/app_icon.dart.
//
// The fetched/processed SVG is rasterized here (via sharp/librsvg) to a
// 256x256 lossy WebP before being written — same geometry and color as the
// source mark, just a fixed-resolution raster instead of a vector, matching
// the format used by every other bundled icon. 256px covers every on-screen
// size this app draws a brand mark at, at up to ~4x device pixel ratio; the
// app applies its runtime tint the same way it tints any other Image (color
// + BlendMode.srcIn against the raster's alpha) instead of an SVG
// colorFilter. Sharp performs the rasterization directly through librsvg.
//
// CC0 covers Simple Icons' own SVG artwork; it does not waive the
// trademarks themselves (see their LICENSE.md) — using a brand's mark to
// identify that brand/service (e.g. labelling a transaction "Netflix") is
// the intended, standard use, same as every budgeting app that shows
// merchant logos. Don't use these to imply endorsement.
//
// Run when the brand list changes:
//   npm install sharp
//   node tool/fetch_brand_icons.mjs
import { copyFileSync, existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const APP = dirname(dirname(fileURLToPath(import.meta.url)));
const OUT_DIR = join(APP, 'assets/icon_packs/logos');
const RAW_OUT_DIR = join(APP, '../assets_raw/icon_packs_raw/logos');
const DART_OUT = join(APP, 'lib/domain/brand_icons.dart');
const SOURCE_DIR = join(APP, '../icons/bank_sources');
const RAW = 'https://raw.githubusercontent.com/simple-icons/simple-icons/develop';

// Mark-only crop boxes for source files that contain a horizontal wordmark.
// Values are applied to the generated SVG itself, producing a square icon
// asset with no bank-name fragments. Icon-only sources need no crop.
const BANK_MARK_CROPS = {
  saxo: '0 0 1024 768', // the tile as drawn, without the empty canvas around it
  ig: '0 25 150 150',
  scalablecapital: '906 146 404 404', // teal S on its dark tile; wordmark dropped
  bitso: '-1 -1 33 32', // symbol only
  alrajhibank: '545 279.3 276 285.28',
  bancopromerica: '10.6 6 6 5.4', // star symbol only; wordmark sits below y=12
  banquesaudifransi: '0 0 110 155.11063',
  bsnl: '95 0 180 135',
  bangkokbank: '0 0 151 200', // drop symbol only (viewBox is 803x200)
  btn: '-10 -10 185 177.35',
  mandiri: '22 -0.5 39 9',
  nationalbankofegypt: '440 0 138 153.21',
  cimbthai: '0 0 55 68.29',
  commercialbankofceylon: '45 50 108 75',
  enpara: '0 0 44 45',
  gtbank: '101 0 299 303', // orange GTBank tile; drops 'Guaranty Trust Bank plc / RC'
  huntingtonbank: '0 0 48 49.3',
  kasikornbank: '48 0 144 144',
  krungsri: '51 51 139 139', // yellow symbol only (tile, wordmark, MUFG line dropped)
  mellatbank: '20 0 180 160',
  moniepoint: '0 0 160 152.98',
  navyfederal: '56 0 18 16',
  orangemoney: '0 0 210 115',
  tbank: '0 0 32 34',
  zenithbank: '-15 -15 430 330',
  tmb: '0 0 95 61.647914',
};

function inlineClassFills(svg) {
  const fills = new Map();
  for (const match of svg.matchAll(/\.([\w-]+)\s*\{([^}]*)\}/gi)) {
    const fill = match[2].match(/(?:^|;)\s*fill:\s*(#[0-9a-f]{3,8})/i)?.[1];
    if (fill) fills.set(match[1], fill);
  }
  for (const [className, fill] of fills) {
    svg = svg.replaceAll(`class="${className}"`, `fill="${fill}"`);
  }
  return svg.replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, '');
}

function isolateBankMark(key, svg) {
  svg = inlineClassFills(svg);
  if (key === 'krungsri') {
    // The upstream lockup places the identity on a neutral presentation
    // rectangle. The rectangle is not part of Krungsri's yellow symbol.
    svg = svg.replace(/<rect\b(?=[^>]*width="240")(?=[^>]*height="316\.57")[^>]*\/?\s*>/i, '');
  }
  if (key === 'bajajfinance') {
    // CompaniesLogo's square source is the white reverse mark on a blue tile.
    // Drop the tile and use the same mark in its official blue for transparent
    // light surfaces, matching the positive form used by the brand wordmark.
    svg = svg.replace(/<path\b(?=[^>]*fill="#085fac")[^>]*\/>/i, '');
    svg = svg.replace(/fill="#fff"/gi, 'fill="#085fac"');
  }
  if (key === 'bni') {
    // The provider's square symbol has a solid white canvas as its first path.
    // Remove the canvas so the actual orange mark remains transparent.
    svg = svg.replace(/<path\b(?=[^>]*id="Path 11")[^>]*\/>/i, '');
  }
  if (key === 'bca') {
    // Wikimedia's source contains the BCA emblem followed by the BCA letters.
    // Keep only the six paths that form the standalone emblem.
    const paths = [...svg.matchAll(/<path\b[\s\S]*?\/>/gi)]
      .map((match) => match[0])
      .filter((path) => /id="path(?:20|22|24|26|28|30)"/.test(path));
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-14 -14 341 341">${paths.join('')}</svg>`;
  }
  if (key === 'firstabudhabibank') {
    // Keep the blue FAB letters (paths 19-21) and the red swoosh (path 41).
    // The rest is Arabic and English name text around the mark.
    const paths = [...svg.matchAll(/<path\b[\s\S]*?\/>/gi)].map((match) => match[0]);
    const keep = [19, 20, 21, 41].map((i) => paths[i]);
    if (keep.some((path) => path == null)) throw new Error('Could not isolate FAB mark');
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="140 50 595 340">${keep.join('')}</svg>`;
  }
  if (key === 'commercialbankofceylon') {
    // The source reverses the standalone monogram in white over a long blue
    // presentation strip. Remove the strip and render the original monogram
    // paths in the bank's official blue on transparency.
    svg = svg.replace(
      /<path\b(?=[^>]*fill="#(?:4CB748|006FBA)")[^>]*\/>/gi,
      '',
    );
    return svg.replace(/fill="white"/gi, 'fill="#006FBA"');
  }
  if (key === 'mandiri') {
    // The compact identity is the three gold waves. The blue wordmark begins
    // immediately below them, so remove its paths instead of relying on a
    // sub-pixel viewBox boundary that can leave a detached blue fragment.
    return svg.replace(
      /<path\b(?=[^>]*style="[^"]*fill:#003a70)[^>]*\/>/gi,
      '',
    );
  }
  if (key === 'siamcommercialbank') {
    // Keep the gold Bodhi-leaf/spade identity only. The source SVG also
    // contains Thai/English wordmarks and a purple presentation tile.
    const mark = [...svg.matchAll(/<path\b[^>]*\/>/gi)]
      .map((match) => match[0])
      .find((path) => /fill="#feac00"/i.test(path));
    if (!mark) throw new Error('Could not isolate Siam Commercial Bank mark');
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="170 6 64 62">${mark}</svg>`;
  }
  return svg;
}


// ---- "visual" sources: any SVG/PNG/JPG logo, normalised the same way ----
// 1. render (SVG at ~1400px) or decode, 2. flood-fill the white/transparent
// background from the edges (interior whites such as text on a colour tile are
// kept), 3. trim to the content box, 4. optionally crop to the main symbol
// using fractions of that content box, 5. trim again, pad, fit in a square.
// VISUAL_CROPS = [left, top, right, bottom] fractions, chosen by looking at the
// source: keep only the recognizable main mark, drop side text/taglines.
const VISUAL_CROPS = {
  // Major US/UK banks: use the official standalone symbol from wide lockups.
  usbank: [0, 0, 0.24, 1],
  pncbank: [0, 0, 0.30, 1],
  truist: [0.72, 0, 1, 1],
  tdbank: [0, 0, 0.34, 1],
  fifththird: [0, 0, 0.17, 1],
  bmo: [0.62, 0, 1, 1],
  citizensbank: [0, 0, 0.18, 1],
  mtbank: [0, 0, 0.50, 1],
  keybank: [0.67, 0, 1, 1],
  regionsbank: [0, 0, 0.23, 1],
  santanderus: [0, 0, 0.20, 1],
  bnymellon: [0, 0, 0.25, 0.55],
  statestreet: [0, 0, 0.25, 1],
  northerntrust: [0, 0, 0.22, 1],
  hsbcuk: [0, 0, 0.42, 1],
  bankofscotland: [0, 0, 0.12, 1],
  nationwideuk: [0, 0, 0.18, 1],
  banksyariahindonesia: [0, 0, 0.43, 1],
  cimbniaga: [0, 0, 0.16, 1],
  ocbcindonesia: [0, 0, 0.25, 1],
  permatabank: [0, 0, 0.20, 1],
  danamon: [0, 0, 1, 0.46],
  capitec: [0, 0, 0.30, 1],
  banquemisr: [0, 0, 0.30, 1],
  qnbegypt: [0, 0, 0.30, 1],
  arabafricanbank: [0, 0, 0.24, 1],
  attijariwafa: [0.20, 0, 0.80, 0.56],
  bcpgroup: [0.72, 0, 1, 1],
  bankofafrica: [0.84, 0, 1, 1],
  creditagricolemaroc: [0, 0, 0.34, 0.82],
  cihbank: [0.30, 0, 0.50, 1],
  sahambank: [0.70, 0, 1, 1],
  uba: [0.72, 0, 1, 0.78],
  firstbanknigeria: [0.746, 0, 1, 1],
  cpaalgeria: [0, 0, 1, 1],
  bdlalgeria: [0.72, 0, 1, 1],
  mcbmauritius: [0, 0, 0.34, 1],
  bgfibank: [0.20, 0, 0.50, 0.58],
  bancoagricola: [0, 0, 1, 0.78],
  zemenbank: [0, 0, 0.28, 1],
  opay: [0, 0, 0.24, 1],
  emiratesnbd: [0, 0, 1, 1],
  uobthailand: [0, 0, 0.20, 1],
  nationalsavingsbank: [0, 0, 1, 1],
  kcbkenya: [0, 0, 0.43, 1],
  virginmoneyuk: [0.24, 0, 0.45, 1],
  arabbank: [0.5, 0, 1, 0.85],
  bracbank: [0, 0, 0.13, 0.58],
  faysalbank: [0.745, 0, 1, 1],
  sabb: [0.39, 0, 0.61, 1],
  saudinationalbank: [0, 0, 0.22, 0.25],
  crdbbank: [0, 0, 1, 0.85],
  emiratesislamic: [0, 0, 0.2, 1],
  equitybank: [0, 0, 0.2, 1],
  nationstrustbank: [0, 0, 0.29, 1],
  parsian: [0.2, 0, 0.7, 0.55],
  keralabank: [0, 0, 0.29, 0.77], // '1' dot-matrix symbol only
  keralagramin: [0, 0, 1, 0.78], // diamond G symbol only; Malayalam/English name dropped
};
const wikiUpload = (project, file) => {
  const normalized = file.replaceAll(' ', '_');
  const digest = createHash('md5').update(normalized).digest('hex');
  const encoded = encodeURIComponent(normalized);
  // Wikimedia throttles repeated original-file downloads but explicitly
  // supports standard thumbnail widths. 500px is ample for a 256px asset.
  const thumbnailName = normalized.toLowerCase().endsWith('.svg')
    ? `500px-${encoded}.png`
    : `500px-${encoded}`;
  return `https://upload.wikimedia.org/wikipedia/${project}/thumb/${digest[0]}/${digest.slice(0, 2)}/${encoded}/${thumbnailName}`;
};
const ENWIKI_LOCAL_FILES = new Set([
  'BRAC Bank Limited Logo.svg',
  'Emirates Islamic Bank Logo.png',
  'First-Bank.svg',
  'Halifax logo.svg',
  'KCB Bank Kenya Limited logo.png',
  'Krung Thai Bank logo.svg',
  'Logo GSB Thailand.svg',
  'Mauritius Commercial Bank logo.svg',
  'Metro Bank logo.svg',
  'National Savings Bank logo.png',
  'Nationwide Building Society logo 2023.svg',
  'Nations Trust Bank logo.png',
  'Standard Bank of South Africa logo.png',
  'Parsian Bank logo.png',
  'Virgin Money.svg',
]);
const COMMONS = (file) => wikiUpload('commons', file);
const ENWIKI = (file) => wikiUpload(ENWIKI_LOCAL_FILES.has(file) ? 'en' : 'commons', file);

async function fetchBytes(url) {
  // Fail visibly on throttling instead of making a focused generation run
  // appear hung for several minutes. The caller can retry after Retry-After.
  const res = await fetch(url, {
    headers: { 'User-Agent': 'SimpleMoneyIconTool/1.0 (brand logo sourcing)' },
    signal: AbortSignal.timeout(15000),
  });
  if (res.ok) return Buffer.from(await res.arrayBuffer());
  const retryAfter = res.headers.get('retry-after');
  const retryHint = retryAfter == null ? '' : `; retry after ${retryAfter}s`;
  throw new Error(`HTTP ${res.status} for ${url}${retryHint}`);
}

async function renderVisual(key, input, isSvg) {
  if (key === 'esafbank' && isSvg) {
    // The official source is a wide lockup. Preserve its original blue symbol
    // and red ESAF paths, but stack the short wordmark below the symbol so the
    // identity stays recognizable and readable in a square picker tile.
    const source = input.toString('utf8');
    const cropSvg = (viewBox) => source.replace(/<svg\b[^>]*>/i, (tag) => {
      const normalized = tag
        .replace(/\s(?:width|height|viewBox)=("[^"]*"|'[^']*')/gi, '')
        .replace(/>$/, '');
      return `${normalized} viewBox="${viewBox}">`;
    });
    const symbol = await sharp(Buffer.from(cropSvg('0 0 757 557')), { density: 300 })
      .resize(154, 114, { fit: 'contain', background: '#00000000' })
      .png().toBuffer();
    const wordmark = await sharp(Buffer.from(cropSvg('894 0 1793 557')), { density: 300 })
      .resize(220, 68, { fit: 'contain', background: '#00000000' })
      .png().toBuffer();
    return sharp({ create: { width: 256, height: 256, channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 } } })
      .composite([
        { input: symbol, left: 51, top: 18 },
        { input: wordmark, left: 18, top: 157 },
      ])
      .webp({ quality: 90, alphaQuality: 100, effort: 6 });
  }
  let image;
  if (isSvg) {
    const meta = await sharp(input).metadata();
    image = sharp(input, { density: Math.min(2400, (72 * 1400) / meta.width) });
  } else {
    image = sharp(input);
  }
  const { data, info } = await image.ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const { width: W, height: H } = info;
  if (key === 'bancoagricola') {
    // The current official app icon contains the bank's neutral three-bar
    // identity plus decorative colored arcs and an "SV" app label. Keep the
    // original bar pixels and their antialiasing; the crop below drops "SV".
    for (let i = 0; i < data.length; i += 4) {
      const high = Math.max(data[i], data[i + 1], data[i + 2]);
      const low = Math.min(data[i], data[i + 1], data[i + 2]);
      if (high - low > 14 || high > 210) {
        data[i + 3] = 0;
      } else if (high > 80) {
        data[i + 3] = Math.min(data[i + 3], Math.round((210 - high) * 255 / 130));
      }
    }
  }
  if (key === 'nationalsavingsbank') {
    // The high-resolution source overlaps its round seal with the adjacent
    // NSB letters and arrow. A circular isolation keeps the complete original
    // seal while removing those neighboring lockup elements.
    const cx = W * 0.67;
    const cy = H * 0.36;
    const radius = H * 0.36;
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        if (Math.hypot(x - cx, y - cy) > radius) {
          data[(y * W + x) * 4 + 3] = 0;
        }
      }
    }
  }
  // Lloyds' official app artwork is the current black-horse emblem on its
  // flat green app tile. Treat that tile color like the white page backgrounds
  // used by the other visual sources, without altering the horse itself.
  const lloydsBackground = key === 'lloydsbank'
    ? [data[0], data[1], data[2]]
    : null;
  const isWhite = (i) => data[i + 3] < 8 ||
    (data[i + 3] > 200 && data[i] > 236 && data[i + 1] > 236 && data[i + 2] > 236) ||
    (lloydsBackground != null && Math.hypot(
      data[i] - lloydsBackground[0],
      data[i + 1] - lloydsBackground[1],
      data[i + 2] - lloydsBackground[2],
    ) < 18);
  const seen = new Uint8Array(W * H);
  const stack = [];
  const push = (x, y) => {
    if (x < 0 || y < 0 || x >= W || y >= H) return;
    const p = y * W + x;
    if (seen[p] || !isWhite(p * 4)) return;
    seen[p] = 1;
    stack.push(p);
  };
  for (let x = 0; x < W; x++) { push(x, 0); push(x, H - 1); }
  for (let y = 0; y < H; y++) { push(0, y); push(W - 1, y); }
  while (stack.length) {
    const p = stack.pop();
    const x = p % W, y = (p - x) / W;
    push(x + 1, y); push(x - 1, y); push(x, y + 1); push(x, y - 1);
  }
  if (lloydsBackground != null) {
    // Convert the app-tile edge antialiasing to alpha so no green halo remains
    // around the extracted black horse on light or dark surfaces.
    for (let i = 0; i < data.length; i += 4) {
      if (data[i + 3] === 0) continue;
      const distance = Math.hypot(
        data[i] - lloydsBackground[0],
        data[i + 1] - lloydsBackground[1],
        data[i + 2] - lloydsBackground[2],
      );
      if (distance < 80) data[i + 3] = Math.round(data[i + 3] * distance / 80);
    }
  }
  let x0 = W, y0 = H, x1 = -1, y1 = -1;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const p = y * W + x;
      if (seen[p]) { data[p * 4 + 3] = 0; continue; }
      if (data[p * 4 + 3] > 10) {
        if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
      }
    }
  }
  if (x1 < 0) throw new Error(`No visible artwork for ${key}`);
  x1 += 1; y1 += 1;
  const crop = VISUAL_CROPS[key];
  let left = x0, top = y0, right = x1, bottom = y1;
  if (crop) {
    const bw = x1 - x0, bh = y1 - y0;
    left = x0 + Math.round(crop[0] * bw); top = y0 + Math.round(crop[1] * bh);
    right = x0 + Math.round(crop[2] * bw); bottom = y0 + Math.round(crop[3] * bh);
  }
  const region = await sharp(data, { raw: { width: W, height: H, channels: 4 } })
    .extract({ left, top, width: right - left, height: bottom - top })
    .png().toBuffer();
  const trimmed = await sharp(region).trim({ threshold: 1 }).png().toBuffer({ resolveWithObject: true });
  return sharp(trimmed.data)
    // Sharp executes geometric operations in a fixed order, so extending by a
    // source-sized pad before resize can produce a canvas larger than 256px.
    // Fit the mark first, then add a fixed 10px clear area on every side.
    .resize(236, 236, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .extend({ top: 10, bottom: 10, left: 10, right: 10, background: '#00000000' })
    .webp({ quality: 90, alphaQuality: 100, effort: 6 });
}

const MARK_ONLY_SVGS = {
  // Clean vector reconstructions from the provider symbols. No enlarged
  // low-resolution pixels, metallic textures, or adjacent wordmark fragments.
  equitas: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><defs><linearGradient id="equitas-ring" x1="8" y1="39" x2="39" y2="8" gradientUnits="userSpaceOnUse"><stop offset=".42" stop-color="#089949"/><stop offset=".58" stop-color="#C6203A"/></linearGradient></defs><circle cx="24" cy="24" r="20" fill="none" stroke="url(#equitas-ring)" stroke-width="2.2" stroke-linecap="round" stroke-dasharray="112 14" transform="rotate(20 24 24)"/><path fill="#214D86" d="M14 14h22v13H24v-5h7v-3H19v14h17v5H14z"/><path fill="#089949" d="M25 44c6.4 0 10.6-1.8 13.5-5.5l3.2-4.1c.7-.9.5-2.2-.4-2.8-.8-.5-1.8-.3-2.5.4l-3.2 3.2c-2.3 2.2-5.2 3.1-8.8 2.9l-3.6-.2c-1.8-.1-2.7 1.9-1.4 3.1z"/></svg>',
  kotak811: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><circle cx="11" cy="14" r="7.5" fill="#F90045"/><circle cx="11" cy="34" r="7.5" fill="#F90045"/><path fill="#263D4A" d="M27 5h8l-7 38h-8zM40 5h8l-7 38h-8z"/></svg>',
  flipkart: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><path fill="#F8E831" d="M8 12h32l-2.2 32H10.2z"/><path d="M16 14V9c0-4.2 3.6-7 8-7s8 2.8 8 7v5" fill="none" stroke="#fff" stroke-width="3.2" stroke-linecap="round"/><path fill="#2874F0" d="M17 16h18l-1 5H23l-.7 3.5H32l-1 5h-9.7L19 41h-6z"/><path fill="#2874F0" d="m32 31 5-3-1 5z"/></svg>',
  microsoft: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><path fill="#F25022" d="M3 3h19v19H3z"/><path fill="#7FBA00" d="M26 3h19v19H26z"/><path fill="#00A4EF" d="M3 26h19v19H3z"/><path fill="#FFB900" d="M26 26h19v19H26z"/></svg>',
  adobe: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><path fill="#FA0F00" d="M3 3h17L3 45zm42 0H28l17 42zM24 18l10 27h-7l-3-8h-8z"/></svg>',
  dominos: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><g transform="rotate(-45 24 24)"><rect x="10" y="4" width="28" height="40" rx="5" fill="#006491"/><path fill="#E31837" d="M10 24h28v15a5 5 0 0 1-5 5H15a5 5 0 0 1-5-5z"/><circle cx="18" cy="15" r="3" fill="#fff"/><circle cx="18" cy="32" r="3" fill="#fff"/><circle cx="30" cy="36" r="3" fill="#fff"/></g></svg>',
  myntra: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><path fill="#F13AB1" d="M4 43 11 5l13 23L37 5l7 38h-8l-3-20-9 17-9-17-3 20z"/><path fill="#FF905A" d="m11 5 6 11-2 7z"/><path fill="#F05524" d="m37 5-6 11 2 7z"/><path fill="#FD913C" d="m15 23 9 17-5 3z"/><path fill="#7E57C2" d="m33 23-9 17 5 3z"/></svg>',
  uco: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><path fill="#0060A9" d="M9 3h30l6 6v30l-6 6H9l-6-6V9zm2.5 5L8 11.5v25L11.5 40h25l3.5-3.5v-25L36.5 8z"/><circle cx="24" cy="17" r="4" fill="#0060A9"/><path fill="#0060A9" d="M14 23h6l4 4 4-4h6l-7 9v7h-6v-7z"/></svg>',
  ksfe: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><path fill="#83C341" d="m24 3 18 10-9 6-9-5-9 5-9-6z"/><path fill="#173F73" d="m6 15 9 6v10l9 5v10L6 36z"/><path fill="#246BA0" d="m42 15-9 6v10l-9 5v10l18-10z"/><path fill="#fff" d="m24 17 7 4-7 4-7-4zm-7 7 6 3.5v7L17 31zm14 0-6 3.5v7l6-3.5z"/></svg>',
  manappuram: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><circle cx="24" cy="24" r="21" fill="#F9C300" stroke="#B71923" stroke-width="3"/><circle cx="24" cy="24" r="15" fill="none" stroke="#B71923" stroke-width="2"/><path fill="#B71923" d="M12 32V16h6l6 8 6-8h6v16h-6v-8l-6 8-6-8v8z"/></svg>',
};

// key: our stable identifier (persisted in the DB, prefixed "brand:").
// title: exact Simple Icons title, used to look up both the slug and hex.
const BRANDS = [
  { key: 'keralavision', title: 'Kerala Vision Broadband', source: 'raster', image: 'https://play-lh.googleusercontent.com/UScTCZPFw5X6Srkj_Y5MEqzixB3XAk-VNWeKGXv3ZgJfRJbRrPdKgBKFLZs2MF1Lcwmy7cmMuzlYRSuvd8p1jQ=s0', hex: 'E31E24' },
  { key: 'actfibernet', title: 'ACT Fibernet', source: 'remote-svg', url: 'https://www.actcorp.in/themes/custom/actcorp/logo.svg', hex: 'E31E24' },
  { key: 'excitel', title: 'Excitel', source: 'raster', image: 'https://www.excitel.com/wp-content/uploads/2025/04/Excitel_1920x720_2-1-1.png', hex: 'ED1C24' },
  { key: 'hathway', title: 'Hathway', source: 'remote-svg', url: 'https://www.hathway.com/home_images/logo.svg', hex: 'ED1C24' },
  { key: 'tataplayfiber', title: 'Tata Play Fiber', source: 'remote-svg', url: 'https://www.tataplayfiber.com/themes/custom/tpf_combine/logo.svg', hex: 'E10092' },
  { key: 'youbroadband', title: 'YOU Broadband', source: 'raster', image: 'https://youbroadband.in/images/logo.png', hex: 'E31E24' },
  { key: 'meesho', title: 'Meesho', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/meesho-bf855663.svg', hex: '570A43' },
  { key: 'disneyplus', title: 'Disney+', source: 'wikimedia', file: 'Disney+ 2024.svg', hex: '007F80' },
  { key: 'netflix', title: 'Netflix' },
  { key: 'primevideo', title: 'Prime Video', source: 'wikimedia', file: 'Prime Video logo (2024).svg', hex: '0578FF' },
  { key: 'jiohotstar', title: 'JioHotstar', source: 'raster', image: 'https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/jiohotstar.png', hex: 'D4AF74' },
  { key: 'zee5', title: 'ZEE5', source: 'remote-svg', url: 'https://www.zee5.com/images/ZEE5_logo.svg?ver=7.1.7', hex: '000000' },
  { key: 'youtube', title: 'YouTube' },
  { key: 'spotify', title: 'Spotify' },
  { key: 'appletv', title: 'Apple TV' },
  { key: 'uber', title: 'Uber' },
  { key: 'ola', title: 'Ola', source: 'wikimedia', file: 'Ola Cabs logo.svg', hex: '111111' },
  { key: 'rapido', title: 'Rapido', source: 'remote-svg', url: 'https://rapido.bike/images/NewLogo.svg', hex: 'FFD400' },
  { key: 'nammayatri', title: 'Namma Yatri', source: 'remote-svg', url: 'https://www.nammayatri.in/WebsiteIcon.svg', hex: 'F5D547' },
  { key: 'kseb', title: 'KSEB', source: 'wikimedia', file: 'KSEB Logo 2022.svg', hex: '1769AA' },
  { key: 'kwa', title: 'Kerala Water Authority', source: 'raster', image: 'https://kwa.kerala.gov.in/wp-content/uploads/2020/07/og_logo.webp', hex: '087CC1' },
  { key: 'ksrtc', title: 'Kerala KSRTC', source: 'raster', image: 'https://play-lh.googleusercontent.com/KQWlKK7Bg3-CTh4HIBRvd7pW4TzUy4CqTBGLaMT7ljclkkAoHkv47nrSGHRt8Gosvp-yfIEIRC1MEbWPU2hS=s0-br30', hex: 'D71920' },
  { key: 'irctc', title: 'IRCTC', source: 'page-svg', url: 'https://www.irctc.com/', hex: '174A8B' },
  { key: 'redbus', title: 'redBus', source: 'wikimedia', file: 'RedBus Logo (2015-present).svg', hex: 'D7263D' },
  { key: 'bsnl', title: 'BSNL', source: 'wikimedia', file: 'BSNL logo with slogan.svg', hex: '1676B8' },
  { key: 'viindia', title: 'Vi', source: 'wikimedia', file: 'Vodafone Idea logo (2026).svg', hex: 'E60000' },
  { key: 'asianetbroadband', title: 'Asianet Broadband', source: 'raster', image: 'https://asianetbroadband.in/wp-content/uploads/2024/01/AF_logo.png', hex: 'E31E24' },
  { key: 'kochimetro', title: 'Kochi Metro', source: 'wikimedia-raster', file: 'Kochi Metro logo.png', hex: '137B3D' },
  { key: 'delhimetro', title: 'Delhi Metro', source: 'wikimedia', file: 'Delhi Metro logo.svg', hex: 'E1262F' },
  { key: 'nammametro', title: 'Namma Metro', source: 'wikimedia', file: 'Namma metro icon.svg', hex: '7C2A8B' },
  { key: 'chennaimetro', title: 'Chennai Metro', source: 'wikimedia', file: 'Chennai Metro logo.svg', hex: '146CB3' },
  { key: 'hyderabadmetro', title: 'Hyderabad Metro', source: 'wikimedia', file: 'Seal of Hyderabad Metro Rail.svg', hex: 'E1262F' },
  { key: 'mumbaimetro', title: 'Mumbai Metro', source: 'wikimedia-raster', file: 'Mumbai metro Logo.png', hex: 'E31E24' },
  { key: 'swiggy', title: 'Swiggy' },
  { key: 'zomato', title: 'Zomato' },
  { key: 'paypal', title: 'PayPal' },
  { key: 'paytm', title: 'Paytm' },
  { key: 'phonepe', title: 'PhonePe' },
  { key: 'googlepay', title: 'Google Pay' },
  { key: 'airtel', title: 'Airtel' },
  { key: 'jio', title: 'Jio' },
  { key: 'icloud', title: 'iCloud' },
  { key: 'notion', title: 'Notion' },
  { key: 'github', title: 'GitHub' },
  { key: 'whatsapp', title: 'WhatsApp' },
  { key: 'telegram', title: 'Telegram' },
  { key: 'instagram', title: 'Instagram' },
  { key: 'airbnb', title: 'Airbnb' },
  { key: 'claude', title: 'Claude' },
  { key: 'openai', title: 'OpenAI', source: 'wikimedia', file: 'OpenAI logo 2025 (symbol).svg', hex: '000000' },
  { key: 'discord', title: 'Discord' },
  { key: 'dropbox', title: 'Dropbox' },
  { key: 'googledrive', title: 'Google Drive' },
  { key: 'twitch', title: 'Twitch' },
  { key: 'crunchyroll', title: 'Crunchyroll' },
  { key: 'doordash', title: 'DoorDash' },
  { key: 'microsoft', title: 'Microsoft', source: 'inline', hex: '00A4EF' },
  { key: 'adobe', title: 'Adobe', source: 'inline', hex: 'FA0F00' },
  { key: 'dominos', title: "Domino's", source: 'inline', hex: '006491' },
  { key: 'myntra', title: 'Myntra', source: 'inline', hex: 'F13AB1' },
  { key: 'onecard', title: 'OneCard', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/uM8TqrUNuyG7VYh79qZxR23yG7taXVYdtcx3ectRH0HH5EW2cQ99NxhDjiGblTQ_iMY0yeH5aRCP_Ti7BkBE=s512', hex: '111111' },
  { key: 'sbicard', title: 'SBI Card', payment: true, source: 'wikimedia', file: 'SBI Card logo.svg', hex: '00A7DF' },
  { key: 'bobcard', title: 'BOBCARD', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/eXkxY5fRFdO5-18_GEkSYkRIq0RCNa0P6g_txCi2DCvhmAECCydhwyDYFufG8sJqQjSeYmj1-iT7JYjQ6YB-og=s512', hex: 'F9671B' },
  // Cards, wallets, investing, and shopping services.
  { key: 'mastercard', title: 'MasterCard', payment: true },
  { key: 'cred', title: 'CRED', payment: true, source: 'remote-svg', url: 'https://newsroom.cred.club/assets/images/brand/cred-logo-vertical-white-transparent.svg', hex: '000000' },
  { key: 'visa', title: 'Visa', payment: true },
  { key: 'americanexpress', title: 'American Express', payment: true, bank: true, country: 'United States' },
  { key: 'discover', title: 'Discover', payment: true },
  { key: 'jcb', title: 'JCB', payment: true },
  { key: 'dinersclub', title: 'Diners Club', payment: true },
  { key: 'stripe', title: 'Stripe', payment: true },
  { key: 'square', title: 'Square', payment: true },
  { key: 'klarna', title: 'Klarna', payment: true },
  { key: 'revolut', title: 'Revolut', payment: true, bank: true, country: 'United Kingdom' },
  { key: 'wise', title: 'Wise', payment: true },
  { key: 'monzo', title: 'Monzo', payment: true, bank: true, country: 'United Kingdom' },
  { key: 'cashapp', title: 'Cash App', payment: true },
  { key: 'applepay', title: 'Apple Pay', payment: true },
  { key: 'samsungpay', title: 'Samsung Pay', payment: true },
  { key: 'alipay', title: 'Alipay', payment: true },
  { key: 'razorpay', title: 'Razorpay', payment: true },
  { key: 'payoneer', title: 'Payoneer', payment: true },
  { key: 'paysafe', title: 'Paysafe', payment: true },
  { key: 'payback', title: 'PAYBACK', payment: true },
  { key: 'vivawallet', title: 'Viva Wallet', payment: true },
  { key: 'webmoney', title: 'WebMoney', payment: true },
  { key: 'zebpay', title: 'ZebPay', payment: true },
  { key: 'moneygram', title: 'MoneyGram', payment: true },
  { key: 'fampay', title: 'FamPay', payment: true },
  { key: 'afterpay', title: 'Afterpay', payment: true },
  { key: 'picpay', title: 'PicPay', payment: true },
  { key: 'mercadopago', title: 'Mercado Pago', payment: true },
  { key: 'binance', broker: true, title: 'Binance', payment: true },
  { key: 'coinbase', broker: true, title: 'Coinbase', payment: true },
  { key: 'robinhood', broker: true, title: 'Robinhood', payment: true },
  { key: 'zerodha', broker: true, title: 'Zerodha', payment: true },
  { key: 'tradingview', title: 'TradingView', payment: true },
  { key: 'ebay', title: 'eBay', payment: true },
  { key: 'etsy', title: 'Etsy', payment: true },
  { key: 'shopify', title: 'Shopify', payment: true },
  { key: 'shopee', title: 'Shopee', payment: true },
  { key: 'rakuten', title: 'Rakuten', payment: true },
  { key: 'amazon', title: 'Amazon', payment: true, source: 'remote-svg', url: 'https://companieslogo.com/img/orig/AMZN-434f1137.svg?download=true&t=1740113564', hex: 'FF9900' },
  { key: 'flipkart', title: 'Flipkart', payment: true, source: 'inline', hex: '2874F0' },
  // Banks carry country metadata so the picker can expose a short section per
  // market without changing any stable stored icon key.
  { key: 'bankofamerica', title: 'Bank of America', bank: true, country: 'United States' },
  { key: 'starlingbank', title: 'Starling Bank', bank: true, country: 'United Kingdom' },
  { key: 'caixabank', title: 'CaixaBank', bank: true, country: 'Spain' },
  { key: 'deutschebank', title: 'Deutsche Bank', bank: true, country: 'Germany' },
  { key: 'commerzbank', title: 'Commerzbank', bank: true, country: 'Germany' },
  { key: 'thurgauerkantonalbank', title: 'Thurgauer Kantonalbank', bank: true, country: 'Switzerland' },
  { key: 'hdfcbank', title: 'HDFC Bank', bank: true, country: 'India' },
  { key: 'icicibank', title: 'ICICI Bank', bank: true, country: 'India' },
  { key: 'axisbank', title: 'Axis Bank', bank: true, country: 'India' },
  { key: 'nubank', title: 'Nubank', bank: true, country: 'Brazil' },
  // Brokers and investing platforms, for the Portfolio screen's broker icon.
  // Official Google Play app artwork (the original 512px file is kept in
  // icons/broker_sources/); registered like banks, by country.
  { key: 'groww', broker: true, title: 'Groww', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/dG1q2wx6Nk3aN6FIna144DYXI51P1cnbmBSRSvxKMZcZEDXcBv1-clSpc_PgjsE-UkGUCmX1kvRF-D443l3e=s0', hex: '5367FF' },
  { key: 'upstox', broker: true, title: 'Upstox', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/MrawO4hBn_dsf62-9xtIqD8p-We5DmUfKQwZ_fMmVRRvL2sEDaO05wAmly9V5d2nAxos3ZtX47jijV_DaXRfnQ=s0', hex: '6B2FA0' },
  { key: 'angelone', broker: true, title: 'Angel One', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/iWsUCDr0qRHrSQr90BTrbMeIP9Y5GNUEaIRNuxdufPXZmKruGScnvs9zcOM8vLhOemaMs7VjenS5T_5OrQ-A=s0', hex: '2F5BFF' },
  { key: 'icicidirect', broker: true, title: 'ICICI Direct', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/i94YBKq9-P8EgSFF8WxAFSLs17mTmlnRvB4QgAvjSF_Vqs1UePrvJc1s8D6Whz02JsAb87UJy2cNmNIoyprb=s0', hex: 'E4681D' },
  { key: 'hdfcsecurities', broker: true, title: 'HDFC Securities', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/q4HjH0Ky59Bv0g4-mXEPGo0WUc62h3oKl8QB-m53KwOaX_8M0nKUwN8u_GnIP5xwhS1uSyVWJ27k7MzXovU=s0', hex: '1A6EE6' },
  { key: 'kotakneo', broker: true, title: 'Kotak Neo', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/GXHU5xUKj-jx5RTsEo2ZrXnOaVH-y78VfT3RszWMZ-h-n7HQXGfkQ4Pc8QCkqCk5r7aTklH3xlbV4pMLFLa7=s0', hex: 'ED1C24' },
  { key: 'dhan', broker: true, title: 'Dhan', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/yKCt-YUk--HvxY_15cYHxSLl1AtgQuAn9f0eZO0jJpmCZxq9m-EN3IASyXsgVsPQGJF1qLXMQQEO8KCY86G2tQ=s0', hex: '168E6B' },
  { key: 'paytmmoney', broker: true, title: 'Paytm Money', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/PU-HJirvLDD4JkGRu17_1i2LmFS2GU1OYq-LqCPe9O7Lcx78vTCTqggyTufhRX4GUenIwutEU5DS6_rgzlDwnzI=s0', hex: '00BAF2' },
  { key: 'fidelity', broker: true, title: 'Fidelity Investments', bank: true, country: 'United States', source: 'raster', image: 'https://play-lh.googleusercontent.com/N56Fk3hFqKakNIzNBGo05K8hRaqRzArbQOcT3XLbWnWzC5O87cWZ1A8BWT7j3kI7id1HsawBoN_-ZpDHzL62HvM=s0', hex: '368727' },
  { key: 'etrade', broker: true, title: 'E*TRADE', bank: true, country: 'United States', source: 'raster', image: 'https://play-lh.googleusercontent.com/2YvJcF0POkjEkAobKzZxuH1jZQC3-3ZVpWc6D3F07LpirFu6CG80u7oAkAzOZa7ZISBoI0OgCrdKuSADZKPOc30=s0', hex: '6633CC' },
  { key: 'vanguard', broker: true, title: 'Vanguard', bank: true, country: 'United States', source: 'raster', image: 'https://play-lh.googleusercontent.com/bbqsYqJ7JttaJUzInOYtsEXsgdp8z2UhLBRdZ86gR3IayTGPsuDs3-QSMLM4nxYWlNOuDlcCEf6ANDoKCNjLnz0=s0', hex: '5F0A28' },
  { key: 'interactivebrokers', broker: true, title: 'Interactive Brokers', bank: true, country: 'United States', source: 'raster', image: 'https://play-lh.googleusercontent.com/6cMf8T9ZxVL4qgw-xbz6U6OoBSO4QtZr-rCc0wSfZBqAk-XsN_euH_ld3KKbrlJh2R-haiMimQVzYsiPt3bzsw=s0', hex: 'D81222' },
  { key: 'webull', broker: true, title: 'Webull', bank: true, country: 'United States', source: 'raster', image: 'https://play-lh.googleusercontent.com/5tva49lqkaE_rmPLnVlaFVmL4HjfCr_vSrMJs5TFrrwK_VO_dDsGr4ZltFE6B7w6nti8uTXlJwUgAIySeZ4r=s0', hex: '0A6CFF' },
  { key: 'merrilledge', broker: true, title: 'Merrill Edge', bank: true, country: 'United States', source: 'raster', image: 'https://play-lh.googleusercontent.com/h82cMlYk7-T_v81gU1vWqAlJj_yNiZ7akVQ6Mql5iBb1CqWgs7m-yfsM_mKS0pxvKMsYjYUa08RYoiwpfYzG=s0', hex: '012169' },
  { key: 'sofi', broker: true, title: 'SoFi', bank: true, country: 'United States', source: 'raster', image: 'https://play-lh.googleusercontent.com/ID7tWNMM566_AdaL54TGh-r1iBOKsYq69QCRgmM8IGF2k6qbPYdRYoQhndGbSGofF2xoVC5BCO1HyDJn_PF9xg=s0', hex: '00A1D6' },
  { key: 'trading212', broker: true, title: 'Trading 212', bank: true, country: 'United Kingdom', source: 'raster', image: 'https://play-lh.googleusercontent.com/vJFCjurK-d_LFFfMsrEfweQ7nMsu3KfLoTgSxFyvQv9zFhVIsaCr325dRgiZYEKB3_63NU1ur5ELwEka4nQu0A=s0', hex: '00A5E3' },
  { key: 'ajbell', broker: true, title: 'AJ Bell', bank: true, country: 'United Kingdom', source: 'raster', image: 'https://play-lh.googleusercontent.com/uxJbbVA1zK3Pon0sV4_EJMfy3BhzH2-lxE67aIek8aqlNdQ4QaKfL6XZybp40YwvEFwsu7WzQj0_PiLyh6YXna8=s0', hex: 'E8194B' },
  { key: 'etoro', broker: true, title: 'eToro', bank: true, country: 'Israel', source: 'raster', image: 'https://play-lh.googleusercontent.com/XH0fUZ_okeBUWB5xbZ7MrqCPdX4aFjn8qNyYE9rQlH-IzpoQ1xwRJKpFfDTnJvDO1A9cyUp_IyVFW7iNIxyGyQ=s0', hex: '13C636' },
  { key: 'traderepublic', broker: true, title: 'Trade Republic', bank: true, country: 'Germany', source: 'raster', image: 'https://play-lh.googleusercontent.com/p5ZAjWVXkOQKCyYalT40_WNL5LsP1s2W4eAQ06M71s9MeHJ6OColiqINcI-ctNe16TWIrkN8IdIm8xlSvNXB5_g=s0', hex: '111111' },
  { key: 'degiro', broker: true, title: 'DEGIRO', bank: true, country: 'Germany', source: 'raster', image: 'https://play-lh.googleusercontent.com/YOW_3z_WXhud_9OL7401vSt7_lszQAEETh1XTw5n1ibdY1G4kFjm4b1dwVb_b4iFGadMpL6aIR71qP4GeicZsaA=s0', hex: '1B75BC' },
  { key: 'questrade', broker: true, title: 'Questrade', bank: true, country: 'Canada', source: 'raster', image: 'https://play-lh.googleusercontent.com/Z8csYKEZCl1qXWuOKEsBt6M1OzMYGOSIlBuH3Ded1b51bU2jG9ig_KOhB26IntGKxw9Y-ppthcPl64yS89NS=s0', hex: '111111' },
  { key: 'wealthsimple', broker: true, title: 'Wealthsimple', bank: true, country: 'Canada', source: 'raster', image: 'https://play-lh.googleusercontent.com/hiG3-EbR-UYUYlwl5rrIvebr9eoYxU5oh5TlLdh9tbYpN_pkoPvFtHkRDpySEOcHtM0V4xFKmZ6O_swMO3IXtw=s0', hex: '000000' },
  { key: 'commsec', broker: true, title: 'CommSec', bank: true, country: 'Australia', source: 'raster', image: 'https://play-lh.googleusercontent.com/MLCBrCQN2fj95tTe_w_hO6RJYeFPhzbETE-QSUziO-PHS-VL5vituo4pqeP_68c907cIRfeykat2HRfhbV5J8A=s0', hex: 'FFCC00' },
  { key: 'stake', broker: true, title: 'Stake', bank: true, country: 'Australia', source: 'raster', image: 'https://play-lh.googleusercontent.com/MnYkuCS5wL-VcLhe3US720WNQg-F218QRHiau06K9Ttg7G-BdflaT1Ducz6rChHVXw8EC81N09P3NrZMHpolfw=s0', hex: '111111' },
  { key: 'tigerbrokers', broker: true, title: 'Tiger Brokers', bank: true, country: 'Singapore', source: 'raster', image: 'https://play-lh.googleusercontent.com/-AmDUb770GR7MnVr3Pl0MKs57ry-cRB6UllaqeE6GhZdMd-F2ldiyKL25abhMWbc7fqrnrpf2HcdkCfPB6PL=s0', hex: 'FFD800' },
  { key: 'xp', broker: true, title: 'XP Investimentos', bank: true, country: 'Brazil', source: 'raster', image: 'https://play-lh.googleusercontent.com/SG3pE3Bxbhr4CbGUP8k5lNOq2bWFCYEgbUm8Lb2Rx0N-jvFUZMVGFoTBhxZMNlQTsQKSVBXx8Ki10grw1fyuQQ=s0', hex: '000000' },
  // Crypto exchanges, wallets and more brokers worldwide: official app icons.
  { key: 'kraken', broker: true, title: 'Kraken', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/uXWjZQvrPbt9tz8nn7Gz-SuUnUrCw-cQPIg12RokMXxl2DKbfi6Yp4rxHywgGoYmhz4TlK3QnOakZ0gLMczc=s0', hex: '5741D9' },
  { key: 'bybit', broker: true, title: 'Bybit', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/8QvJsNNgtd-m28dkcxJjCz19Xwrp7-wjUtqLd1X5qeFvD_dvFBkrcyBLmWap-bf75ruO6Tmp0Tz6T92TTBSB=s0', hex: 'F7A600' },
  { key: 'okx', broker: true, title: 'OKX', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/E7LlTp0ew64sFWk7HN5cJjRGx_FKedlGX7zOQyO-7wRWHXOyPXTw6lIPJGgd8GdHp-XNdzcBZq3LciVM7Bn50w=s0', hex: '000000' },
  { key: 'kucoin', broker: true, title: 'KuCoin', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/TMI4cPCDBoBtOVTMc9GsMwGZ5FrxudVGDptqzAUOaCC2uT3gJnlTygRTaa1JwMxuxVJvApKfHbb-lqabEfroYd4=s0', hex: '23AF91' },
  { key: 'bitget', broker: true, title: 'Bitget', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/DHeDXHPjGD_39MLe4yhQOTr6CrB5LyiPX_sqoXWx-YlUtSkNCA38dwavTtXD9c_zRVqdZ1-hFaDif7bh7rWG=s0', hex: '00F0FF' },
  { key: 'gemini', broker: true, title: 'Gemini', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/94WeEFfCBINrvpKxGB4YkR6-yau-aCx4PZVivlDDFbdPOajiwJ-E7ew3gC9WfsYiHmfvwFRfQATzPOBKzJGQIA=s0', hex: '00DCFA' },
  { key: 'cryptocom', broker: true, title: 'Crypto.com', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/P6s_H1KY5eznFTmTGjbZ9xKxODHLjuTyfJ2V16f7cB61gNPi67xxm5-Qm98_bs3TH_2tgWOEymyGoveAMdPHFw=s0', hex: '002D74' },
  { key: 'bitstamp', broker: true, title: 'Bitstamp', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/6FZAgfQSPBTSzQAy70SoYdQDR3FGlGl9Yyex94po8xGwTOJtRku_Nd6a_IXxNXvU78Jokqsz-KEiDE28Trys=s0', hex: '1B2733' },
  { key: 'mexc', broker: true, title: 'MEXC', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/F0taegF8b77cZfUY-Sbiitz_vJcrBhoJAgHmoBUZ9J0w3cFpIJaaa98gl_C3a9VFBPO1l_CivlNSMaZnFylmFw=s0', hex: '1972E2' },
  { key: 'gateio', broker: true, title: 'Gate', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/D06vxjbVEogI_EFdUTIlY0zO-Er_08uJ1CsrSytYwla_amMBcnfgjDlmx6zNpJH1kUPTBIYI1tkp2fdg7SfJWa0=s0', hex: '2354E6' },
  { key: 'htx', broker: true, title: 'HTX', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/mHu57jpNFzrVVIT3jMeprI5wewzN2wLz49dGpQ2vodG6mpnmzL2EvEKu-cT3prIVaJKPvaItQQ-E1Nxjv7ns9Q=s0', hex: '1B2C58' },
  { key: 'bitpanda', broker: true, title: 'Bitpanda', bank: true, country: 'Austria', source: 'raster', image: 'https://play-lh.googleusercontent.com/aIzS4QzuTnhwX9U1GbT3PClNOxqd854d4D5OB-04a_SwWbiqzrFyu4zX8EQCd5qktiQ1nJ8Cs_hNEeGcgXpPKQ=s0', hex: '1ED0A2' },
  { key: 'upbit', broker: true, title: 'Upbit', bank: true, country: 'South Korea', source: 'raster', image: 'https://play-lh.googleusercontent.com/fFw0TlG1ExhjoAXPjiPkPQRcxkeNUmNpqaM2VEIfylSL--aB6pFvKMgvQRN551BcTEZ9vIDENvmOobTY0J2Ffo0=s0', hex: '093687' },
  { key: 'bithumb', broker: true, title: 'Bithumb', bank: true, country: 'South Korea', source: 'raster', image: 'https://play-lh.googleusercontent.com/LF42sIYOi6NH13MS2ZhEl2ArpnFhqLaWpwWOcHcEZBZeoj_vW54JUlQv20HQHr6R6DX0AxCyImWLAQbjIzgm9Q=s0', hex: 'F37321' },
  { key: 'coincheck', broker: true, title: 'Coincheck', bank: true, country: 'Japan', source: 'raster', image: 'https://play-lh.googleusercontent.com/ddBCDkILk2zUWc-8l4PF1_F4jVw1TbH3ZOR4hzNFlokvPrlsoBNICcvCi5xjngGEtLqpLbuLv-zwn7laB3sT7g=s0', hex: '2680EB' },
  { key: 'coindcx', broker: true, title: 'CoinDCX', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/1fe3ZZGVphz2gyty2Cb2pm7-INTz6ryG8ekFaPDE5vV9WwN9dJRFd1fFhOhwA3JXVIhx3hAaMg4WARjzogGGnA=s0', hex: '0D1226' },
  { key: 'wazirx', broker: true, title: 'WazirX', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/-wdt6QVqtsYeyuaxA68BG4WxKeiBDOtE5ObqIMlwUe8yKDAF33iG8q8LBZ2TumeZoYHRLAwbDGiScSvHFtYNWw=s0', hex: '3067F0' },
  { key: 'coinswitch', broker: true, title: 'CoinSwitch', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/Pq0CR5u-3B58mns97Zj3vyx6R-gTkCYLV0DIHPbJfm1Q55_Pns1AeV3SPXxL2IexHNttyJMoLv4EvXEbE7Wr3Pg=s0', hex: '2F6BFF' },
  { key: 'valr', broker: true, title: 'VALR', bank: true, country: 'South Africa', source: 'raster', image: 'https://play-lh.googleusercontent.com/tWjLsftfqNVY3CKeMzIsGBprt4jxVYWm3TWgamBmkAhzosdFPLUHgavawiGrJGf0rqL1OsXINnaa6MZCPZBt=s0', hex: '1A1A1A' },
  { key: 'mercadobitcoin', broker: true, title: 'Mercado Bitcoin', bank: true, country: 'Brazil', source: 'raster', image: 'https://play-lh.googleusercontent.com/MJX6KjZEAaVHFHuUS1BtqTneWketIY5lRdcLdmF700SdNm53PCIFhzYzB_ZZ9EYaWI9Am_EC-gefjzTGMGT_wQ=s0', hex: 'F9B21A' },
  { key: 'metamask', broker: true, title: 'MetaMask', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/UZYAICbN6huXhWkzjKFxQ-nqWCQy8C4HW3oAmx073m9sAUgI7OAPOuoMeq0Nsn7PcwhrpkUS94Dw-TERq4LOhA=s0', hex: 'F6851B' },
  { key: 'trustwallet', broker: true, title: 'Trust Wallet', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/0o3eb1pFP5LMvfnjbNIO18-090KB8CCCktck3h7lWcYEP4Q7h9pV13qOyEyBDEIkGzuBlmL8MN9ziDH-u08B=s0', hex: '0500FF' },
  { key: 'ledger', broker: true, title: 'Ledger', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/2m-OGWTytngqWotUst0ePY56cwBErE3rsm2G6tQKpO1UHmgv5OUvTCeuuKOsYNDmtD2VGVRdX-LWX8CwlouJow=s0', hex: '000000' },
  { key: 'trezor', broker: true, title: 'Trezor', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/bOxSIJKUp4UocASPcx7gPhptI4A_Vu9-Tu2XH9E1onvoeOt-FsllGIx_vDfbkjGPaXqg5RrBpAmM1Hen5j0WkA=s0', hex: '00854D' },
  { key: 'phantom', broker: true, title: 'Phantom', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/oo1OyYqnwEgwkx6Fo0yDNgV5okLwiVYPlhPA4LBp0OOphZHhUqkvJ6JldbVRXrGfa2yFFCdOkMnnDPFUo2Ji_A=s0', hex: 'AB9FF2' },
  { key: 'exodus', broker: true, title: 'Exodus', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/fHEgFEETzLAeBSPRFvdSb-3IDqJhWOADxIivOQ5dTxPxXEFKpmlcbkdb2XGJxzy22RpFmqH0BAduwjh-8cZVPoc=s0', hex: '8F52FF' },
  { key: 'coinbasewallet', broker: true, title: 'Coinbase Wallet', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/polJR2mhxrVL1-urF1bnAnahB2Ve3tj4rPzrIzpeCbRufH1mGytvz_uv31TJtb-ofQ3yyzc8Ve0JvrMOxNW-vj8=s0', hex: '0052FF' },
  { key: 'rainbow', broker: true, title: 'Rainbow', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/RJhaaoDOsocyRcpYS4xFkJFS0icXi2o6QITibCRBP3PHV-W35jXYkNFkkk59l3W7xMK6JyRaR98ty3NiisxBrA=s0', hex: '001E59' },
  { key: 'safepal', broker: true, title: 'SafePal', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/oJySFa2HQ9IQWvUqf9UEjNlrIjpj_K8iKkKZ6VIolwzGa_F-ftSRmXmU6l7HbNLdncfP9omPyflBBFj2ewRaY0A=s0', hex: '3375BB' },
  { key: 'atomicwallet', broker: true, title: 'Atomic Wallet', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/UxMmO6aVh_TCIQKZB6GIt905LKxIcda6dqug9T_AM76yNjHq6MnKqMfeJjxxh_NclEycaJb1sHTduOxb6R76Ww=s0', hex: '0D1122' },
  { key: 'bitcoincom', broker: true, title: 'Bitcoin.com Wallet', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/-p8YFSq-qqx25K-D-0mUuUTIVAxWZob7_iAQ6NbAic6uLy8vX_mwApmFGnUY54Nf9uUz-u3soyiUkDPR30udFA=s0', hex: '0AC18E' },
  { key: 'moomoo', broker: true, title: 'moomoo', bank: true, country: 'Hong Kong', source: 'raster', image: 'https://play-lh.googleusercontent.com/asavCAIOPZTA2ahJOBsIIOkGndADimPTzUbF_zdSbll1dIvXwozWf7mb97Wzdsy4X3MQpkN6g53yCY68NY2vdX4=s0', hex: 'FF6A00' },
  { key: 'futu', broker: true, title: 'Futubull', bank: true, country: 'Hong Kong', source: 'raster', image: 'https://play-lh.googleusercontent.com/cYHWt0DmqXUskRl5bTEaLz82rAuFeEanJviSYx1ODMyQSOdfYI5LEQ0A3wRhoGHXdIyTwXxtk9FfXdn1OQ3R1A=s0', hex: 'FF6A00' },
  { key: 'firstrade', broker: true, title: 'Firstrade', bank: true, country: 'United States', source: 'raster', image: 'https://play-lh.googleusercontent.com/eMc_wUGleAS2TeuP9Drj-R1ziXkogXzNwBh_zcdkQBGN3CTXDHNlrQlXYnbCFiP-QvtZ4WcZzH0JQhcIFUQ=s0', hex: '00529B' },
  { key: 'motilaloswal', broker: true, title: 'Motilal Oswal', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/mYmcPxQifEvJcqxLoGLGvIOLk9OmuFmKNEvK3ruWdr6d8smfExlZ0VcDghdPzTAV6DjyYU5H935WF7hRdXfr_u4=s0', hex: 'E21F26' },
  { key: 'indmoney', broker: true, title: 'INDmoney', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/GbJSdICmN3ec1y7Y6D3s76lS5GhEjdL3472CKgQgjZ2UdQeM0CZoU2ne3SBfgxHLhLazZmbYeQj8AjcPSCKZEXE=s0', hex: '6C4DF4' },
  { key: 'publicapp', broker: true, title: 'Public', bank: true, country: 'United States', source: 'raster', image: 'https://play-lh.googleusercontent.com/imHONgAycbYI0iMHgbiO590gFOFQDp9gKJ4UNXkatzUJaG1mbDwI2MpTtdv7PRNtRtUaqzoTunLvY_vONKER4w=s0', hex: '000000' },
  { key: 'fyers', broker: true, title: 'FYERS', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/5Y1kVEbboWVeZ4T0l7cjP2nAUbz1_-ImIWKbbdXkJ0-JMpwV7svbG4uEakENWxPQFRWuQgu4tDtaENULAzZW=s0', hex: '2F6BFF' },
  { key: 'interactiveinvestor', broker: true, title: 'interactive investor', bank: true, country: 'United Kingdom', source: 'raster', image: 'https://play-lh.googleusercontent.com/6jXJqVypWjHFZk8QYswazrDTFCIh44qeK02LL0JrZfZrWKdeIzXx-FJM9tVj4qQbjAnbU6w4xyXutLFxqt_1lw=s0', hex: '00A8E0' },
  { key: 'iifl', broker: true, title: 'IIFL', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/9NMcJmKIQ44wE09aYYtoGKDyksM3YW7faWUVdRYZm5FtGhclyd_iCVJvNWpjlIqjYrZxXN6eXPThskzmlUJK0w=s0', hex: '1F4E9E' },
  { key: 'kuvera', broker: true, title: 'Kuvera', bank: true, country: 'India', source: 'raster', image: 'https://play-lh.googleusercontent.com/ApJ4Qv86goaDayg53TXS9X9L2PjS1uR4JUkJg4LxVgOeK6is-qXOAzTCE7VNCIP-2RVMwGc_6ZI28uCTEC8eQw=s0', hex: '2A2A2A' },
  { key: 'tastytrade', broker: true, title: 'tastytrade', bank: true, country: 'United States', source: 'raster', image: 'https://play-lh.googleusercontent.com/uFWH_5XRc6GGppdpB1avmdAw2pdQwOqTMH3zUWCNqvnzwRlsplHh5LA4zXy8BbZ7zwNqvc6bDGiFIHn1eZCyXmY=s0', hex: 'E8222E' },
  { key: 'plus500', broker: true, title: 'Plus500', bank: true, country: 'United Kingdom', source: 'raster', image: 'https://play-lh.googleusercontent.com/Pa48V6jOOVITF780AhLkvJW04BEIhiSTO4TPFb-HYownMgZ4boKFs6wJAYKBYf07fuKLaFp4hhl9BSobZmu_Aw=s0', hex: '2D7DD2' },
  { key: 'bingx', broker: true, title: 'BingX', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/b7k7t25q8w-XMjwKTB5DOCsMWp7imHlsJrRK53LD1MEzwAWFc9rGaQZru3j4w77bT3GpKI8IfhUsJqZTd4ZDgu0=s0', hex: '2A54FF' },
  { key: 'bitfinex', broker: true, title: 'Bitfinex', payment: true, source: 'raster', image: 'https://play-lh.googleusercontent.com/t4hzoUfDzqetduKyOmPVdTDeQjPPUej0UNhJJWuSzFRHdsfP3NvdBMwi41Eo_q9fWVGjEYNSiuRxYIzdBrGLlw=s0', hex: '16B157' },
  { key: 'saxo', broker: true, title: 'Saxo', bank: true, country: 'Denmark', source: 'wikimedia', file: 'Saxo Bank logo.svg', hex: '00305F' },
  { key: 'ig', broker: true, title: 'IG', bank: true, country: 'United Kingdom', source: 'wikimedia', file: 'IG Group logo.svg', hex: 'E01B1C' },
  { key: 'hargreaveslansdown', broker: true, title: 'Hargreaves Lansdown', bank: true, country: 'United Kingdom', source: 'wikimedia', file: 'Hargreaves Lansdown logo.svg', hex: '071D49' },
  { key: 'scalablecapital', broker: true, title: 'Scalable Capital', bank: true, country: 'Germany', source: 'wikimedia', file: 'Scalable Capital Logo 2024.svg', hex: '28EBCF' },
  { key: 'bitso', broker: true, title: 'Bitso', bank: true, country: 'Mexico', source: 'wikimedia', file: 'Logo de Bitso.svg', hex: '252C36' },
  // Worldwide rule-pack institutions with verified original vector marks.
  { key: 'bancopromerica', title: 'Banco Promerica', bank: true, country: 'El Salvador', source: 'wikimedia', file: 'Logo Banco Promerica.svg', hex: '158447' },
  { key: 'cibegypt', title: 'CIB Egypt', bank: true, country: 'Egypt', source: 'wikimedia', file: 'Cib Logo.svg', hex: 'F58220' },
  { key: 'nationalbankofegypt', title: 'National Bank of Egypt', bank: true, country: 'Egypt', source: 'wikimedia', file: 'National Bank of Egypt.svg', hex: '007A3D' },
  { key: 'mellatbank', title: 'Mellat Bank', bank: true, country: 'Iran', source: 'wikimedia', file: 'Bank Mellat Logo.svg', hex: 'D71920' },
  { key: 'mellibank', title: 'Melli Bank', bank: true, country: 'Iran', source: 'wikimedia', file: 'Bank Melli Iran Logo.svg', hex: '006A4D' },
  { key: 'orangemoney', title: 'Orange Money', payment: true, source: 'wikimedia', file: 'Logo Orange Money.svg', hex: 'FF7900' },
  { key: 'tbank', title: 'T-Bank', bank: true, country: 'Russia', source: 'wikimedia', file: 'T-Bank RU logo.svg', hex: 'FFDD2D' },
  { key: 'alrajhibank', title: 'Al Rajhi Bank', bank: true, country: 'Saudi Arabia', source: 'wikimedia', file: 'Al Rajhi Bank Logo.svg', hex: '00856A' },
  { key: 'banquesaudifransi', title: 'Banque Saudi Fransi', bank: true, country: 'Saudi Arabia', source: 'wikimedia', file: 'Banque Saudi Fransi Logo.svg', hex: '006A71' },
  { key: 'commercialbankofceylon', title: 'Commercial Bank of Ceylon', bank: true, country: 'Sri Lanka', source: 'wikimedia', file: 'Commercial Bank logo.svg', hex: '005CA9' },
  { key: 'baac', title: 'BAAC', bank: true, country: 'Thailand', source: 'wikimedia', file: 'BAAC Logo.svg', hex: '00843D' },
  { key: 'bangkokbank', title: 'Bangkok Bank', bank: true, country: 'Thailand', source: 'wikimedia', file: 'Bangkok Bank 2023 (English version).svg', hex: '1E4598' },
  { key: 'cimbthai', title: 'CIMB Thai', bank: true, country: 'Thailand', source: 'wikimedia', file: 'CIMB Thai Bank Logo.svg', hex: '7A003C' },
  { key: 'kasikornbank', title: 'Kasikorn Bank', bank: true, country: 'Thailand', source: 'wikimedia', file: 'Kasikornbank Logo.svg', hex: '138F4A' },
  { key: 'krungsri', title: 'Krungsri', bank: true, country: 'Thailand', source: 'wikimedia', file: 'Krungsri Logo.svg', hex: 'F7D117' },
  { key: 'ktc', title: 'KTC', bank: true, country: 'Thailand', source: 'wikimedia', file: 'Krungthai Card Logo.svg', hex: '0057A8' },
  { key: 'siamcommercialbank', title: 'Siam Commercial Bank', bank: true, country: 'Thailand', source: 'wikimedia', file: 'Siam Commercial Bank Logo.svg', hex: '4E2A84' },
  { key: 'ttb', title: 'TTB', bank: true, country: 'Thailand', source: 'wikimedia', file: 'TTB Logo.svg', hex: '0046AD' },
  { key: 'enpara', title: 'Enpara', bank: true, country: 'Turkey', source: 'wikimedia', file: 'Enpara.com Logo.svg', hex: '7B2D8E' },
  { key: 'firstabudhabibank', title: 'First Abu Dhabi Bank', bank: true, country: 'United Arab Emirates', source: 'wikimedia', file: 'First Abu Dhabi Bank Logo.svg', hex: '006B5B' },
  { key: 'navyfederal', title: 'Navy Federal Credit Union', bank: true, country: 'United States', source: 'wikimedia', file: 'Navy Federal Credit Union Logo.svg', hex: '00529B' },
  { key: 'chase', title: 'Chase', bank: true, country: 'United States' },
  { key: 'citibank', title: 'Citi Bank', bank: true, country: 'United States', source: 'wikimedia', file: 'Citibank.svg', hex: '056DAE' },
  { key: 'huntingtonbank', title: 'Huntington Bank', bank: true, country: 'United States', source: 'wikimedia', file: 'Huntington Bancshares Inc. logo.svg', hex: '006D4E' },
  { key: 'nepalsbibank', title: 'Nepal SBI Bank', bank: true, country: 'Nepal', source: 'wikimedia', file: 'Nepal SBI Bank Logo.svg', hex: '1C73B8' },
  { key: 'gtbank', title: 'GTBank', bank: true, country: 'Nigeria', source: 'wikimedia', file: 'Logo GuarantyTrustBank.svg', hex: 'D94F00' },
  { key: 'jaizbank', title: 'Jaiz Bank', bank: true, country: 'Nigeria', source: 'wikimedia-raster', file: 'Jaiz New Logo.jpg', hex: '006B54' },
  { key: 'keystonebank', title: 'Keystone Bank', bank: true, country: 'Nigeria', source: 'wikimedia-raster', file: 'Keystone Logo.png', hex: '7A263A' },
  { key: 'moniepoint', title: 'Moniepoint', bank: true, country: 'Nigeria', source: 'wikimedia', file: 'Moniepoint Logo.svg', hex: '6C4CF1' },
  { key: 'zenithbank', title: 'Zenith Bank', bank: true, country: 'Nigeria', source: 'wikimedia', file: 'Zenith Bank Logo.svg', hex: 'ED1C24' },
  // Parser-pack banks added later: main symbol only, see VISUAL_CROPS.
  { key: 'arabbank', title: 'Arab Bank', bank: true, country: 'Egypt', source: 'visual', url: COMMONS('Arab Bank.svg'), hex: '1B75BB' },
  { key: 'bancoagricola', title: 'Banco Agricola', bank: true, country: 'El Salvador', source: 'visual', url: 'https://play-lh.googleusercontent.com/4odhYGAFtFIPd1JqopEYCYmnf4e_NQUTHg7nL-QzrkoFNxxhHunjae6_4cyGdrfHc4QQzKVQRMRxowWZVB-e5Q=s0', hex: '00539F' },
  { key: 'awashbank', title: 'Awash Bank', bank: true, country: 'Ethiopia', source: 'visual', url: COMMONS('Awash International Bank.png'), hex: 'F7941D' },
  { key: 'bankofabyssinia', title: 'Bank of Abyssinia', bank: true, country: 'Ethiopia', source: 'visual', url: COMMONS('BOA-LOGO.png'), hex: 'FFED00' },
  { key: 'commercialbankofethiopia', title: 'Commercial Bank of Ethiopia', bank: true, country: 'Ethiopia', source: 'visual', url: COMMONS('LOGO OF COMMERCIAL BANK OF ETHIOPIA (BAANKII DALDALA ITIYOOPHIYAA).jpg'), hex: '9C6B2F' },
  { key: 'dashenbank', title: 'Dashen Bank', bank: true, country: 'Ethiopia', source: 'visual', url: COMMONS('Dashen Bank.png'), hex: '1C2A6B' },
  { key: 'zemenbank', title: 'Zemen Bank', bank: true, country: 'Ethiopia', source: 'visual', url: COMMONS('Zemen Bank.png'), hex: 'E4262B' },
  { key: 'bpce', title: 'BPCE', bank: true, country: 'France', source: 'visual', url: COMMONS('Bpce Logo.png'), hex: '008C95' },
  { key: 'millenniumbim', title: 'Millennium BIM', bank: true, country: 'Mozambique', source: 'visual', url: COMMONS('Millenniumbim logo svg.svg'), hex: 'D81B60' },
  { key: 'mpesamozambique', title: 'M-Pesa Mozambique', payment: true, source: 'visual', url: COMMONS('M-PESA LOGO-01.svg'), hex: '4DB848' },
  { key: 'equitybank', title: 'Equity Bank', bank: true, country: 'Kenya', source: 'visual', url: COMMONS('Equity Bank Logo.jpg'), hex: 'A6192E' },
  { key: 'standardcharteredbanknepal', title: 'Standard Chartered Bank Nepal', bank: true, country: 'Nepal', source: 'visual', url: COMMONS('Standard Chartered Logo (2021, Logo only).svg'), hex: '0473EA' },
  { key: 'standardcharteredbanknigeria', title: 'Standard Chartered Bank Nigeria', bank: true, country: 'Nigeria', source: 'visual', url: COMMONS('Standard Chartered Logo (2021, Logo only).svg'), hex: '0473EA' },
  { key: 'accessbank', title: 'Access Bank', bank: true, country: 'Nigeria', source: 'visual', url: COMMONS('Accessbank1.png'), hex: 'F26A21' },
  { key: 'opay', title: 'Opay', bank: true, country: 'Nigeria', source: 'visual', url: COMMONS('Opay Digital Services Limited.png'), hex: '1DCF9F' },
  { key: 'bankmuscat', title: 'Bank Muscat', bank: true, country: 'Oman', source: 'visual', url: COMMONS('BM logo.png'), hex: 'C8102E' },
  { key: 'faysalbank', title: 'Faysal Bank', bank: true, country: 'Pakistan', source: 'visual', url: COMMONS('Faysal Bank Limited logo (2026).svg'), hex: '0A5C8F' },
  { key: 'd360bank', title: 'D360 Bank', bank: true, country: 'Saudi Arabia', source: 'visual', url: COMMONS('D360 Bank.svg'), hex: 'EE6352' },
  { key: 'sabb', title: 'SABB', bank: true, country: 'Saudi Arabia', source: 'visual', url: COMMONS('SABB Bank Logo.svg'), hex: 'DB0011' },
  { key: 'saudinationalbank', title: 'Saudi National Bank', bank: true, country: 'Saudi Arabia', source: 'visual', url: COMMONS('Saudi National Bank Logo.svg'), hex: '006A4E' },
  { key: 'bracbank', title: 'BRAC Bank', bank: true, country: 'Bangladesh', source: 'visual', url: ENWIKI('BRAC Bank Limited Logo.svg'), hex: '0060AC' },
  { key: 'parsian', title: 'Parsian Bank', bank: true, country: 'Iran', source: 'visual', url: ENWIKI('Parsian Bank logo.png'), hex: '7B4A2A' },
  { key: 'nationalsavingsbank', title: 'National Savings Bank', bank: true, country: 'Sri Lanka', source: 'visual', url: ENWIKI('National Savings Bank logo.png'), hex: '1A1A1A' },
  { key: 'nationstrustbank', title: 'Nations Trust Bank', bank: true, country: 'Sri Lanka', source: 'visual', url: ENWIKI('Nations Trust Bank logo.png'), hex: '00A0DF' },
  { key: 'sampathbank', title: 'Sampath Bank', bank: true, country: 'Sri Lanka', source: 'visual', url: COMMONS('SmpBank.png'), hex: 'F58220' },
  { key: 'crdbbank', title: 'CRDB Bank', bank: true, country: 'Tanzania', source: 'visual', url: COMMONS('CRDB BANK.png'), hex: '2E9E3E' },
  { key: 'diamondtrustbank', title: 'Diamond Trust Bank', bank: true, country: 'Tanzania', source: 'visual', url: COMMONS('DTB Tanzania logo.png'), hex: 'E31837' },
  { key: 'nmbbanktanzania', title: 'NMB Bank Tanzania', bank: true, country: 'Tanzania', source: 'visual', url: COMMONS('Nmb logo.jpg'), hex: '0057A8' },
  { key: 'governmentsavingsbank', title: 'Government Savings Bank', bank: true, country: 'Thailand', source: 'visual', url: ENWIKI('Logo GSB Thailand.svg'), hex: 'E4007F' },
  { key: 'krungthaibank', title: 'Krungthai Bank', bank: true, country: 'Thailand', source: 'visual', url: ENWIKI('Krung Thai Bank logo.svg'), hex: '00A5E5' },
  { key: 'uobthailand', title: 'UOB Thailand', bank: true, country: 'Thailand', source: 'visual', url: COMMONS('UOB Logo.svg'), hex: '0B2A6F' },
  { key: 'emiratesislamic', title: 'Emirates Islamic', bank: true, country: 'United Arab Emirates', source: 'visual', url: ENWIKI('Emirates Islamic Bank Logo.png'), hex: '5B2A86' },
  { key: 'emiratesnbd', title: 'Emirates NBD', bank: true, country: 'United Arab Emirates', source: 'visual', url: 'https://cdn.emiratesnbd.com/assets/images/brandmark-blue.png', hex: '0F2B5B' },
  { key: 'charlesschwab', broker: true, title: 'Charles Schwab', bank: true, country: 'United States', source: 'visual', url: COMMONS('Charles Schwab Corporation logo.svg'), hex: '00A0DF' },
  { key: 'discovercard', title: 'Discover Card', bank: true, country: 'United States', source: 'visual', url: COMMONS('DiscoverCard.svg'), hex: 'F76F20' },
  // Major US consumer and commercial banks, ranked from the Federal Reserve's
  // June 2026 large-bank report. ENWIKI resolves local and Commons logo files.
  { key: 'wellsfargo', title: 'Wells Fargo', bank: true, country: 'United States', source: 'visual', url: ENWIKI('Wells Fargo Logo (2020).svg'), hex: 'D71E28' },
  { key: 'usbank', title: 'U.S. Bank', bank: true, country: 'United States', source: 'visual', url: ENWIKI('US Bancorp logo 2023 color.svg'), hex: '0050A4' },
  { key: 'capitalone', title: 'Capital One', bank: true, country: 'United States', source: 'visual', url: ENWIKI('Capital One logo.svg'), hex: '004977' },
  { key: 'pncbank', title: 'PNC Bank', bank: true, country: 'United States', source: 'visual', url: ENWIKI('PNClogo.svg'), hex: 'F58025' },
  { key: 'truist', title: 'Truist', bank: true, country: 'United States', source: 'visual', url: ENWIKI('Truist Financial logo.svg'), hex: '2E1A47' },
  { key: 'tdbank', title: 'TD Bank', bank: true, country: 'United States', source: 'visual', url: ENWIKI('TD Bank.svg'), hex: '008A00' },
  { key: 'fifththird', title: 'Fifth Third Bank', bank: true, country: 'United States', source: 'visual', url: ENWIKI('Fifth Third Bank.svg'), hex: '1B438B' },
  { key: 'bmo', title: 'BMO', bank: true, country: 'United States', source: 'visual', url: ENWIKI('BMO Logo.svg'), hex: '0075BE' },
  { key: 'firstcitizens', title: 'First Citizens Bank', bank: true, country: 'United States', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/FCNCA-24fcaa12.svg?t=1742284949&download=true', hex: '00563F' },
  { key: 'citizensbank', title: 'Citizens Bank', bank: true, country: 'United States', source: 'visual', url: ENWIKI('Citizens Financial Group logo.svg'), hex: '319C8B' },
  { key: 'mtbank', title: 'M&T Bank', bank: true, country: 'United States', source: 'visual', url: ENWIKI('M&T Bank wordmark.svg'), hex: '007856' },
  { key: 'keybank', title: 'KeyBank', bank: true, country: 'United States', source: 'visual', url: ENWIKI('KeyBank.png'), hex: 'E2231A' },
  { key: 'allybank', title: 'Ally Bank', bank: true, country: 'United States', source: 'visual', url: ENWIKI('Ally Financial.svg'), hex: '650360' },
  { key: 'hsbcusa', title: 'HSBC USA', bank: true, country: 'United States', source: 'copy', from: 'hsbcuk', hex: 'DB0011' },
  { key: 'regionsbank', title: 'Regions Bank', bank: true, country: 'United States', source: 'visual', url: ENWIKI('Regions Financial Corp logo.svg'), hex: '78BE20' },
  { key: 'santanderus', title: 'Santander Bank', bank: true, country: 'United States', source: 'visual', url: ENWIKI('Banco Santander Logotipo.svg'), hex: 'EC0000' },
  { key: 'goldmansachs', title: 'Goldman Sachs', bank: true, country: 'United States', source: 'visual', url: ENWIKI('Goldman Sachs logo.svg'), hex: '6AB5DE' },
  { key: 'bnymellon', title: 'BNY Mellon', bank: true, country: 'United States', source: 'visual', url: ENWIKI('BNY Mellon.svg'), hex: '009CDE' },
  { key: 'morganstanley', title: 'Morgan Stanley', bank: true, country: 'United States', source: 'visual', url: ENWIKI('Morgan Stanley Logo 1.svg'), hex: '000000' },
  { key: 'statestreet', title: 'State Street', bank: true, country: 'United States', source: 'visual', url: ENWIKI('State-street-logo-final.svg'), hex: '00529B' },
  { key: 'northerntrust', title: 'Northern Trust', bank: true, country: 'United States', source: 'visual', url: 'https://cdn.northerntrust.com/pws/nt/images/social-media/nt-2linestacked-logo-1200x628.png', hex: '000000' },

  // The Bank of England's July 2026 major-bank peer group, plus widely used
  // retail challengers and constituent consumer brands.
  { key: 'barclays', title: 'Barclays', bank: true, country: 'United Kingdom' },
  { key: 'hsbcuk', title: 'HSBC', bank: true, country: 'United Kingdom', source: 'visual', url: ENWIKI('HSBC logo (2018).svg'), hex: 'DB0011' },
  { key: 'lloydsbank', title: 'Lloyds Bank', bank: true, country: 'United Kingdom', source: 'visual', url: 'https://play-lh.googleusercontent.com/UYjNbnqTRrjm0lUEutey90OJ24fbBmKE1BDoPwj0QZJbJ0NCzx_jyzHR7apU0PxDBApdp0rcX2hUZQ4eBnFy=s0', hex: '006A4D' },
  { key: 'natwest', title: 'NatWest', bank: true, country: 'United Kingdom', source: 'visual', url: ENWIKI('Natwest 2014 logo.svg'), hex: '42145F' },
  { key: 'santanderuk', title: 'Santander UK', bank: true, country: 'United Kingdom', source: 'copy', from: 'santanderus', hex: 'EC0000' },
  { key: 'standardchartereduk', title: 'Standard Chartered', bank: true, country: 'United Kingdom', source: 'copy', from: 'standardcharteredbanknigeria', hex: '0473EA' },
  { key: 'bankofscotland', title: 'Bank of Scotland', bank: true, country: 'United Kingdom', source: 'visual', url: ENWIKI('Bank of Scotland logo.svg'), hex: '0072CE' },
  { key: 'tsbuk', title: 'TSB', bank: true, country: 'United Kingdom', source: 'visual', url: ENWIKI('TSB logo.svg'), hex: '004B8D' },
  { key: 'virginmoneyuk', title: 'Virgin Money', bank: true, country: 'United Kingdom', source: 'visual', url: ENWIKI('Virgin Money.svg'), hex: 'E10A0A' },
  { key: 'cooperativebankuk', title: 'The Co-operative Bank', bank: true, country: 'United Kingdom', source: 'visual', url: ENWIKI('The co-operative bank logo.svg'), hex: '00B1E7' },
  { key: 'nationwideuk', title: 'Nationwide', bank: true, country: 'United Kingdom', source: 'visual', url: ENWIKI('Nationwide Building Society logo 2023.svg'), hex: '002878' },
  { key: 'halifaxuk', title: 'Halifax', bank: true, country: 'United Kingdom', source: 'visual', url: ENWIKI('Halifax logo.svg'), hex: '005EB8' },
  { key: 'metrobankuk', title: 'Metro Bank', bank: true, country: 'United Kingdom', source: 'visual', url: ENWIKI('Metro Bank logo.svg'), hex: '0057B8' },

  // Africa's June 2026 top-30 groups that were not already represented by the
  // earlier parser-driven batches. Consumer-facing FNB identifies FirstRand.
  { key: 'standardbanksa', title: 'Standard Bank', bank: true, country: 'South Africa', source: 'visual', url: ENWIKI('Standard Bank of South Africa logo.png'), hex: '0033A1' },
  { key: 'fnbsa', title: 'FNB', bank: true, country: 'South Africa', source: 'remote-svg', url: 'https://www.fnb.co.za/_assets/images/generic/skins/00/navigation/secondary-logo/header-logo_lrg.svg', hex: '009999' },
  { key: 'absa', title: 'Absa', bank: true, country: 'South Africa', source: 'visual', url: ENWIKI('Absa Logo.svg'), hex: 'DC0032' },
  { key: 'nedbank', title: 'Nedbank', bank: true, country: 'South Africa', source: 'visual', url: COMMONS('NEDBANK N SYMBOL CMYK.jpg'), hex: '007A33' },
  { key: 'investec', title: 'Investec', bank: true, country: 'South Africa', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/INVR.L-800fb324.svg?t=1720244492&download=true', hex: '000000' },
  { key: 'capitec', title: 'Capitec Bank', bank: true, country: 'South Africa', source: 'visual', url: COMMONS('Capitec Bank logo.svg'), hex: '004771' },
  { key: 'banquemisr', title: 'Banque Misr', bank: true, country: 'Egypt', source: 'visual', url: ENWIKI('Banque Misr.svg'), hex: '5C2D91' },
  { key: 'qnbegypt', title: 'QNB Egypt', bank: true, country: 'Egypt', source: 'visual', url: ENWIKI('QNB Logo.svg'), hex: '7C1F5B' },
  { key: 'arabafricanbank', title: 'Arab African International Bank', bank: true, country: 'Egypt', source: 'visual', url: COMMONS('البنك العربى الافريقى الدولى.png'), hex: '006A4E' },
  { key: 'attijariwafa', title: 'Attijariwafa Bank', bank: true, country: 'Morocco', source: 'visual', url: ENWIKI('LogoNew.png'), hex: 'E31E24' },
  { key: 'bcpgroup', title: 'Banque Centrale Populaire', bank: true, country: 'Morocco', source: 'visual', url: ENWIKI('Logo BCP.svg'), hex: 'E30613' },
  { key: 'bankofafrica', title: 'Bank of Africa', bank: true, country: 'Morocco', source: 'visual', url: ENWIKI('Bank of Africa Logo.png'), hex: 'D71920' },
  { key: 'creditagricolemaroc', title: 'Crédit Agricole du Maroc', bank: true, country: 'Morocco', source: 'visual', url: COMMONS('CAM Logo 2023-VF.jpg'), hex: '007A3D' },
  { key: 'cihbank', title: 'CIH Bank', bank: true, country: 'Morocco', source: 'visual', url: ENWIKI('Cih-bank.png'), hex: 'E6007E' },
  { key: 'sahambank', title: 'Saham Bank', bank: true, country: 'Morocco', source: 'visual', url: ENWIKI('Saham-bank-logo.svg'), hex: '512888' },
  { key: 'uba', title: 'United Bank for Africa', bank: true, country: 'Nigeria', source: 'visual', url: ENWIKI('United bank of Africa.png'), hex: 'D71920' },
  { key: 'firstbanknigeria', title: 'FirstBank Nigeria', bank: true, country: 'Nigeria', source: 'visual', url: ENWIKI('First-Bank.svg'), hex: '003B5C' },
  { key: 'cpaalgeria', title: 'Crédit Populaire d’Algérie', bank: true, country: 'Algeria', source: 'visual', url: 'https://play-lh.googleusercontent.com/1Yifd7DHPee1r484ZD1EThRJyxwRIM4XvWfNGPUEdBiHWm66XkqHqCyDMSTI6tGLB_hccy8vtaIW1YScRZEydA=s0', hex: '00529B' },
  { key: 'bdlalgeria', title: 'Banque de Développement Local', bank: true, country: 'Algeria', source: 'visual', url: COMMONS('Logo BDL .png'), hex: '652F8D' },
  { key: 'ecobank', title: 'Ecobank', bank: true, country: 'Togo', source: 'visual', url: ENWIKI('Ecobank Logo.svg'), hex: '00529B' },
  { key: 'mcbmauritius', title: 'Mauritius Commercial Bank', bank: true, country: 'Mauritius', source: 'visual', url: ENWIKI('Mauritius Commercial Bank logo.svg'), hex: 'ED1C24' },
  { key: 'kcbkenya', title: 'KCB Bank', bank: true, country: 'Kenya', source: 'visual', url: ENWIKI('KCB Bank Kenya Limited logo.png'), hex: '009C4B' },
  { key: 'bgfibank', title: 'BGFI Bank', bank: true, country: 'Gabon', source: 'visual', url: ENWIKI('Logo BGFIBank.jpg'), hex: '006A4D' },
  // Every Sparkasse shares the Sparkassen-Finanzgruppe 'S' mark.
  { key: 'sparkasserheinmaas', title: 'Sparkasse Rhein-Maas', siTitle: 'Sparkasse', bank: true, country: 'Germany' },
  { key: 'chaseuk', title: 'Chase UK', bank: true, country: 'United Kingdom', source: 'copy', from: 'chase', hex: '117ACA' },
  // Original bank marks from Wikimedia Commons.
  { key: 'bri', title: 'BRI', bank: true, country: 'Indonesia', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/BBRI.JK-30a60327.svg?download=true&t=1720244490', hex: '00529C' },
  { key: 'bca', title: 'BCA', bank: true, country: 'Indonesia', source: 'wikimedia', file: 'Bank Central Asia.svg', hex: '003D7C' },
  { key: 'bni', title: 'BNI', bank: true, country: 'Indonesia', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/BBNI.JK-68793c4c.svg?download=true&t=1782765734', hex: 'F15A22' },
  { key: 'btn', title: 'BTN', bank: true, country: 'Indonesia', source: 'wikimedia', file: 'Bank Tabungan Negara logo.svg', hex: '005BAC' },
  { key: 'mandiri', title: 'Mandiri', bank: true, country: 'Indonesia', source: 'wikimedia', file: 'Bank Mandiri logo 2016.svg', hex: '003E7E' },
  { key: 'banksyariahindonesia', title: 'Bank Syariah Indonesia', bank: true, country: 'Indonesia', source: 'visual', url: ENWIKI('Bank Syariah Indonesia.svg'), hex: '00A39D' },
  { key: 'cimbniaga', title: 'CIMB Niaga', bank: true, country: 'Indonesia', source: 'visual', url: ENWIKI('CIMB Niaga logo.svg'), hex: '7A003C' },
  { key: 'ocbcindonesia', title: 'OCBC Indonesia', bank: true, country: 'Indonesia', source: 'visual', url: ENWIKI('Logo-ocbc.svg'), hex: 'E30613' },
  { key: 'permatabank', title: 'PermataBank', bank: true, country: 'Indonesia', source: 'visual', url: ENWIKI('Permata Bank (2024).svg'), hex: '00A651' },
  { key: 'danamon', title: 'Bank Danamon', bank: true, country: 'Indonesia', source: 'visual', url: ENWIKI('Danamon (2024).svg'), hex: '00843D' },
  { key: 'idfcfirst', title: 'IDFC FIRST Bank', bank: true, country: 'India', source: 'raster', image: 'https://companieslogo.com/img/orig/IDFCFIRSTB.NS-6c6b4306.png?t=1720244492', hex: '8F1D2C' },
  { key: 'unionbankindia', title: 'Union Bank of India', bank: true, country: 'India', source: 'raster', image: 'https://companieslogo.com/img/orig/UNIONBANK.NS-5bba728d.png?t=1720244494', hex: 'E26B14' },
  { key: 'sbi', title: 'State Bank of India', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/SBIN.NS-797afcaa.svg?download=true&t=1720244493', hex: '1C73B8' },
  { key: 'canara', title: 'Canara Bank', bank: true, country: 'India', source: 'raster', image: 'https://companieslogo.com/img/orig/CANBK.NS-94324ae3.png?t=1613453726', hex: '00529B' },
  { key: 'indianoverseas', title: 'Indian Overseas Bank', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/IOB.NS-97c85257.svg?download=true&t=1745073264', hex: '1A73A8' },
  { key: 'rbl', title: 'RBL Bank', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/RBLBANK.NS-0a123623.svg?download=true&t=1747106329', hex: '004A8F' },
  { key: 'pnb', title: 'Punjab National Bank', bank: true, country: 'India', source: 'raster', image: 'https://companieslogo.com/img/orig/PNB.NS-f0a1e3ee.png?t=1720244493', hex: '7B2C3A' },
  { key: 'bankofbaroda', title: 'Bank of Baroda', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/BANKBARODA.NS-9424a39c.svg?download=true&t=1744859630', hex: 'F26522' },
  { key: 'yesbank', title: 'YES BANK', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/YESBANK.NS-570f0718.svg?download=true&t=1720244494', hex: '00529B' },
  { key: 'indianbank', title: 'Indian Bank', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/INDIANB.NS-f5d0c2a3.svg?download=true&t=1746790300', hex: '006CB7' },
  { key: 'kotakmahindra', title: 'Kotak Mahindra Bank', bank: true, country: 'India', source: 'raster', image: 'https://companieslogo.com/img/orig/KOTAKBANK.NS-36440c5e.png?t=1720244492', hex: '003A78' },
  { key: 'kotak811', title: 'Kotak 811', bank: true, country: 'India', source: 'inline', hex: 'F90045' },
  { key: 'equitas', title: 'Equitas Small Finance Bank', bank: true, country: 'India', source: 'inline', hex: '214D86' },
  { key: 'aubank', title: 'AU Small Finance Bank', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/AUBANK.NS-d9d16ad7.svg?download=true&t=1768443315', hex: 'E31E24' },
  { key: 'uco', title: 'UCO Bank', bank: true, country: 'India', source: 'inline', hex: '003F7F' },
  { key: 'ksfe', title: 'KSFE', bank: true, country: 'India', source: 'inline', hex: '007A3D' },
  { key: 'keralagramin', title: 'Kerala Gramin Bank', bank: true, country: 'India', source: 'visual', url: 'https://img.mathrubhumi.com/view/acePublic/alias/contentid/1i4jbp05wyki2l1j4pc/1/kerala-gramin-bank.webp?f=3%3A2&q=0.75&w=900', hex: '006B54' },
  { key: 'manappuram', title: 'Manappuram Finance', bank: true, country: 'India', source: 'inline', hex: 'F5A623' },
  { key: 'bajajfinance', title: 'Bajaj Finance', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/BAJFINANCE.NS-1c491b90.svg?download=true&t=1729491498', hex: '085FAC' },
  { key: 'federalbank', title: 'Federal Bank', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/FEDERALBNK.NS-7c827449.svg?t=1768446273&download=true', hex: '7B2D8E' },
  { key: 'bandhanbank', title: 'Bandhan Bank', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/BANDHANBNK.NS-0cc3da43.svg?t=1745810711&download=true', hex: 'B6202A' },
  { key: 'bankofindia', title: 'Bank of India', bank: true, country: 'India', source: 'raster', image: 'https://companieslogo.com/img/orig/BANKINDIA.NS-e3d88e01.png?t=1720244490', hex: '0067A5' },
  { key: 'indusindbank', title: 'IndusInd Bank', bank: true, country: 'India', source: 'raster', image: 'https://companieslogo.com/img/orig/INDUSINDBK.NS-29bfd69e.png?t=1720244492', hex: '8B1E3F' },
  { key: 'bankofmaharashtra', title: 'Bank of Maharashtra', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/MAHABANK.NS-b7bfb717.svg?t=1749224623&download=true', hex: '0B4C8C' },
  { key: 'karurvysyabank', title: 'Karur Vysya Bank', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/KARURVYSYA.NS-84ba0f96.svg?t=1746460251&download=true', hex: '007A4D' },
  { key: 'tmb', title: 'Tamilnad Mercantile Bank', bank: true, country: 'India', source: 'wikimedia', file: 'TMB SVG Logo.svg', hex: '3052A1' },
  { key: 'southindianbank', title: 'South Indian Bank', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/SOUTHBANK.NS-37fd569e.svg?t=1729770234&download=true', hex: '9D2235' },
  { key: 'karnatakabank', title: 'Karnataka Bank', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/KTKBANK.NS-56364bdf.svg?t=1746197860&download=true', hex: '7A263A' },
  { key: 'cityunionbank', title: 'City Union Bank', bank: true, country: 'India', source: 'raster', image: 'https://companieslogo.com/img/orig/CUB.NS-9eb81137.png?t=1720244491', hex: '006A4D' },
  { key: 'idbibank', title: 'IDBI Bank', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/IDBI.NS-49d7d1b9.svg?t=1745688100&download=true', hex: '00836B' },
  { key: 'csbbank', title: 'CSB Bank', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/CSBBANK.NS-3689f45f.svg?t=1746536267&download=true', hex: 'A71930' },
  { key: 'centralbankindia', title: 'Central Bank of India', bank: true, country: 'India', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/CENTRALBK.NS-bb87fd60.svg?t=1720244491&download=true', hex: '003B70' },
  { key: 'esafbank', title: 'ESAF Small Finance Bank', bank: true, country: 'India', source: 'visual', url: COMMONS('ESAF Bank Logo.svg'), hex: '243B77' },
  { key: 'keralabank', title: 'Kerala Bank', bank: true, country: 'India', source: 'visual', url: COMMONS('KERALA STATE CO-OPERATIVE BANK LTD (KERALA BANK) Logo.svg'), hex: '00529B' },
  { key: 'punjabsindbank', title: 'Punjab & Sind Bank', bank: true, country: 'India', source: 'raster', image: 'https://companieslogo.com/img/orig/PSB.NS-210860d7.png?t=1720244493', hex: 'F58220' },
];

const countryFolder = (country) => country
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, '_')
  .replace(/^_|_$/g, '');
const brandDirectory = (base, { bank, country }) => bank
  ? join(base, 'banks', countryFolder(country))
  : join(base, 'brands');
const brandFile = (base, brand, suffix = '') =>
  join(brandDirectory(base, brand), `${brand.key}${suffix}.webp`);
const brandsByKey = new Map(BRANDS.map((brand) => [brand.key, brand]));

const onlyKeys = process.argv.includes('--only')
  ? new Set(process.argv.slice(process.argv.indexOf('--only') + 1))
  : null;
const catalogOnly = process.argv.includes('--catalog-only');
const selectedBrands = onlyKeys
  ? BRANDS.filter(({ key }) => onlyKeys.has(key))
  : BRANDS;
if (onlyKeys && selectedBrands.length !== onlyKeys.size) {
  throw new Error('Unknown brand key in --only selection');
}
const icons = selectedBrands.some(({ source }) => !source || source === 'simple-icons')
  ? await (await fetch(`${RAW}/data/simple-icons.json`)).json()
  : [];

mkdirSync(OUT_DIR, { recursive: true });
const entries = [];

for (const {
  key,
  title,
  bank = false,
  country,
  payment = false,
  source = 'simple-icons',
  file,
  image,
  url,
  from,
  siTitle,
  hex,
} of selectedBrands) {
  const currentBrand = { key, bank, country };
  const outputDirectory = brandDirectory(OUT_DIR, currentBrand);
  const outputPath = brandFile(OUT_DIR, currentBrand);
  mkdirSync(outputDirectory, { recursive: true });
  let color = hex;
  let svgUrl;
  let svg;
  let rasterData;
  if (catalogOnly) {
    if (!existsSync(outputPath)) {
      if (source === 'visual') {
        // Not downloaded yet (e.g. source site rate limited): leave it out of
        // the catalog until its asset exists, then rerun --only <key>.
        console.warn(`SKIPPING catalog entry without asset: ${key}`);
        continue;
      }
      throw new Error(`Missing bundled asset for catalog entry: ${key}`);
    }
    if (source === 'simple-icons') {
      const meta = icons.find((item) => item.title === (siTitle ?? title));
      if (!meta) throw new Error(`MISSING from simple-icons: ${title}`);
      color = meta.hex;
    }
    entries.push({ key, title, hex: color, bank, country, payment,
      isOriginal: source !== 'simple-icons' });
    continue;
  }
  if (source === 'copy') {
    // Same artwork as another registered institution (e.g. Chase UK = Chase).
    const sourceBrand = brandsByKey.get(from);
    if (sourceBrand == null) throw new Error(`Unknown copy source: ${from}`);
    copyFileSync(brandFile(OUT_DIR, sourceBrand), outputPath);
    entries.push({ key, title, hex: color, bank, country, payment, isOriginal: true });
    continue;
  }
  if (source === 'visual') {
    // Originals are kept under icons/bank_sources/ so reruns need no network.
    const ext = (url.split('?')[0].match(/\.(svg|png|jpe?g)$/i)?.[1] ?? 'png').toLowerCase();
    // CPA previously used a small horizontal website lockup cached as
    // cpaalgeria.png. Keep that source for provenance, but use a distinct
    // cache name for the complete official mobile-app emblem.
    const cacheKey = key === 'cpaalgeria' ? 'cpaalgeria-mobile' : key;
    const cached = join(SOURCE_DIR, `${cacheKey}.${ext}`);
    try {
      let bytes;
      if (existsSync(cached)) {
        bytes = readFileSync(cached);
      } else {
        bytes = await fetchBytes(url);
        mkdirSync(SOURCE_DIR, { recursive: true });
        writeFileSync(cached, bytes);
      }
      const out = await renderVisual(key, bytes, ext === 'svg');
      await out.toFile(outputPath);
    } catch (error) {
      if (onlyKeys == null) throw error;
      console.error(`SKIPPED ${key}: ${error.message}`);
      continue;
    }
    entries.push({ key, title, hex: color, bank, country, payment, isOriginal: true });
    continue;
  }
  if (source === 'simple-icons') {
    const meta = icons.find((item) => item.title === (siTitle ?? title));
    if (!meta) {
      console.error(`MISSING from simple-icons: ${title}`);
      continue;
    }
    const slug = (siTitle ?? title)
      .toLowerCase()
      .replace(/\+/g, 'plus')
      .replace(/[^a-z0-9]/g, '');
    color = meta.hex;
    svgUrl = `${RAW}/icons/${slug}.svg`;
  } else if (source === 'wikimedia') {
    svgUrl = `https://commons.wikimedia.org/wiki/Special:FilePath/${encodeURIComponent(file)}`;
  } else if (source === 'remote-svg') {
    svgUrl = url;
  } else if (source === 'page-svg') {
    const pageRes = await fetch(url);
    if (!pageRes.ok) throw new Error(`MISSING page for ${title}, HTTP ${pageRes.status}`);
    const page = await pageRes.text();
    svg = page.match(/<a\b[^>]*class="logo"[^>]*>\s*(<svg\b[\s\S]*?<\/svg>)/i)?.[1];
    if (!svg) throw new Error(`MISSING official inline svg for ${title}`);
  } else if (source === 'raster' || source === 'wikimedia-raster') {
    const imageUrl = source === 'raster'
        ? image
        : `https://commons.wikimedia.org/wiki/Special:FilePath/${encodeURIComponent(file)}?width=256`;
    const rasterExt = (source === 'raster' ? image : file)
      .split('?')[0].match(/\.(png|jpe?g|webp)$/i)?.[1]?.toLowerCase() ?? 'png';
    const rasterCache = join(SOURCE_DIR, `${key}.${rasterExt}`);
    if (existsSync(rasterCache)) {
      rasterData = readFileSync(rasterCache);
    } else {
      const imageRes = await fetch(imageUrl);
      if (!imageRes.ok) {
        throw new Error(`MISSING image for ${title}, HTTP ${imageRes.status}`);
      }
      rasterData = Buffer.from(await imageRes.arrayBuffer());
      mkdirSync(SOURCE_DIR, { recursive: true });
      writeFileSync(rasterCache, rasterData);
    }
  } else if (source === 'inline') {
    svg = MARK_ONLY_SVGS[key];
  } else {
    throw new Error(`Unsupported icon source: ${source}`);
  }
  const svgCache = source === 'wikimedia'
    ? join(SOURCE_DIR, `${key}.svg`)
    : null;
  if (svg == null && svgCache != null && existsSync(svgCache)) {
    svg = readFileSync(svgCache, 'utf8');
  }
  if (svg == null && rasterData == null) {
    let svgRes = await fetch(svgUrl);
    // Special:FilePath is occasionally rate-limited even when Commons' API
    // and upload host are healthy. Resolve the canonical original URL through
    // imageinfo so focused repair runs do not fail on that redirect endpoint.
    if (!svgRes.ok && source === 'wikimedia') {
      const apiUrl = 'https://commons.wikimedia.org/w/api.php?' + new URLSearchParams({
        action: 'query',
        format: 'json',
        prop: 'imageinfo',
        iiprop: 'url',
        titles: `File:${file}`,
      });
      const apiRes = await fetch(apiUrl, {
        headers: { 'User-Agent': 'SimpleMoney icon maintenance/1.0' },
      });
      if (apiRes.ok) {
        const api = await apiRes.json();
        const page = Object.values(api.query?.pages ?? {})[0];
        const originalUrl = page?.imageinfo?.[0]?.url;
        if (originalUrl) {
          svgRes = await fetch(originalUrl, {
            headers: { 'User-Agent': 'SimpleMoney icon maintenance/1.0' },
          });
        }
      }
    }
    if (!svgRes.ok) {
      if (onlyKeys) throw new Error(`MISSING svg for ${title}, HTTP ${svgRes.status}`);
      const existingPath = outputPath;
      if (!existsSync(existingPath)) {
        console.error(`MISSING svg for ${title}, HTTP ${svgRes.status}`);
        continue;
      }
      // The bundled asset is already a rasterized WebP — there's no SVG text
      // left to reprocess (crop/isolateBankMark), so just keep the existing
      // file as-is rather than fail the whole run.
      console.warn(
        `KEEPING existing webp for ${title}, download returned HTTP ${svgRes.status}`,
      );
      entries.push({
        key,
        title,
        hex: color,
        bank,
        country,
        payment,
        isOriginal:
          source === 'wikimedia' ||
          source === 'remote-svg' ||
          source === 'page-svg' ||
          source === 'raster' ||
          source === 'wikimedia-raster' ||
          source === 'inline',
      });
      continue;
    } else {
      svg = await svgRes.text();
      if (svgCache != null) {
        mkdirSync(SOURCE_DIR, { recursive: true });
        writeFileSync(svgCache, svg);
      }
    }
  }
  if (rasterData != null) {
    if (key === 'jaizbank') {
      // The Commons JPEG is a full lockup on white. Keep its interlocking
      // gold/green identity mark and reconstruct transparency from the white
      // source canvas; the bank name and slogan are deliberately excluded.
      const { data, info } = await sharp(rasterData)
        .extract({ left: 220, top: 0, width: 110, height: 110 })
        .ensureAlpha().raw().toBuffer({ resolveWithObject: true });
      for (let i = 0; i < data.length; i += 4) {
        // JPEG compression adds neutral grey speckles around the white
        // canvas. Both official mark colours are strongly chromatic, so use
        // colour range for edge coverage and discard those neutral artefacts.
        const red = data[i];
        const green = data[i + 1];
        const blue = data[i + 2];
        const greenInk = Math.min(green - red, green - blue);
        const goldInk = Math.min(red - blue, green - blue);
        const inkStrength = Math.max(greenInk, goldInk);
        data[i + 3] = Math.max(0, Math.min(255, (inkStrength - 18) * 7));
      }
      rasterData = await sharp(data, {
        raw: { width: info.width, height: info.height, channels: 4 },
      }).trim().png().toBuffer();
    }
    if (key === 'keystonebank') {
      // Commons includes the wordmark and slogan. Its geometric keystone
      // symbol is already transparent and can be cropped without alteration.
      const { data, info } = await sharp(rasterData)
        .extract({ left: 0, top: 8, width: 125, height: 130 })
        .ensureAlpha().raw().toBuffer({ resolveWithObject: true });
      for (let i = 0; i < data.length; i += 4) {
        const distance = Math.hypot(
          data[i] - 20, data[i + 1] - 33, data[i + 2] - 66,
        );
        if (distance < 12) data[i + 3] = 0;
        else if (distance < 40) data[i + 3] = Math.round(data[i + 3] * (distance - 12) / 28);
      }
      rasterData = await sharp(data, {
        raw: { width: info.width, height: info.height, channels: 4 },
      }).trim().png().toBuffer();
    }
    if (key === 'keralavision' || key === 'excitel') {
      const crop = key === 'keralavision'
        ? { left: 145, top: 48, width: 220, height: 244 }
        : { left: 855, top: 590, width: 165, height: 165 };
      const { data, info } = await sharp(rasterData).extract(crop)
        .ensureAlpha().raw().toBuffer({ resolveWithObject: true });
      for (let i = 0; i < data.length; i += 4) {
        if (key === 'keralavision') {
          // Original solid cyan background, including gaps inside the symbol.
          if (data[i] < 45 && data[i + 1] > 110 && data[i + 2] > 160) data[i + 3] = 0;
        } else {
          // The banner's white logo on blue: preserve source edge coverage.
          data[i + 3] = Math.max(0, Math.min(255, Math.round((data[i] - 5) * 255 / 250)));
          data[i] = 255; data[i + 1] = 109; data[i + 2] = 26;
        }
      }
      rasterData = await sharp(data, { raw: { width: info.width, height: info.height, channels: 4 } })
        .trim().extend({ top: 14, bottom: 14, left: 14, right: 14, background: '#00000000' })
        .png().toBuffer();
    }
    let rasterOutput = sharp(rasterData);
    if (key === 'jaizbank') {
      // The source crop contains the complete interlocking mark, but fitting
      // it directly to 256px made its outer strokes look clipped by the tile.
      rasterOutput = rasterOutput
        .resize(236, 236, { fit: 'contain', background: '#00000000' })
        .extend({ top: 10, bottom: 10, left: 10, right: 10, background: '#00000000' });
    } else {
      rasterOutput = rasterOutput.resize(256, 256, {
        fit: 'contain',
        background: { r: 0, g: 0, b: 0, alpha: 0 },
      });
    }
    await rasterOutput
      .webp({ quality: 90, alphaQuality: 100, effort: 6 })
      .toFile(outputPath);
    entries.push({ key, title, hex: color, bank, country, payment, isOriginal: true });
    continue;
  }
  svg = key === 'sbicard' ? svg : isolateBankMark(key, svg);
  if (key === 'actfibernet') {
    // Retain the complete recognizable ACT logo, with a clean transparent canvas.
    svg = svg.replace(/<rect width="89\.6" height="32" fill="white"\/>/, '');
    svg = svg.replace('viewBox="0 0 90 32"', 'viewBox="-5 -34 100 100"');
    svg = svg.replace('width="90" height="32"', 'width="100" height="100"');
  }
  if (key === 'tataplayfiber') {
    await sharp(Buffer.from(svg), { density: 300 })
      .resize(256, 256, { fit: 'contain', background: '#00000000' })
      .webp({ quality: 90, alphaQuality: 100, effort: 6 })
      .toFile(brandFile(OUT_DIR, currentBrand, '_dark'));
    svg = svg.replace(/fill="white"/g, 'fill="#000000"');
  }
  if (key === 'cred') {
    const darkSvg = svg;
    await sharp(Buffer.from(darkSvg), { density: 300 })
      .resize(256, 256, { fit: 'contain', background: '#00000000' })
      .webp({ quality: 90, alphaQuality: 100, effort: 6 })
      .toFile(brandFile(OUT_DIR, currentBrand, '_dark'));
    svg = svg.replace(/fill="#fff"/gi, 'fill="#000000"');
  }
  if (key === 'zee5') {
    // The provider's icon has a full-canvas gradient rect. Keep just the mark.
    svg = svg.replace(/<rect\b[^>]*\/>/gi, '');
    svg = svg.replace(/fill="white"/gi, 'fill="#000000"');
    const darkSvg = svg.replace(/fill="#000000"/gi, 'fill="#FFFFFF"');
    await sharp(Buffer.from(darkSvg), { density: 300 })
      .resize(256, 256, { fit: 'contain', background: '#00000000' })
      .webp({ quality: 90, alphaQuality: 100, effort: 6 })
      .toFile(brandFile(OUT_DIR, currentBrand, '_dark'));
  }
  // Bake Simple Icons' catalog colors into WebP assets for direct rendering.
  if (source === 'simple-icons') {
    svg = svg.replace(/<svg\b/i, `<svg fill="#${color}"`);
  }
  // Some upstream Wikimedia files keep editor-only namespaced attributes
  // after omitting the namespace declaration. They do not affect rendering,
  // but librsvg correctly rejects the malformed XML unless they are removed.
  svg = svg.replace(/\s(?:inkscape|sodipodi):[\w-]+=("[^"]*"|'[^']*')/gi, '');
  if (key === 'sbicard') {
    // Crop the symbol/SBI and Card from the original vector, then stack them.
    const source = await sharp(Buffer.from(svg), { density: 300 })
      .resize(1216, 240).png().toBuffer();
    const sbi = await sharp(source).extract({ left: 0, top: 0, width: 570, height: 240 })
      .resize(220, 93).png().toBuffer();
    const card = await sharp(source).extract({ left: 608, top: 0, width: 608, height: 240 })
      .resize(220, 87).png().toBuffer();
    await sharp({ create: { width: 256, height: 256, channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 } } })
      .composite([{ input: sbi, left: 18, top: 36 }, { input: card, left: 18, top: 134 }])
      .webp({ quality: 90, alphaQuality: 100, effort: 6 })
      .toFile(outputPath);
    entries.push({ key, title, hex: color, bank, country, payment, isOriginal: true });
    continue;
  }
  const crop = BANK_MARK_CROPS[key];
  if (crop != null) {
    const [x, y, width, height] = crop.split(/\s+/);
    svg = svg.replace(/<svg\b[^>]*>/i, (tag) => {
      const normalized = tag
        .replace(/\s(?:width|height|viewBox)=["'][^"']*["']/gi, '')
        .replace(/>$/, '');
      return `${normalized} width="48" height="48" viewBox="${crop}"><defs><clipPath id="bank-mark-clip"><rect x="${x}" y="${y}" width="${width}" height="${height}"/></clipPath></defs><g clip-path="url(#bank-mark-clip)">`;
    });
    svg = svg.replace(/<\/svg>\s*$/i, '</g></svg>');
  }
  let svgOutput = sharp(Buffer.from(svg), { density: 300 });
  const needsMarkPadding = crop != null ||
    key === 'bca' || key === 'firstabudhabibank' || key === 'siamcommercialbank';
  if (needsMarkPadding) {
    svgOutput = svgOutput
      .resize(236, 236, { fit: 'contain', background: '#00000000' })
      .extend({ top: 10, bottom: 10, left: 10, right: 10, background: '#00000000' });
  } else {
    svgOutput = svgOutput.resize(256, 256, {
      fit: 'contain',
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    });
  }
  await svgOutput
    .webp({ quality: 90, alphaQuality: 100, effort: 6 })
    .toFile(outputPath);
  entries.push({
    key,
    title,
    hex: color,
    bank,
    country,
    payment,
    isOriginal:
      source === 'wikimedia' ||
      source === 'remote-svg' ||
      source === 'page-svg' ||
      source === 'raster' ||
      source === 'wikimedia-raster' ||
      source === 'inline',
  });
}

if (!catalogOnly) {
  mkdirSync(RAW_OUT_DIR, { recursive: true });
  for (const brand of selectedBrands) {
    const generated = brandFile(OUT_DIR, brand);
    if (existsSync(generated)) {
      const rawDirectory = brandDirectory(RAW_OUT_DIR, brand);
      mkdirSync(rawDirectory, { recursive: true });
      copyFileSync(generated, brandFile(RAW_OUT_DIR, brand));
    }
  }
}

const dartEntries = entries
  .map((entry) => {
    const options = [
      entry.bank && 'isBank: true',
      entry.country && `bankCountry: ${JSON.stringify(entry.country)}`,
      BRANDS.find((b) => b.key === entry.key)?.broker && 'isBroker: true',
      entry.payment && 'isPayment: true',
      entry.isOriginal && 'isOriginal: true',
    ].filter(Boolean);
    return `  BrandIcon('${entry.key}', ${JSON.stringify(entry.title)}, Color(0xFF${entry.hex})${options.length == 0 ? '' : `, ${options.join(', ')}`}),`;
  })
  .join('\n');

const dart = `// GENERATED by tool/fetch_brand_icons.mjs — do not hand-edit.
// Sources: Simple Icons, Wikimedia Commons, and provider websites.
// assets/icon_packs/logos/ATTRIBUTION.md for asset-source details.
import 'package:flutter/material.dart';

class BrandIcon {
  const BrandIcon(
    this.key,
    this.title,
    this.color, {
    this.isBank = false,
    this.isPayment = false,
    this.isBroker = false,
    this.isOriginal = false,
    this.bankCountry,
  });
  final String key, title;
  final Color color;
  final bool isBank;
  final bool isPayment;

  /// A broker or investing platform, listed in the picker's Brokers section.
  final bool isBroker;
  final bool isOriginal;
  final String? bankCountry;
}

const brandIcons = <BrandIcon>[
${dartEntries}
];
`;
if (!onlyKeys) writeFileSync(DART_OUT, dart);
console.log(`fetched ${entries.length}/${selectedBrands.length} brand icons`);
