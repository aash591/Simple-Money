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
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const APP = dirname(dirname(fileURLToPath(import.meta.url)));
const OUT_DIR = join(APP, 'assets/icon_packs/brands');
const DART_OUT = join(APP, 'lib/domain/brand_icons.dart');
const RAW = 'https://raw.githubusercontent.com/simple-icons/simple-icons/develop';

// Mark-only crop boxes for source files that contain a horizontal wordmark.
// Values are applied to the generated SVG itself, producing a square icon
// asset with no bank-name fragments. Icon-only sources need no crop.
const BANK_MARK_CROPS = {
  bsnl: '95 0 180 135',
  btn: '0 0 165 157.35',
  mandiri: '8 0 44 8',
  keralagramin: '20 0 60 48',
  tmb: '0 0 95 61.647914',
};

function inlineClassFills(svg) {
  const fills = new Map();
  for (const match of svg.matchAll(/\.([\w-]+)\s*\{\s*fill:\s*(#[0-9a-f]{3,8})\s*;?\s*\}/gi)) {
    fills.set(match[1], match[2]);
  }
  for (const [className, fill] of fills) {
    svg = svg.replaceAll(`class="${className}"`, `fill="${fill}"`);
  }
  return svg.replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, '');
}

function isolateBankMark(key, svg) {
  svg = inlineClassFills(svg);
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
  return svg;
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
  { key: 'americanexpress', title: 'American Express', payment: true },
  { key: 'discover', title: 'Discover', payment: true },
  { key: 'jcb', title: 'JCB', payment: true },
  { key: 'dinersclub', title: 'Diners Club', payment: true },
  { key: 'stripe', title: 'Stripe', payment: true },
  { key: 'square', title: 'Square', payment: true },
  { key: 'klarna', title: 'Klarna', payment: true },
  { key: 'revolut', title: 'Revolut', payment: true },
  { key: 'wise', title: 'Wise', payment: true },
  { key: 'monzo', title: 'Monzo', payment: true },
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
  { key: 'binance', title: 'Binance', payment: true },
  { key: 'coinbase', title: 'Coinbase', payment: true },
  { key: 'robinhood', title: 'Robinhood', payment: true },
  { key: 'zerodha', title: 'Zerodha', payment: true },
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
  // Original bank marks from Wikimedia Commons.
  { key: 'bri', title: 'BRI', bank: true, country: 'Indonesia', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/BBRI.JK-30a60327.svg?download=true&t=1720244490', hex: '00529C' },
  { key: 'bca', title: 'BCA', bank: true, country: 'Indonesia', source: 'wikimedia', file: 'Bank Central Asia.svg', hex: '003D7C' },
  { key: 'bni', title: 'BNI', bank: true, country: 'Indonesia', source: 'remote-svg', url: 'https://companieslogo.com/img/orig/BBNI.JK-68793c4c.svg?download=true&t=1782765734', hex: 'F15A22' },
  { key: 'btn', title: 'BTN', bank: true, country: 'Indonesia', source: 'wikimedia', file: 'Bank Tabungan Negara logo.svg', hex: '005BAC' },
  { key: 'mandiri', title: 'Mandiri', bank: true, country: 'Indonesia', source: 'wikimedia', file: 'Bank Mandiri logo 2016.svg', hex: '003E7E' },
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
  { key: 'keralagramin', title: 'Kerala Gramin Bank', bank: true, country: 'India', source: 'raster', image: 'https://img.mathrubhumi.com/view/acePublic/alias/contentid/1i4jbp05wyki2l1j4pc/1/kerala-gramin-bank.webp?f=3%3A2&q=0.75&w=900', hex: '006B54' },
  { key: 'manappuram', title: 'Manappuram Finance', bank: true, country: 'India', source: 'inline', hex: 'F5A623' },
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
  { key: 'punjabsindbank', title: 'Punjab & Sind Bank', bank: true, country: 'India', source: 'raster', image: 'https://companieslogo.com/img/orig/PSB.NS-210860d7.png?t=1720244493', hex: 'F58220' },
];

const onlyKeys = process.argv.includes('--only')
  ? new Set(process.argv.slice(process.argv.indexOf('--only') + 1))
  : null;
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
  hex,
} of selectedBrands) {
  let color = hex;
  let svgUrl;
  let svg;
  let rasterData;
  if (source === 'simple-icons') {
    const meta = icons.find((item) => item.title === title);
    if (!meta) {
      console.error(`MISSING from simple-icons: ${title}`);
      continue;
    }
    const slug = title
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
    const imageRes = await fetch(imageUrl);
    if (!imageRes.ok) {
      throw new Error(`MISSING image for ${title}, HTTP ${imageRes.status}`);
    }
    rasterData = Buffer.from(await imageRes.arrayBuffer());
  } else if (source === 'inline') {
    svg = MARK_ONLY_SVGS[key];
  } else {
    throw new Error(`Unsupported icon source: ${source}`);
  }
  if (svg == null && rasterData == null) {
    const svgRes = await fetch(svgUrl);
    if (!svgRes.ok) {
      if (onlyKeys) throw new Error(`MISSING svg for ${title}, HTTP ${svgRes.status}`);
      const existingPath = join(OUT_DIR, `${key}.webp`);
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
    }
  }
  if (rasterData != null) {
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
    await sharp(rasterData)
      .resize(256, 256, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .webp({ quality: 90, alphaQuality: 100, effort: 6 })
      .toFile(join(OUT_DIR, `${key}.webp`));
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
      .toFile(join(OUT_DIR, 'tataplayfiber_dark.webp'));
    svg = svg.replace(/fill="white"/g, 'fill="#000000"');
  }
  if (key === 'cred') {
    const darkSvg = svg;
    await sharp(Buffer.from(darkSvg), { density: 300 })
      .resize(256, 256, { fit: 'contain', background: '#00000000' })
      .webp({ quality: 90, alphaQuality: 100, effort: 6 })
      .toFile(join(OUT_DIR, 'cred_dark.webp'));
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
      .toFile(join(OUT_DIR, 'zee5_dark.webp'));
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
      .toFile(join(OUT_DIR, `${key}.webp`));
    entries.push({ key, title, hex: color, bank, country, payment, isOriginal: true });
    continue;
  }
  const crop = BANK_MARK_CROPS[key];
  if (crop != null) {
    svg = svg.replace(/<svg\b[^>]*>/i, (tag) => {
      const normalized = tag
        .replace(/\s(?:width|height|viewBox)=["'][^"']*["']/gi, '')
        .replace(/>$/, '');
      return `${normalized} width="48" height="48" viewBox="${crop}">`;
    });
  }
  await sharp(Buffer.from(svg), { density: 300 })
    .resize(256, 256, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .webp({ quality: 90, alphaQuality: 100, effort: 6 })
    .toFile(join(OUT_DIR, `${key}.webp`));
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

const dartEntries = entries
  .map((entry) => {
    const options = [
      entry.bank && 'isBank: true',
      entry.country && `bankCountry: ${JSON.stringify(entry.country)}`,
      entry.payment && 'isPayment: true',
      entry.isOriginal && 'isOriginal: true',
    ].filter(Boolean);
    return `  BrandIcon('${entry.key}', ${JSON.stringify(entry.title)}, Color(0xFF${entry.hex})${options.length == 0 ? '' : `, ${options.join(', ')}`}),`;
  })
  .join('\n');

const dart = `// GENERATED by tool/fetch_brand_icons.mjs — do not hand-edit.
// Sources: Simple Icons, Wikimedia Commons, and provider websites.
// assets/icon_packs/brands/ATTRIBUTION.md for asset-source details.
import 'package:flutter/material.dart';

class BrandIcon {
  const BrandIcon(
    this.key,
    this.title,
    this.color, {
    this.isBank = false,
    this.isPayment = false,
    this.isOriginal = false,
    this.bankCountry,
  });
  final String key, title;
  final Color color;
  final bool isBank;
  final bool isPayment;
  final bool isOriginal;
  final String? bankCountry;
}

const brandIcons = <BrandIcon>[
${dartEntries}
];
`;
if (!onlyKeys) writeFileSync(DART_OUT, dart);
console.log(`fetched ${entries.length}/${selectedBrands.length} brand icons`);
