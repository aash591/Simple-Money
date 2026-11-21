# Brand icon sources

CRED uses the original transparent vertical light/dark SVG logos from its
[official brand kit](https://newsroom.cred.club/brand/), preserving the complete
shield and wordmark in both theme variants.

Prime Video uses the transparent blue logo from
[Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Prime_Video_logo_(2024).svg),
preserving the source paths and color without an app-icon background.

JioHotstar uses the transparent star symbol from
[Dashboard Icons](https://github.com/homarr-labs/dashboard-icons/blob/main/png/jiohotstar.png).
ZEE5 uses the mark paths from its
[official SVG](https://www.zee5.com/images/ZEE5_logo.svg?ver=7.1.7), with the
full-canvas background removed and monochrome black/white theme variants.
These are transparent mark-only WebPs; no rectangular logo backgrounds are bundled.

The mark-only bank assets use high-resolution transparent symbol artwork from
[CompaniesLogo](https://companieslogo.com/) where available. The BCA, BTN, and
Mandiri vectors are isolated from original logo SVGs hosted by
[Wikimedia Commons](https://commons.wikimedia.org/); their wordmark paths are
excluded from the generated assets.

The mark-only `uco`, `ksfe`, and `manappuram` vectors were reconstructed from
high-resolution original logo references found through image search. The
`keralagramin` SVG embeds isolated source artwork from the same research.

Bajaj Finance uses the standalone symbol from
[CompaniesLogo](https://companieslogo.com/bajaj-finance/logo/). The source's
blue tile is removed and its white reverse mark is rendered in the same
official blue as a 256px transparent WebP. Regenerate it from `app/` with
`node tool/fetch_brand_icons.mjs --only bajajfinance`.

The added service marks use original artwork, resized onto transparent 256 px
WebP canvases. [Ola](https://commons.wikimedia.org/wiki/File:Ola_Cabs_logo.svg),
[KSEB](https://commons.wikimedia.org/wiki/File:KSEB_Logo_2022.svg),
[redBus](https://commons.wikimedia.org/wiki/File:RedBus_Logo_(2015-present).svg),
[BSNL](https://commons.wikimedia.org/wiki/File:BSNL_logo_with_slogan.svg),
[Vi](https://commons.wikimedia.org/wiki/File:Vodafone_Idea_logo_(2026).svg),
[Kochi Metro](https://commons.wikimedia.org/wiki/File:Kochi_Metro_logo.png),
[Delhi Metro](https://commons.wikimedia.org/wiki/File:Delhi_Metro_logo.svg),
[Namma Metro](https://commons.wikimedia.org/wiki/File:Namma_metro_icon.svg),
[Chennai Metro](https://commons.wikimedia.org/wiki/File:Chennai_Metro_logo.svg),
[Hyderabad Metro](https://commons.wikimedia.org/wiki/File:Seal_of_Hyderabad_Metro_Rail.svg),
and [Mumbai Metro](https://commons.wikimedia.org/wiki/File:Mumbai_metro_Logo.png)
come from Wikimedia Commons. Their individual file pages contain the source
and reuse terms. [Rapido](https://rapido.bike/images/NewLogo.svg),
[Namma Yatri](https://www.nammayatri.in/WebsiteIcon.svg),
[Kerala Water Authority](https://kwa.kerala.gov.in/wp-content/uploads/2020/07/og_logo.webp),
[IRCTC](https://www.irctc.com/), and
[Asianet Broadband](https://asianetbroadband.in/wp-content/uploads/2024/01/AF_logo.png)
come from the providers' websites; the IRCTC emblem is the inline SVG in its
site header. These files identify a provider and do not imply endorsement.
The [Kerala KSRTC](https://play.google.com/store/apps/details?id=com.keralasrtc.app)
badge is from its official app listing. The BSNL asset uses the globe and
arrows from the linked vector. Asianet uses a transparent PNG from its site.

The Equitas and Kotak 811 marks were recreated from high-resolution bank and
press references. Amazon and Kotak Mahindra use transparent symbol assets from
CompaniesLogo. The OpenAI Blossom follows OpenAI's current official design
guidelines and uses a mark-only Wikimedia vector. Flipkart, Microsoft, Adobe,
Domino's, and Myntra are transparent mark-only reconstructions; no wordmark
fallbacks are offered in the picker.

All other SVGs in this directory are from [Simple Icons](https://github.com/simple-icons/simple-icons), licensed CC0.
Brand names and marks remain their respective owners' trademarks and are used
only to identify a user's selected financial institution or service.

OneCard and BOBCARD use their official Google Play app icons: [OneCard](https://play.google.com/store/apps/details?id=com.creditcard.onecard) and [BOBCARD](https://play.google.com/store/apps/details?id=com.bob.fe). SBI Card uses a [transparent Wikimedia vector](https://commons.wikimedia.org/wiki/File:SBI_Card_logo.svg); its original symbol, SBI letters, and Card letters are stacked to fit the square icon. These sources are resized to the same 256 px WebP canvas as the other brand assets.

Simple Icons' catalog colors are baked into their normal WebP files; the app
does not tint them at render time. The small set of `*_dark.webp` companions
is explicitly selected and treated per logo in
`tool/generate_brand_dark_variants.mjs` after checking the normal marks on
the picker's dark tile. Readable originals, including Equitas and BTN, are
used in both themes. Selected companions use a white reverse while retaining
each mark's distinctive accents. This follows the dark-use
patterns in [Visa's standards](https://corporate.visa.com/en/about-visa/brand.html),
[Samsung Pay's guidelines](https://developer.paypal.com/braintree/files/samsung-pay-brand-guidelines.pdf),
[BCA's identity manual](https://www.bca.co.id/-/media/Feature/Card/List-Card/Tentang-BCA/Brand-Assets/PDF/Corporate-Identity-Manual--CIM--BCA.pdf),
and [Amazon's reverse-logo examples](https://developer.amazon.com/en-US/alexa/branding/echo-guidelines/identity-guidelines/logo-guidelines).
Jio's companion uses the [Reliance media kit](https://www.beta-prod.ril.com/news-media/resource-center/media-kit/jio) monochrome artwork, with its circle changed to the blue of the normal Jio asset and its letters kept white.
PayPal keeps its dark-blue mark on a white badge, in line with [PayPal's logo guidance](https://www.paypalobjects.com/webstatic/en_US/developer/docs/pdf/PayPalX_Interface_Guide_Edition1_1.pdf).

Meesho uses the transparent symbol SVG from
[CompaniesLogo](https://companieslogo.com/meesho/logo/).
Disney+ uses the transparent original logo from
[Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Disney%2B_2024.svg).
Both use transparent 256px lossy WebP canvases (quality 90, alpha quality 100).
Regenerate only these assets with `node tool/fetch_brand_icons.mjs --only meesho disneyplus`
from `app/`, and retain copies in `assets_raw/icon_packs_raw/logos/`.

## Indian internet providers

These original logos are sourced from the providers' own websites:
- [Kerala Vision Broadband](https://keralavisionisp.com/) (`assets/logo-Dnpp9r7N.png`).
- [ACT Fibernet](https://www.actcorp.in/) (`themes/custom/actcorp/logo.svg`); the visible white canvas is removed, preserving the mark and clipping path.
- [Excitel](https://www.excitel.com/) (`wp-content/uploads/2022/07/logo-excitel.png`).
- [Hathway](https://www.hathway.com/) (`home_images/logo.svg`).
- [Tata Play Fiber](https://www.tataplayfiber.com/) (`themes/custom/tpf_combine/logo.svg`); monochrome black for light surfaces, original white for dark surfaces.
- [YOU Broadband](https://youbroadband.in/) (`images/logo.png`), preserving its original badge artwork.

Assets use 256px lossy WebP (q90, alpha_q100); copies are retained under
`assets_raw/icon_packs_raw/logos/`. Regenerate from `app/`:
`node tool/fetch_brand_icons.mjs --only keralavision actfibernet excitel hathway tataplayfiber youbroadband`.

Kerala Vision and Excitel now use only their original standalone symbols,
isolated from the horizontal source artwork. ACT uses only its original A
path (excluding the C and T). Symbol isolation is reproducible in the fetch
script, allowing these marks to fill square tiles without tiny side text.

The latest Kerala Vision and Excitel assets are clean vector reconstructions
of their symbols in `MARK_ONLY_SVGS`, replacing the earlier raster crops.
Kerala Vision's metallic ring is simplified to a flat outline for small tiles.
ACT retains its complete official ACT wordmark on a transparent square canvas,
replacing the isolated A. These treatments supersede the earlier crop notes.

Latest source correction: hand-drawn Kerala Vision and Excitel reconstructions
have been removed. Kerala Vision uses the 512px original emblem from its
[Google Play listing](https://play.google.com/store/apps/details?id=com.nexge.kcclvoip),
with the cyan background and Voice label excluded. Excitel uses the original
symbol isolated from its [3840px official banner](https://www.excitel.com/wp-content/uploads/2025/04/Excitel_1920x720_2-1-1.png),
rendered in the official orange. Original downloads are retained in
`icons/isp_sources/`; crop/background processing is in the fetch script.
This supersedes the reconstruction notes above.

### Worldwide bank rule packs

Worldwide institutions are added in reviewed batches from the names in
`packages/universal_bank_sms_parser/rules/`. The first batch uses original
vector or high-resolution raster marks from Wikimedia Commons for Banco
Promerica, CIB Egypt, National Bank of Egypt, Mellat Bank, Melli Bank, Orange
Money, T-Bank, Al Rajhi Bank, Banque Saudi Fransi, Commercial Bank of Ceylon,
BAAC, Bangkok Bank, CIMB Thai, Kasikorn Bank, Krungsri, KTC, Siam Commercial
Bank, TTB, Enpara, First Abu Dhabi Bank, Navy Federal, Citi, Huntington, Nepal
SBI, GTBank, Jaiz Bank, Keystone Bank, Moniepoint, and Zenith Bank. Chase uses
the original Simple Icons vector. Exact Commons filenames and processing are
recorded beside each entry in `tool/fetch_brand_icons.mjs`.

This batch uses the standalone identity symbol wherever the Commons source is
a horizontal or stacked lockup. Bank names, slogans, presentation rectangles,
and unrelated source backgrounds are clipped or removed in the fetch script.
Only intentional parts of an original mark, such as BAAC's crest, CIMB Thai's
red arrow badge, and GTBank's orange badge, are retained.

### Worldwide bank rule packs, second batch

Logos for the next set of parser-pack institutions come from Wikimedia Commons
or English Wikipedia file pages (exact filenames in `tool/fetch_brand_icons.mjs`):
Arab Bank, Banco Agricola, Awash Bank, Bank of Abyssinia, Commercial Bank of
Ethiopia, Dashen Bank, Zemen Bank, BPCE, Millennium BIM, M-Pesa, Equity Bank,
Standard Chartered (Nepal and Nigeria), Access Bank, Opay, Bank Muscat, Faysal
Bank, D360 Bank, SABB, Saudi National Bank, BRAC Bank, Parsian Bank, National
Savings Bank, Nations Trust Bank, Sampath Bank, CRDB Bank, Diamond Trust Bank,
NMB Bank Tanzania, Government Savings Bank, Krungthai Bank, UOB, Emirates
Islamic, Emirates NBD, Charles Schwab, and Discover. Sparkasse Rhein-Maas uses
the shared Sparkasse mark from Simple Icons; Chase UK reuses the Chase mark.
Kerala Gramin Bank was regenerated from its original source so the complete
diamond "G" symbol, including the blue lower wedge, is kept.

All of them go through one pipeline (`renderVisual`): the white page
background is removed from the edges (white inside a mark is kept), the artwork
is trimmed, and where the source is a horizontal or stacked lockup only the main
symbol is cropped with `VISUAL_CROPS` (for example the Arab Bank loop, the
Faysal Bank star, the Equity emblem). Names, taglines, Arabic or Amharic
captions and presentation tiles are dropped. Downloaded originals are kept in
`icons/bank_sources/`.

Bangkok Bank, GTBank, Krungsri, First Abu Dhabi Bank, Banco Promerica and
Jaiz Bank were redone because the first crops cut the logo: crop boxes now come
from the measured bounds of the source artwork.

Dark companions (`_dark.webp`) were added only where the mark nearly disappears
on charcoal: NSB, SABB, Parsian, Discover, Emirates Islamic, UOB, D360, Opay,
Citi, Navy Federal, Banque Saudi Fransi, Goldman Sachs, Investec, and Morgan
Stanley. Colored accents are kept; the three solid-black marks use white paths
on transparency in dark mode.

Kerala Bank (Wikimedia Commons SVG, the dot-matrix "1" symbol only) was added later with VISUAL_CROPS. Saraswat Bank was tried and dropped: its only source was a small JPG whose crop left white fringes and clipped edges.

ESAF Small Finance Bank uses the blue community emblem and red ESAF wordmark from the
[original Wikimedia Commons SVG](https://commons.wikimedia.org/wiki/File:ESAF_Bank_Logo.svg).
The original paths are stacked symbol-over-wordmark so both remain large and
readable on the square picker tile; the long bank name and tagline are excluded.
The composition is recorded in `renderVisual`, and the downloaded SVG is
retained under `icons/bank_sources/`.

No usable original logo was found for the remaining parser-pack banks, so they
keep the generic bank icon rather than an invented one.

### Major banks: United States, United Kingdom, Indonesia, and Africa

The November 2026 regional expansion adds major consumer and institutional
banks from the United States and United Kingdom, Indonesia's next five largest
banks beyond the existing top five, and African groups represented in the
2026 top-30 ranking. The exact source URL or Wikimedia filename for every bank
is recorded beside its stable key in `tool/fetch_brand_icons.mjs`.

Most originals come from official bank sites, Simple Icons, CompaniesLogo, or
Wikimedia's 500px standard thumbnail service. Official-site sources include
FNB, Nedbank, Northern Trust, and Crédit Populaire d’Algérie. Standalone marks
from wide lockups are isolated reproducibly with `VISUAL_CROPS`; no initials,
AI artwork, favicon, or hand-drawn replacement is used. Compact official
identities that have no separate symbol remain intact. Santander UK and HSBC
USA reuse the corresponding approved Santander and HSBC artwork, while
Standard Chartered UK reuses the existing Standard Chartered mark.

The batch includes Wells Fargo, U.S. Bank, Capital One, PNC, Truist, TD,
Fifth Third, BMO, First Citizens, Citizens, M&T, KeyBank, Ally, HSBC USA,
Regions, Santander, Goldman Sachs, BNY Mellon, Morgan Stanley, State Street,
Northern Trust; Barclays, HSBC, Lloyds, NatWest, Santander UK, Standard
Chartered, Bank of Scotland, TSB, Virgin Money, The Co-operative Bank,
Nationwide, Halifax, and Metro Bank; BSI, CIMB Niaga, OCBC Indonesia,
PermataBank, and Danamon; and the added South African, Egyptian, Moroccan,
Nigerian, Algerian, Togolese, Mauritian, Kenyan, and Gabonese institutions.
All outputs are transparent 256px WebPs (q90, alpha_q100), mirrored in the raw
brand pack, and reviewed as square tiles on light and dark surfaces.

### Square-tile corrections

Horizontal lockups were re-audited against the square-tile rules. Bancoagrícola
now uses the standalone three-bar mark isolated from its
[official Google Play app artwork](https://play.google.com/store/apps/details?id=com.bancoagricola.bancamovil),
and Lloyds uses the black-horse emblem from its
[official Google Play app artwork](https://play.google.com/store/apps/details?id=com.grppl.android.shell.CMBlloydsTSB73).
The original symbols for BRAC Bank, Zemen Bank, Emirates NBD, UOB, SABB, Saudi
National Bank, National Savings Bank, KCB, Virgin Money, Bank of Scotland,
Opay, and Santander UK are isolated from the sources already listed above.
Emirates NBD specifically uses the blue standalone brandmark from the bank's
[official brand-assets page](https://www.emiratesnbd.com/en/brand-assets),
replacing the obsolete 216px horizontal JPEG.
Side wordmarks, slogans, app labels, and presentation backgrounds are excluded;
the crop/background operations are recorded in `tool/fetch_brand_icons.mjs`.
Bancoagrícola, Lloyds, Emirates NBD, and Bank of Scotland use white reverse
companions on charcoal. Virgin Money's dark companion places the original red
circle over white so its official knockout wordmark remains white.

### Cutoff audit corrections

The November 2026 edge audit replaces the truncated CPA Algeria website
lockup with the complete emblem from the bank's
[official CPA Mobile Google Play listing](https://play.google.com/store/apps/details?id=com.beyn.sela.cpa).
It also corrects the retained-source crop boxes for FirstBank Nigeria, M&T,
Mandiri, BTN, Zenith Bank, First Abu Dhabi Bank, Commercial Bank of Ceylon,
and Jaiz Bank. The Commercial Bank output is the source SVG's original reverse
monogram converted to its official blue after removing the presentation strip;
Jaiz uses the complete gold/green mark reconstructed from the retained Commons
JPEG. Small transparent margins are applied during deterministic export so
valid outer strokes no longer meet the 256px canvas edge. No logo was redrawn
or generated with AI.


### Brokers and investing platforms (Portfolio)

The Portfolio screen offers a logo for each broker or platform. None of these
has a vector source in Simple Icons, and where Wikimedia Commons has one it is
an older logo than the one the broker uses today, so each uses the **official app icon from the broker's own Google Play listing**,
downloaded at original size (the 512px files are kept in
`icons/broker_sources/`) and exported unchanged to a 256px WebP by
`tool/fetch_brand_icons.mjs` (`source: 'raster'`). They are registered as banks
under their country, so they appear in the same per-country picker sections.

- Groww (India): [Google Play listing](https://play.google.com/store/apps/details?id=com.nextbillion.groww)
- Upstox (India): [Google Play listing](https://play.google.com/store/apps/details?id=in.upstox.app)
- Angel One (India): [Google Play listing](https://play.google.com/store/apps/details?id=com.msf.angelmobile)
- ICICI Direct (India): [Google Play listing](https://play.google.com/store/apps/details?id=com.icicidirect.idirectsuper)
- HDFC Securities (India): [Google Play listing](https://play.google.com/store/apps/details?id=com.cloudtradetech.sky)
- Kotak Neo (India): [Google Play listing](https://play.google.com/store/apps/details?id=com.kotak.neo)
- Dhan (India): [Google Play listing](https://play.google.com/store/apps/details?id=com.dhan.live)
- Paytm Money (India): [Google Play listing](https://play.google.com/store/apps/details?id=com.paytmmoney)
- Fidelity Investments (United States): [Google Play listing](https://play.google.com/store/apps/details?id=com.fidelity.android)
- E*TRADE (United States): [Google Play listing](https://play.google.com/store/apps/details?id=com.etrade.mobilepro.activity)
- Vanguard (United States): [Google Play listing](https://play.google.com/store/apps/details?id=com.vanguard)
- Interactive Brokers (United States): [Google Play listing](https://play.google.com/store/apps/details?id=atws.app)
- Webull (United States): [Google Play listing](https://play.google.com/store/apps/details?id=org.dayup.stocks)
- Merrill Edge (United States): [Google Play listing](https://play.google.com/store/apps/details?id=com.ml.mobile.edge)
- SoFi (United States): [Google Play listing](https://play.google.com/store/apps/details?id=com.sofi.mobile)
- Trading 212 (United Kingdom): [Google Play listing](https://play.google.com/store/apps/details?id=com.avuscapital.trading212)
- AJ Bell (United Kingdom): [Google Play listing](https://play.google.com/store/apps/details?id=com.apadmi.AJBell)
- eToro (Israel): [Google Play listing](https://play.google.com/store/apps/details?id=com.etoro.openbook)
- Trade Republic (Germany): [Google Play listing](https://play.google.com/store/apps/details?id=de.traderepublic.app)
- DEGIRO (Germany): [Google Play listing](https://play.google.com/store/apps/details?id=nl.degiro.trader)
- Questrade (Canada): [Google Play listing](https://play.google.com/store/apps/details?id=com.questrade.questmobile)
- Wealthsimple (Canada): [Google Play listing](https://play.google.com/store/apps/details?id=com.wealthsimple.trade)
- CommSec (Australia): [Google Play listing](https://play.google.com/store/apps/details?id=au.com.commsec.android.CommSec)
- Stake (Australia): [Google Play listing](https://play.google.com/store/apps/details?id=com.stake.stake)
- Tiger Brokers (Singapore): [Google Play listing](https://play.google.com/store/apps/details?id=com.tigerbrokers.stock)
- XP Investimentos (Brazil): [Google Play listing](https://play.google.com/store/apps/details?id=br.com.xp.carteira)

Notes:
- The app tiles are full-bleed squares, so they keep their tile exactly as the
  publisher drew it; nothing was cropped, recoloured, or redrawn.
- XP Investimentos' tile is black with white lettering and would vanish on
  dark surfaces, so it has a `_dark` companion with the two swapped (the
  brand's white-tile form); see `tool/generate_brand_dark_variants.mjs`.
- Listings were checked by app name and publisher before use. A first guess
  for Vanguard resolved to an unrelated app and 5paisa's listing carried an
  outdated icon, so those were replaced or left out.
- Zerodha and Robinhood were already bundled (Simple Icons) and are unchanged.

Crypto exchanges, wallets and more brokers (official Google Play app icons, full-bleed tiles kept as drawn; listings checked by app name):
- Kraken (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=com.kraken.invest.app)
- Bybit (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=com.bybit.app)
- OKX (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=com.okinc.okex.gp)
- KuCoin (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=com.kubi.kucoin)
- Bitget (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=com.bitget.exchange)
- Gemini (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=com.gemini.android.app)
- Crypto.com (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=co.mona.android)
- Bitstamp (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=net.bitstamp.app)
- MEXC (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=com.mexcpro.client)
- Gate (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=com.gateio.gateio)
- HTX (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=pro.huobi)
- Bitpanda (Austria): [Google Play listing](https://play.google.com/store/apps/details?id=com.bitpanda.bitpanda)
- Upbit (South Korea): [Google Play listing](https://play.google.com/store/apps/details?id=com.dunamu.exchange)
- Bithumb (South Korea): [Google Play listing](https://play.google.com/store/apps/details?id=com.btckorea.bithumb)
- Coincheck (Japan): [Google Play listing](https://play.google.com/store/apps/details?id=jp.coincheck.android)
- CoinDCX (India): [Google Play listing](https://play.google.com/store/apps/details?id=com.coindcx.btc)
- WazirX (India): [Google Play listing](https://play.google.com/store/apps/details?id=com.wrx.wazirx)
- CoinSwitch (India): [Google Play listing](https://play.google.com/store/apps/details?id=com.coinswitch.kuber)
- VALR (South Africa): [Google Play listing](https://play.google.com/store/apps/details?id=com.valr.app)
- Mercado Bitcoin (Brazil): [Google Play listing](https://play.google.com/store/apps/details?id=br.com.mercadobitcoin.android)
- MetaMask (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=io.metamask)
- Trust Wallet (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=com.wallet.crypto.trustapp)
- Ledger (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=com.ledger.live)
- Trezor (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=io.trezor.suite)
- Phantom (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=app.phantom)
- Exodus (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=exodusmovement.exodus)
- Coinbase Wallet (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=org.toshi)
- Rainbow (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=me.rainbow)
- SafePal (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=io.safepal.wallet)
- Atomic Wallet (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=io.atomicwallet)
- Bitcoin.com Wallet (crypto exchange / wallet, worldwide): [Google Play listing](https://play.google.com/store/apps/details?id=com.bitcoin.mwallet)
- moomoo (Hong Kong): [Google Play listing](https://play.google.com/store/apps/details?id=com.moomoo.trade)
- Futubull (Hong Kong): [Google Play listing](https://play.google.com/store/apps/details?id=cn.futu.trader)
- Firstrade (United States): [Google Play listing](https://play.google.com/store/apps/details?id=com.firstrade.android)
- Motilal Oswal (India): [Google Play listing](https://play.google.com/store/apps/details?id=com.mosl.mobile)
- INDmoney (India): [Google Play listing](https://play.google.com/store/apps/details?id=in.indwealth)
- Black tiles (OKX, Bybit, Ledger, INDmoney) have a `_dark` companion with black and white swapped.

More brokers and exchanges (second batch):
- Play Store app icons: Public, FYERS, interactive investor, IIFL, Kuvera, tastytrade, Plus500 (futures app icon), BingX, Bitfinex; same treatment as above. Sharekhan (rebranded Mirae Asset) and 5paisa (generic "Alpha" card art) were tried and left out because their icons don't read as the brand.
- Wikimedia Commons originals, cropped to fit a square tile: Saxo (Saxo Bank logo.svg, the tile as drawn), IG (IG Group logo.svg), Hargreaves Lansdown (Hargreaves Lansdown logo.svg, its two-line wordmark, as it has no symbol), Scalable Capital (Scalable Capital Logo 2024.svg, the teal S on its dark tile, wordmark dropped), Bitso (Logo de Bitso.svg, symbol only). Crops live in `BANK_MARK_CROPS` in `tool/fetch_brand_icons.mjs`.
- Dark companions: Bitso and Hargreaves Lansdown (white), Plus500 and others need none.
- Not found: Freetrade, Mudrex, Luno, Bitkub (no usable large original).
